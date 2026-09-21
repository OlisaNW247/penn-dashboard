import Foundation
import LowHangingFruitKit
import WebKit

/// Silent Canvas session renewal — Layer 2 of the session-longevity work.
///
/// When `AppState.canvasSessionExpired` goes true (the Keychain-persisted
/// Canvas cookie session has aged out — docs/CANVAS_LOGIN_HARDENING.md item
/// 3d), the user's only recourse used to be the "needs a refresh" banner,
/// which sends them through the full in-app PennKey/Duo WebView. Often that's
/// unnecessary: Penn's IdP (`idp.pennkey.upenn.edu`) and Duo keep their own,
/// separately-lived session cookies in `LoginDataStores.canvas` — the same
/// persistent, isolated `WKWebsiteDataStore` the visible login pane uses — so
/// if THAT session is still alive, loading `https://canvas.upenn.edu/` alone
/// is enough to walk the SAML redirect chain straight back to a fresh Canvas
/// session with zero taps. If the IdP session is also dead, the chain lands
/// on a login form instead, and this class gives up quietly and leaves the
/// existing banner to do its job.
///
/// Hard safety rules, carried over from the Stale Request post-mortem
/// (docs/CANVAS_LOGIN_DIAGNOSIS.md, docs/CANVAS_LOGIN_HARDENING.md group 3a)
/// — rule 1 amended below for the "stay signed in" feature, rules 2–6 kept
/// verbatim:
/// 1. **One `webView.load(URLRequest)` per attempt, PLUS — as of "stay
///    signed in" (CLAUDE.md) — at most one JavaScript submission per
///    attempt, of the IdP's *credential* form (`j_username`/`j_password`),
///    guarded both by an instance flag (`hasSubmittedCredentialsThisAttempt`)
///    and by the script's own page-level sentinel
///    (`PennKeyLoginForm.fillAndSubmitScript`'s `window.__lhfAutoLogin`).
///    This does NOT reopen the historical bug: that post-mortem's double-POST
///    was of the SAML *response* form on the way back to Canvas — a
///    different form, on a different host, at a different point in the
///    chain — and nothing in this class ever touches that form or that hop.
///    The only code allowed near the SAML response form's re-issue is
///    `LoginNavigationObserver`'s own guard and re-issue logic, and this
///    class deliberately uses its own separate, local navigation delegate
///    (`RenewalNavigationDelegate` below) specifically so it can never
///    inherit that class's re-navigation behavior — see that type's doc
///    comment. Without credentials configured (the `autoLogin` closure
///    returns `nil`, which is everything this class did before "stay signed
///    in" existed and everything it still does for a student who hasn't
///    turned the feature on), this class's behavior is unchanged: exactly
///    one GET, no JavaScript, ever.
/// 2. **Read-only against the login data store.** Cookies are only ever
///    harvested via `httpCookieStore.getAllCookies`; nothing here ever purges
///    or writes into `LoginDataStores.canvas`.
/// 3. **Never runs while the visible login pane could be using the same
///    store** — gated on the `isLoginPaneActive` closure the owner injects
///    (backed by `AppState.isCanvasLoginPaneActive`).
/// 4. **One attempt per cooldown window, one in-flight attempt max, hard
///    timeout.** See `cooldown`/`timeout` below.
/// 5. **Inert under test/fixture conditions** — the test-runner guard lives
///    in `gate(...)`; `isUsingFixtureData` is checked by the caller
///    (`AppState.attemptSilentCanvasRenewal()`) before this class is even
///    reached, since that flag is private state on `AppState` this class has
///    no reason to know about.
/// 6. **Silent failure.** No banner change, no log spam — at most one
///    `LoginDiagnosticsLog` entry per real attempt (host/path/status only,
///    never a cookie value), gated behind the same cooldown as everything
///    else here.
@MainActor
final class CanvasSessionRenewer {
    /// Mirrors `renewIfNeeded()`'s possible results back to the caller (and,
    /// via `attemptSilentCanvasRenewal()`, to nothing user-visible — see rule
    /// 6 above).
    enum Outcome: Equatable {
        case renewed
        case landedOnLoginPage
        case timedOut
        /// The visible login pane appeared while this attempt was mid-flight,
        /// so the attempt tore itself down (`abortForLoginPane()`) — the user
        /// is now doing the real thing, and a background navigation racing
        /// them through the same store is exactly what rule 3 forbids.
        case abortedByLoginPane
        case notAttempted(reason: String)
        /// A credential submission (this attempt's own, or one already in
        /// flight from an earlier hop) landed on Duo's host and the chain
        /// stayed there long enough to be observed as a settled page rather
        /// than a transient redirect — Duo needs a human, which a silent
        /// background attempt cannot supply. `AppState` treats this exactly
        /// like every other non-`.renewed` outcome: silent, banner unchanged.
        case needsDuo
        /// This attempt actually submitted the stored PennKey password
        /// (`autoLogin` returned credentials) and the chain landed back on
        /// the IdP's login form instead of Duo or Canvas — the password
        /// didn't work. `AppState.noteAutoLoginRejected()` is wired to this
        /// outcome specifically, which is what disables further auto-login
        /// attempts until the student re-enters the password (see that
        /// method's doc comment for why retrying instead was rejected).
        case passwordRejected
    }

    /// Minimum spacing between two real (network-touching) attempts, kept in
    /// the same neighborhood as `AutoSyncCoordinator`'s other cookie-authed
    /// refresh throttles but wider — this one drives an actual WebView
    /// navigation against Penn's IdP, not a REST fetch, so it's worth being
    /// stingier with it.
    static let cooldown: TimeInterval = 60 * 60

    /// A SEPARATE, much longer cooldown that gates only whether a given
    /// attempt is allowed to actually SUBMIT the stored PennKey password —
    /// distinct from `cooldown` above, which gates whether an attempt runs
    /// at all. An attempt can still run every hour (to pick up a session
    /// that came back on its own via still-live IdP cookies, exactly as
    /// before this feature existed) without that also meaning a wrong or
    /// flapping stored password gets resubmitted to Penn's IdP every hour —
    /// that repeated-wrong-password shape is exactly what risks a PennKey
    /// lockout. In practice a single rejection already stops further
    /// submissions immediately (`autoLogin` starts returning `nil` once
    /// `AppState.autoLoginDisabledReason` is set — see
    /// `AppState.attemptSilentCanvasRenewal`'s doc comment on its `autoLogin`
    /// closure), so this cooldown's real job is bounding the case where a
    /// session keeps expiring and reviving faster than a human notices, not
    /// the rejected-password case specifically.
    static let autoLoginCooldown: TimeInterval = 6 * 60 * 60

    /// Hard cap on one attempt. Past this the WebView is discarded regardless
    /// of what WebKit is still doing — a hung SSO hop (a stuck Duo prompt
    /// that will never complete without a human, a slow network) must not
    /// leave a silent background attempt running indefinitely.
    static let timeout: TimeInterval = 30

    private static let canvasURL = URL(string: "https://canvas.upenn.edu/")!

    /// Case-insensitive substrings of an IdP/login host — Penn's actual SAML
    /// chain hops through `idp.pennkey.upenn.edu`; `weblogin`/`duosecurity`
    /// are included for the same reason `AppState.canvasLoginDomainHints`
    /// covers `duosecurity` — Duo's own domain if a 2FA prompt is reached.
    private static let loginHostMarkers = ["pennkey", "idp", "weblogin", "duosecurity"]

    /// Canvas's own session cookie names, matched as a case-insensitive
    /// substring of the cookie's `name` — `canvas_session` is Canvas's own
    /// Rails session cookie, `_normandy_session` is Instructure's shared
    /// Normandy auth service cookie. Either one present on a canvas.upenn.edu
    /// cookie is treated as "a real session was minted."
    private static let sessionCookieNameMarkers = ["canvas_session", "_normandy_session"]

    /// Injected rather than read from a stored `AppState` reference: keeps
    /// this class free of any dependency on `AppState`'s shape beyond "can I
    /// run right now," which is also what makes the pure `gate(...)` function
    /// below testable without constructing an `AppState` at all.
    private let isLoginPaneActive: () -> Bool

    /// Returns the stored PennKey username/password to submit into the IdP's
    /// login form if/when this attempt reaches it, or `nil` if there is
    /// nothing to submit (the feature is off, no credentials are on file, or
    /// a prior submission was already rejected and hasn't been re-entered —
    /// see `AppState.attemptSilentCanvasRenewal`'s own doc comment on the
    /// closure it passes here). A closure rather than a stored credential
    /// pair, so this class never itself holds the secret between attempts —
    /// it asks fresh, every time it might actually use one, and forgets it
    /// again immediately after. `nil` (the default) reproduces this class's
    /// entire pre-"stay signed in" behavior byte for byte: no credentials
    /// ever means no JavaScript ever runs, full stop.
    private let autoLogin: (() -> (username: String, password: String)?)?

    /// Set once per attempt, right before the one-and-only credential
    /// submission that attempt is allowed to make (rule 1's amendment,
    /// above) — reset at the top of every `performAttempt()`. Never reset
    /// mid-attempt: once true, this attempt will not submit again no matter
    /// how many more times the login form finishes loading before the
    /// attempt otherwise resolves.
    private var hasSubmittedCredentialsThisAttempt = false

    /// Wall-clock time of the most recent credential submission across ALL
    /// attempts (unlike `hasSubmittedCredentialsThisAttempt`, this outlives
    /// a single `performAttempt()` call) — what `autoLoginCooldown` is
    /// measured against.
    private var lastCredentialSubmissionAt: Date?

    private var lastAttemptAt: Date?
    private var isInFlight = false

    #if DEBUG
    /// Owner-only test seam for the Settings "simulate canvas logout" button
    /// (`AppState.simulateCanvasLogoutForTesting()`). Without this, testing
    /// "stay signed in" end to end on a real phone means waiting for
    /// Canvas's cookie to actually age out (about a day) or, worse, for
    /// `cooldown` (1h) / `autoLoginCooldown` (6h) to lapse after any earlier
    /// attempt this launch already made — the whole point of those throttles
    /// being long is that a real background trigger should almost never fire
    /// twice in a session, which is exactly what makes them useless for
    /// deliberately firing twice on purpose. Resetting both (rather than
    /// just `lastAttemptAt`) matters because a `.passwordRejected` outcome
    /// from an earlier manual test would otherwise still be inside
    /// `autoLoginCooldown` and `handleNonCanvasFinish` would silently treat
    /// the next attempt as "no credentials" instead of actually resubmitting
    /// the (freshly re-entered, or unchanged) stored password — see that
    /// method's own comment on `credentialSubmissionAllowed`. Does not touch
    /// `isInFlight`: an attempt that's genuinely still running should still
    /// be treated as in flight, throttle reset or not. Compiles out of every
    /// Release build.
    func resetThrottlesForTesting() {
        lastAttemptAt = nil
        lastCredentialSubmissionAt = nil
    }

    /// Host+path (never the query string, which can carry live SAML request
    /// state) of wherever the WebView was sitting the moment the most recent
    /// attempt settled or hit the hard timeout. Set once per attempt, right
    /// after `waiter.wait()` resolves in `performAttempt()`, before anything
    /// downstream can navigate further or the `defer` discards the WebView.
    /// Surfaced by `AppState.simulateCanvasLogoutForTesting()` so a
    /// `.timedOut`/`.landedOnLoginPage` result on a real device says WHERE
    /// the chain actually stalled instead of just that it did — the
    /// 2026-09-21 incident needed exactly this to even start diagnosing.
    /// DEBUG-only, same reasoning as `resetThrottlesForTesting()` above.
    private(set) var lastSettledOrTimedOutURL: String?

    /// Pure formatting helper for `lastSettledOrTimedOutURL` — host+path
    /// only, `nil` in, `nil` out (a `nil` URL, e.g. a WebView that never
    /// navigated at all, has nothing to report). DEBUG-only alongside the
    /// property it exists to fill in — kept out of Release builds rather
    /// than left as unused dead weight there.
    private static func hostPathString(_ url: URL?) -> String? {
        guard let url, let host = url.host else { return nil }
        return "\(host)\(url.path)"
    }
    #endif

    /// The in-flight attempt's WebView/delegate, retained here for the
    /// duration of `performAttempt()` and nowhere else. `WKWebView
    /// .navigationDelegate` is a WEAK property (same fact
    /// `LoginNavigationObserver`'s doc comment notes — there it's the pane's
    /// `@StateObject` that keeps the delegate alive instead), so without a
    /// strong reference held somewhere past the point the delegate is
    /// assigned, ARC would be free to deallocate a purely-local `delegate`
    /// variable as soon as its last textual use passed, silently nil-ing
    /// `webView.navigationDelegate` before any callback could ever fire.
    /// Holding both on `self` and clearing them together in `performAttempt`
    /// 's `defer` is what makes "discard the WebView (and its delegate) in
    /// every exit path" actually true, rather than just documented.
    private var activeWebView: WKWebView?
    private var activeDelegate: RenewalNavigationDelegate?
    private var activeWaiter: SettleWaiter?

    /// Tears down an in-flight attempt because the visible Canvas login pane
    /// just appeared (rule 3's second half — the gate stops a NEW attempt
    /// from starting while the pane is open, and this stops an ALREADY
    /// RUNNING one the moment the pane opens). The trigger design makes this
    /// race likely, not hypothetical: the same `canvasSessionExpired`
    /// transition that starts a silent attempt also surfaces the "needs a
    /// refresh" banner, so the user tapping reconnect right then is the
    /// EXPECTED path, and the pane's purge-then-login must never share the
    /// live store with a background SAML navigation still resolving. Called
    /// synchronously from `AppState.isCanvasLoginPaneActive`'s `didSet`
    /// (both are `@MainActor`, so there's no window between the flag flip
    /// and this teardown). The consumed cooldown slot deliberately stays
    /// consumed — the user is logging in for real; retrying silently a
    /// second later would race them all over again.
    func abortForLoginPane() {
        guard isInFlight else { return }
        activeWebView?.stopLoading()
        activeWaiter?.signal(.aborted)
    }

    init(
        isLoginPaneActive: @escaping () -> Bool,
        autoLogin: (() -> (username: String, password: String)?)? = nil
    ) {
        self.isLoginPaneActive = isLoginPaneActive
        self.autoLogin = autoLogin
    }

    /// Attempts one silent renewal, subject to every guard in `gate(...)`.
    /// Safe to call redundantly/speculatively from multiple observers
    /// (`AppState.refreshCanvasSessionExpiredState()`,
    /// `AppState.refreshGradeWatcher(cookies:)`) — the cooldown/in-flight
    /// state make every call after the first in a given window a cheap,
    /// synchronous no-op.
    func renewIfNeeded(now: Date = Date()) async -> Outcome {
        if let gated = Self.gate(
            now: now,
            lastAttempt: lastAttemptAt,
            inFlight: isInFlight,
            paneActive: isLoginPaneActive(),
            isTestRunner: SharedDefaults.isTestRunner
        ) {
            return gated
        }

        // Recorded BEFORE the WebView ever navigates: a crash, a hang, or
        // the 30s timeout below still consumes this window's cooldown slot,
        // so a stuck attempt can't be retried again a second later by the
        // next trigger (e.g. another `refreshCanvasSessionExpiredState()`
        // call a few seconds later in the same launch).
        lastAttemptAt = now
        isInFlight = true
        defer { isInFlight = false }

        return await performAttempt()
    }

    /// Pure decision logic behind `renewIfNeeded()`: `nil` means "proceed
    /// with a real attempt," any non-nil `Outcome` is the answer to return
    /// immediately without touching WebKit. Order matches the brief exactly
    /// — test runner, then login-pane-active, then in-flight, then cooldown
    /// — so the cheapest/most-certain guards short-circuit first.
    static func gate(
        now: Date,
        lastAttempt: Date?,
        inFlight: Bool,
        paneActive: Bool,
        isTestRunner: Bool
    ) -> Outcome? {
        if isTestRunner {
            return .notAttempted(reason: "test runner")
        }
        if paneActive {
            return .notAttempted(reason: "Canvas login pane is active")
        }
        if inFlight {
            return .notAttempted(reason: "an attempt is already in flight")
        }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < cooldown {
            return .notAttempted(reason: "within the 1h cooldown")
        }
        return nil
    }

    /// How a navigation's final host classifies, for the success/failure
    /// decision after settle. Pure and `static` so it's testable without a
    /// live WebView.
    enum HostClassification: Equatable {
        /// Landed back on Canvas itself — the SAML round trip completed.
        case canvas
        /// Landed on Penn's IdP, Duo, or an equivalent login host — the IdP
        /// session was dead, so give up silently.
        case loginPage
        /// Anything else (nil host, an unrelated domain, mid-flight).
        case other
    }

    /// Pure decision behind `autoLoginCooldown` — testable without
    /// constructing a `CanvasSessionRenewer` at all, same shape as `gate(...)`.
    /// `nil` (no prior submission on record) is always allowed.
    static func credentialSubmissionAllowed(lastSubmissionAt: Date?, now: Date) -> Bool {
        guard let lastSubmissionAt else { return true }
        return now.timeIntervalSince(lastSubmissionAt) >= autoLoginCooldown
    }

    static func classifyFinalHost(_ host: String?) -> HostClassification {
        guard let host, !host.isEmpty else { return .other }
        let lower = host.lowercased()
        if loginHostMarkers.contains(where: lower.contains) {
            return .loginPage
        }
        if lower == "canvas.upenn.edu" {
            return .canvas
        }
        return .other
    }

    /// True for a canvas.upenn.edu cookie whose name marks it as an actual
    /// session credential (as opposed to, say, a CSRF token or an analytics
    /// cookie that also happens to live on that domain) — see
    /// `sessionCookieNameMarkers`'s doc comment for what the two names mean.
    static func isCanvasSessionCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.domain.localizedCaseInsensitiveContains("canvas") else { return false }
        let name = cookie.name.lowercased()
        return sessionCookieNameMarkers.contains { name.contains($0) }
    }

    /// The actual WebKit-touching attempt. Never called directly — only
    /// through `renewIfNeeded()`, which has already recorded the cooldown
    /// timestamp and set the in-flight flag before this runs.
    private func performAttempt() async -> Outcome {
        // Fresh for every attempt — see this flag's own doc comment. Reset
        // here rather than only at declaration so a *reused* renewer
        // (`AppState.canvasSessionRenewer` is created once and kept across
        // calls) doesn't carry a stale `true` from an earlier attempt into
        // this one and skip a submission it should actually make.
        hasSubmittedCredentialsThisAttempt = false

        let configuration = WKWebViewConfiguration()
        // Bound to the SAME persistent, isolated store the visible Canvas
        // login pane uses (`LoginDataStores.canvas` — see its own doc
        // comment) so the still-live PennKey/Duo IdP cookies from the user's
        // last real login are actually there to be replayed. Never a fresh
        // or `.default()` store — either would have no IdP session to ride
        // on and would always land on a login form.
        configuration.websiteDataStore = LoginDataStores.canvas
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Mirrors `makeWebView`'s hardening choices (OnboardingView.swift) —
        // duplicated rather than shared, since that function is `private`
        // and pane-coupled (it wires a pane-owned `LoginNavigationObserver`
        // that this renewer deliberately does not reuse; see the delegate
        // below). Never added to any view hierarchy — `webView.frame` stays
        // `.zero` and it's never assigned to a superview.
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = LoginUserAgent.mobileSafari

        let waiter = SettleWaiter()
        let delegate = RenewalNavigationDelegate(
            waiter: waiter,
            // Called for every `didFinish` that did NOT land on Canvas.
            // Returning `true` tells the delegate to settle the wait now
            // (classified below, once `waiter.wait()` returns); `false`
            // keeps waiting for a further hop or the hard timeout — which,
            // with no credentials configured, is EVERY non-Canvas finish,
            // reproducing this class's pre-"stay signed in" behavior
            // exactly (rule 1's doc comment). `async` because deciding
            // requires evaluating `detectFormScript` in-page first — see
            // `handleNonCanvasFinish`'s doc comment.
            onNonCanvasFinish: { [weak self] webView in
                await self?.handleNonCanvasFinish(webView) ?? false
            }
        )
        webView.navigationDelegate = delegate
        // See `activeWebView`/`activeDelegate`'s doc comment: this is the
        // strong reference that actually keeps `delegate` alive opposite
        // `navigationDelegate`'s weak storage.
        activeWebView = webView
        activeDelegate = delegate
        activeWaiter = waiter
        defer {
            // Discard the WebView (and its delegate) on every exit path
            // below, including the two early returns — this is the one
            // `defer`, so there's exactly one place that can forget to do it.
            activeWebView?.navigationDelegate = nil
            activeWebView = nil
            activeDelegate = nil
            activeWaiter = nil
        }

        // GET-only, exactly one `load(URLRequest)` call for the whole
        // attempt — rule 1 above / docs/CANVAS_LOGIN_HARDENING.md group 3a's
        // "never re-post, never reload on failure." If this doesn't resolve
        // to a live Canvas session on its own, the attempt simply fails.
        webView.load(URLRequest(url: Self.canvasURL))

        // Races the navigation settling against a hard 30s timeout. Both
        // paths call `waiter.signal(_:)`, which is idempotent (see
        // `SettleWaiter`) — so however this race resolves, the continuation
        // inside `waiter.wait()` is resumed exactly once, and a delegate
        // callback that fires after the timeout already won is a harmless
        // no-op instead of a double-resume crash or a dangling continuation.
        // `@MainActor` on the closure (matching `AppState`'s own
        // `Task { @MainActor in ... }` bridge pattern elsewhere in this
        // codebase) makes the isolation explicit rather than relying on
        // inferred inheritance from the enclosing method.
        let timeoutTask = Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            waiter?.signal(.timedOut)
        }
        let signal = await waiter.wait()
        timeoutTask.cancel()

        #if DEBUG
        lastSettledOrTimedOutURL = Self.hostPathString(webView.url)
        #endif

        if signal == .timedOut {
            Self.logAttempt(host: webView.url?.host, status: "timed-out")
            return .timedOut
        }
        if signal == .aborted {
            Self.logAttempt(host: webView.url?.host, status: "aborted-for-login-pane")
            return .abortedByLoginPane
        }

        let finalHost = webView.url?.host
        guard Self.classifyFinalHost(finalHost) == .canvas else {
            // Distinguish the three ways this can end besides Canvas —
            // order matters: the password-rejected check must come first,
            // since a login-form landing after a submission this attempt
            // actually made is strictly more informative than the generic
            // "landed on login" catch-all below.
            if hasSubmittedCredentialsThisAttempt, PennKeyLoginForm.isLoginForm(webView.url) {
                Self.logAttempt(host: finalHost, status: "password-rejected")
                return .passwordRejected
            }
            if PennKeyLoginForm.isDuo(webView.url) {
                Self.logAttempt(host: finalHost, status: "needs-duo")
                return .needsDuo
            }
            // Covers both the documented login-host case AND anything else
            // unrecognized (mid-redirect, a host neither list expects) —
            // either way, no session was confirmed, so behave identically:
            // give up silently and let the existing banner do its job.
            Self.logAttempt(host: finalHost, status: "landed-on-login")
            return .landedOnLoginPage
        }

        // Read-only harvest (rule 2 above) — never `setCookie`/`removeData`
        // against this store.
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.canvas.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let canvasCookies = cookies.filter { $0.domain.localizedCaseInsensitiveContains("canvas") }
        guard canvasCookies.contains(where: Self.isCanvasSessionCookie) else {
            // Landed back on canvas.upenn.edu but minted no recognizable
            // session cookie — e.g. an anonymous/public page. Treat the same
            // as landing on a login page: nothing to harvest.
            Self.logAttempt(host: finalHost, status: "no-session-cookie")
            return .landedOnLoginPage
        }

        SessionCookieStore.merge(canvasCookies, service: .canvas)
        Self.logAttempt(host: finalHost, status: "renewed")
        return .renewed
    }

    /// Called from `RenewalNavigationDelegate.didFinish` for every
    /// navigation in the current attempt that did NOT land on Canvas.
    /// Returns whether the wait should settle now (`true`) or keep waiting
    /// (`false`) — see the call site's doc comment for what each means.
    ///
    /// `async` because an IdP-host landing now evaluates `detectFormScript`
    /// before deciding anything — `isLoginForm(url)` is only a cheap
    /// host+path pre-filter, and Penn's real flow renders more than one page
    /// at that exact host+path shape: the credential form itself, a Duo
    /// hand-off page shown immediately after a correct password, and a page
    /// Duo hands control back to before its own auto-submitted POST. Without
    /// this check, either of the latter two reads as "the login form came
    /// back" — which, on a real device (2026-09-21), produced `.timedOut`
    /// AND a stale `.passwordRejected` from an EARLIER automatic attempt (the
    /// student's password was correct and Duo was mid-flight the whole
    /// time). See `PennKeyLoginForm.PagePresence.noForm`'s doc comment for
    /// the full incident.
    ///
    /// This — plus the one `fillAndSubmitScript` call — are the only places
    /// `evaluateJavaScript` is ever called from this class, and the
    /// submission still runs at most once per attempt
    /// (`hasSubmittedCredentialsThisAttempt`), which is rule 1's amendment in
    /// this file's header doc comment. `fillAndSubmitScript`'s own result is
    /// still deliberately ignored (`completionHandler: nil`) — this class
    /// doesn't need to know whether the submission "worked" in any
    /// JavaScript sense; the navigation that follows (or doesn't) is what
    /// `performAttempt`'s classification above actually reasons about.
    private func handleNonCanvasFinish(_ webView: WKWebView) async -> Bool {
        if PennKeyLoginForm.isDuo(webView.url) {
            // A real, rendered page on Duo's host — either a prompt genuinely
            // waiting for a human (the case this settles for) or, on a
            // "remembered device," a page that's about to auto-continue on
            // its own. There's no way to tell those apart from here without
            // waiting to see whether anything else happens — but if this
            // really is a transient hop, the auto-continue navigation that
            // follows fires ITS OWN `didFinish`, which (if it reaches Canvas)
            // signals `.finished` on the check above before this settled
            // signal is even read by anyone, since `SettleWaiter.signal` only
            // honors the FIRST call. So settling here costs nothing in the
            // fast-remembered-device case and saves the full 30s timeout in
            // the genuinely-stuck-at-Duo case.
            return true
        }

        guard PennKeyLoginForm.isLoginForm(webView.url) else {
            // Some other page — most often a mid-chain IdP hop that isn't
            // the credential form itself. Keep waiting, exactly as this
            // class already did for every non-Canvas host before "stay
            // signed in" existed.
            return false
        }

        let scriptResult = await withCheckedContinuation { (continuation: CheckedContinuation<Any?, Never>) in
            webView.evaluateJavaScript(PennKeyLoginForm.detectFormScript) { value, _ in
                continuation.resume(returning: value)
            }
        }
        switch PennKeyLoginForm.presence(from: scriptResult) {
        case .noForm, .unknown:
            // The IdP host, but NOT the credential form — the Duo hand-off
            // page or the page Duo hands control back to, most likely (see
            // this method's own doc comment). Keep waiting for a further
            // hop or the hard timeout; the attempt counter and credential
            // store are both untouched.
            return false
        case .form, .formError:
            break
        }

        if hasSubmittedCredentialsThisAttempt {
            // The credential form is ACTUALLY present a second time after
            // the one submission this attempt is allowed to make —
            // Shibboleth re-rendering its own login form is exactly what a
            // wrong password looks like. Settle now; rule 1 forbids a
            // second submission regardless.
            return true
        }

        guard let credentials = autoLogin?() else {
            // No credentials to submit — either "stay signed in" is off, or
            // `AppState.canAutoLoginSilently` is currently false for some
            // other reason (a prior rejection or awaiting-Duo latch not yet
            // cleared, credentials missing). Keep waiting; a login form that
            // never advances times out silently via the 30s cap, same as
            // always — byte-for-byte this class's behavior before
            // `detectFormScript` existed.
            return false
        }
        guard Self.credentialSubmissionAllowed(lastSubmissionAt: lastCredentialSubmissionAt, now: Date()) else {
            // Within `autoLoginCooldown` of a previous submission — treat
            // exactly like "no credentials" rather than resubmitting to
            // Penn's IdP on every renewal attempt.
            return false
        }

        hasSubmittedCredentialsThisAttempt = true
        lastCredentialSubmissionAt = Date()
        let script = PennKeyLoginForm.fillAndSubmitScript(username: credentials.username, password: credentials.password)
        webView.evaluateJavaScript(script, completionHandler: nil)
        // Keep waiting: the submission's own resulting navigation (Canvas,
        // Duo, or the login form again) is what actually resolves this
        // attempt, on a LATER call into this same method or the Canvas
        // check above it.
        return false
    }

    /// One `LoginDiagnosticsLog` entry per real attempt (rule 6 above) — host
    /// and a short status word only, never a cookie name or value. Attempts
    /// are already capped by `cooldown`, so this can't turn into log spam.
    private static func logAttempt(host: String?, status: String) {
        LoginDiagnosticsLog.shared.record(
            LoginRedirectLogEntry(
                host: host ?? "(no host)",
                path: " [silent-renewal \(status)]",
                status: nil,
                at: Date()
            )
        )
    }
}

/// Exactly-once-resumable settle signal shared between the timeout `Task` and
/// the navigation delegate below. `hasResumed` is the load-bearing guard:
/// whichever of "navigation settled" or "timeout fired" happens first wins
/// and resumes the continuation; the loser's call to `signal(_:)` is then a
/// no-op instead of a double-resume (a fatal error) or, if it were skipped
/// entirely instead of guarded, a continuation that never resumes at all
/// (a leaked-continuation runtime warning/crash). Every code path that could
/// settle the wait calls `signal(_:)` unconditionally; the guard inside is
/// what makes calling it more than once safe.
@MainActor
private final class SettleWaiter {
    enum Signal {
        case finished
        case failed
        case timedOut
        /// The visible login pane appeared mid-attempt — see
        /// `CanvasSessionRenewer.abortForLoginPane()`.
        case aborted
    }

    private var continuation: CheckedContinuation<Signal, Never>?
    private var hasResumed = false

    func wait() async -> Signal {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal(_ value: Signal) {
        guard !hasResumed, let continuation else { return }
        hasResumed = true
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// Observe-only `WKNavigationDelegate` local to this file — deliberately NOT
/// `LoginNavigationObserver` (the pane's own delegate), for two reasons:
/// 1. `LoginNavigationObserver` is pane-coupled (a `@Published`-heavy
///    `ObservableObject` carrying a redirect log, error-page detection, and
///    a `startURL` wired for its owning pane's "Start over" flow) — none of
///    which this background renewer needs or should surface anywhere.
/// 2. Most importantly, `LoginNavigationObserver.autoRecoverIfBothNavigationsDead`
///    calls `webView.load(...)` a SECOND time on a specific failure pattern
///    (the duplicate-POST dead end it self-heals from) — exactly the kind of
///    extra navigation rule 1 (GET-only, one `load` call per attempt) forbids
///    for this class. A local delegate that only ever observes and never
///    re-navigates is the only way to guarantee that.
///
/// This delegate still unconditionally `.allow`s every navigation decision
/// (same posture as `LoginNavigationObserver`) — it never cancels, redirects,
/// or otherwise steers the SAML chain; it only watches for the navigation to
/// settle.
@MainActor
private final class RenewalNavigationDelegate: NSObject, WKNavigationDelegate {
    private let waiter: SettleWaiter
    /// Consulted for every `didFinish` that isn't a Canvas landing — see
    /// `CanvasSessionRenewer.handleNonCanvasFinish`'s doc comment for what it
    /// does (submit the stored PennKey password into a freshly-seen login
    /// form, or recognize a Duo/rejected-login settle point) and why
    /// returning `false` here reproduces this class's original,
    /// pre-"stay signed in" GET-only behavior exactly. `async` because
    /// deciding requires an in-page `evaluateJavaScript` round trip
    /// (`detectFormScript`) before this delegate can tell a real credential
    /// form apart from a same-host, same-path Duo hand-off/return page.
    private let onNonCanvasFinish: (WKWebView) async -> Bool

    init(waiter: SettleWaiter, onNonCanvasFinish: @escaping (WKWebView) async -> Bool) {
        self.waiter = waiter
        self.onNonCanvasFinish = onNonCanvasFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A successful SAML round trip is MORE than one WebKit navigation:
        // Shibboleth's POST binding answers with an IdP-hosted page whose
        // JavaScript auto-submits a form back to the SP, and that submit is a
        // second navigation the page starts on its own (not us — rule 1's
        // one-`load()`-call budget, amended for at most one JS submission per
        // attempt, is otherwise untouched). So a `didFinish` on the IdP host
        // mid-chain must NOT unconditionally settle the wait, or a renewal
        // that was milliseconds from succeeding gets misread as "landed on a
        // login page." Only an arrival back on Canvas itself always settles
        // as finished; everything else is handed to `onNonCanvasFinish`,
        // which recognizes the two OTHER settle-worthy landings this class
        // now knows about (Duo, and the login form after this attempt's own
        // submission — confirmed by actually querying the page, not just its
        // URL) and otherwise says "keep waiting" — a chain that truly
        // dead-ends on some other page still settles via the hard timeout,
        // exactly as it always has.
        //
        // `onNonCanvasFinish` is `async`, and `didFinish` itself is a plain
        // synchronous delegate callback, so the evaluation runs inside a
        // `Task` — same `@MainActor`-bridge shape as the timeout `Task` in
        // `performAttempt()`. `SettleWaiter.signal(_:)` is idempotent (only
        // the FIRST call resumes anything), so it does not matter whether
        // this `Task`, a later `didFinish` call, or the 30s timeout `Task`
        // wins the race — whichever settles first is the only one that
        // counts, and every later signal is a harmless no-op.
        if CanvasSessionRenewer.classifyFinalHost(webView.url?.host) == .canvas {
            waiter.signal(.finished)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.onNonCanvasFinish(webView) {
                self.waiter.signal(.finished)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenignInterruption(error) else { return }
        waiter.signal(.failed)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenignInterruption(error) else { return }
        waiter.signal(.failed)
    }

    /// `NSURLErrorCancelled` here almost always means one navigation was
    /// interrupted by the next one starting — routine inside an SSO redirect
    /// chain (JS-driven hops cancel the in-flight provisional load). Treating
    /// it as a real failure would abort the wait mid-chain; ignoring it lets
    /// the chain's final state (a Canvas `didFinish`, a genuine failure, or
    /// the hard timeout) decide instead.
    private static func isBenignInterruption(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    // Same signature discipline `LoginNavigationObserver` documents for these
    // two methods — `@MainActor @Sendable` on the decision handler is what
    // the SDK's protocol requirement actually demands; without it WebKit
    // silently never calls this override at all.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}
