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
/// Hard safety rules, carried over verbatim from the Stale Request
/// post-mortem (docs/CANVAS_LOGIN_DIAGNOSIS.md,
/// docs/CANVAS_LOGIN_HARDENING.md group 3a):
/// 1. **GET-only.** `webView.load(URLRequest)` is called exactly once per
///    attempt. No JavaScript that submits a form, no re-post, no reload on
///    failure — the historical bug this whole subsystem exists to never
///    repeat was a double-POSTed SAML login form.
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
        case notAttempted(reason: String)
    }

    /// Minimum spacing between two real (network-touching) attempts, kept in
    /// the same neighborhood as `AutoSyncCoordinator`'s other cookie-authed
    /// refresh throttles but wider — this one drives an actual WebView
    /// navigation against Penn's IdP, not a REST fetch, so it's worth being
    /// stingier with it.
    static let cooldown: TimeInterval = 60 * 60

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

    private var lastAttemptAt: Date?
    private var isInFlight = false

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

    init(isLoginPaneActive: @escaping () -> Bool) {
        self.isLoginPaneActive = isLoginPaneActive
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
        let delegate = RenewalNavigationDelegate(waiter: waiter)
        webView.navigationDelegate = delegate
        // See `activeWebView`/`activeDelegate`'s doc comment: this is the
        // strong reference that actually keeps `delegate` alive opposite
        // `navigationDelegate`'s weak storage.
        activeWebView = webView
        activeDelegate = delegate
        defer {
            // Discard the WebView (and its delegate) on every exit path
            // below, including the two early returns — this is the one
            // `defer`, so there's exactly one place that can forget to do it.
            activeWebView?.navigationDelegate = nil
            activeWebView = nil
            activeDelegate = nil
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

        if signal == .timedOut {
            Self.logAttempt(host: webView.url?.host, status: "timed-out")
            return .timedOut
        }

        let finalHost = webView.url?.host
        guard Self.classifyFinalHost(finalHost) == .canvas else {
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

    init(waiter: SettleWaiter) {
        self.waiter = waiter
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A successful SAML round trip is MORE than one WebKit navigation:
        // Shibboleth's POST binding answers with an IdP-hosted page whose
        // JavaScript auto-submits a form back to the SP, and that submit is a
        // second navigation the page starts on its own (not us — rule 1's
        // one-`load()`-call budget is untouched). So a `didFinish` on the IdP
        // host mid-chain must NOT settle the wait, or a renewal that was
        // milliseconds from succeeding gets misread as "landed on a login
        // page." Only an arrival back on Canvas itself settles as finished;
        // a chain that truly dead-ends on a login form settles via the hard
        // timeout instead, which the caller treats just as silently.
        if CanvasSessionRenewer.classifyFinalHost(webView.url?.host) == .canvas {
            waiter.signal(.finished)
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
