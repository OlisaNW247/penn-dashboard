import Foundation
import WebKit
import LowHangingFruitKit

/// The one client of Path@Penn: a single hidden `WKWebView` on Penn's advising
/// page (`https://courses.upenn.edu/`) that lives for the app run.
///
/// **Why the page is the client.** The audit is served by a single-page app
/// whose requests carry a 32-character token in the form body, and whose own
/// script knows how to ask for an audit, a program or the student's record
/// (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md, "Observed on 2026-11-10"). So this
/// class does not imitate those requests. It loads the page, lets the page run
/// its own sign-in popup, and then calls the page's own functions through the
/// scripts in `PathScripts`, each of which hands back an allowlisted JSON
/// string. The token, the student's id, the first name and the rendered audit
/// HTML never cross into Swift (the five binding rules of the spec's "rewrite
/// contract"), and nothing is stored in the Keychain for this feature: it
/// replaces the old session reader, native client and token store outright.
///
/// **The popup.** The page signs in with `window.open(...)` to Penn's SSO, and
/// the popup's last page calls a function on its OPENER to deliver the token.
/// So `createWebViewWith` must return a child built from the configuration
/// WebKit passes in. A child built from a fresh configuration has no opener
/// and the hand-off silently never happens; that is the wrong fix to avoid.
/// Only a popup aimed at `PathPage.authHost` is allowed at all.
///
/// **The one-submission rule** is carried over from the old reader: if the
/// popup lands on Penn's PennKey form, the saved pair is filled and submitted
/// at most once per sign-in attempt, only on a `PennKeyLoginForm` host after
/// `detectFormScript` confirms a real form is on the page. A second sighting
/// means the password was refused or Duo bounced, and resubmitting could lock
/// the PennKey account. Duo's own buttons are tapped by `DuoPromptAutoTap`
/// (its user script and handler are installed on the shared configuration, so
/// the popup gets them too).
///
/// **One PennKey, one submission budget.** "Once per attempt" alone is not a
/// budget: attempts are cheap (a student's tap starts one), so a wrong saved
/// password would be retyped on every tap and lock the account. The silent
/// Canvas renewer already has the account-level budget, kept in persisted
/// records (`lastCredentialSubmissionAtV1`, `lastFailedCredentialSubmissionAtV1`,
/// the "password rejected" latch). The portal reads and stamps those same
/// records through `CredentialBudget` and the three `onCredential…` hooks that
/// `AppState+Degree` binds, and applies the renewer's own spacings
/// (`foregroundCredentialSpacing`, `failedSubmissionSpacing`), so whoever
/// spends the budget, the other sees it. The wrong fix is a second, private
/// budget in the portal: two budgets for one account is exactly twice the
/// lock-out risk. `force` skips only the 60-second attempt throttle.
///
/// **Privacy of the log.** DEBUG only, step names and outcomes, hosts of the
/// popup's pages: never a token, an id, a name, a query string or a course.
@MainActor
final class PathPortal: NSObject, WKUIDelegate {
    enum SignIn: Sendable, Equatable {
        case ready
        case needsDuo
        case noCanvasSession
        case blocked
        case timedOut
        case throttled
    }

    /// How long one page script may take before the call is abandoned. The
    /// page's promise can simply never settle (a dropped request inside Penn's
    /// own script), and without a deadline the continuation never resumes and
    /// the whole feature hangs on `.reading`.
    nonisolated static let scriptTimeout: TimeInterval = 30
    /// The audit runs Penn's translator server-side and is the slow call.
    nonisolated static let auditTimeout: TimeInterval = 90
    private static let readyWait: TimeInterval = 20
    private static let signInWait: TimeInterval = 60
    private static let signInWaitAfterDuo: TimeInterval = 120
    private static let minimumAttemptInterval: TimeInterval = 60
    private static let pollNanoseconds: UInt64 = 500_000_000

    /// What the shared PennKey budget says right now (see the type's header).
    struct CredentialBudget: Sendable, Equatable {
        var lastSubmission: Date?
        var lastFailedSubmission: Date?
        var passwordRejected: Bool
        var autoLoginEnabled: Bool
    }

    /// Bound by `AppState+Degree` before every use. Unbound means the fill is
    /// refused: a portal that cannot see the budget must not spend it.
    var credentialBudget: (() -> CredentialBudget)?
    var onCredentialSubmitted: ((Date) -> Void)?
    var onCredentialFailed: ((Date) -> Void)?
    var onCredentialRejected: (() -> Void)?

    private var configuration: WKWebViewConfiguration?
    private var webView: WKWebView?
    private var popup: WKWebView?
    private var popupDelegate: PathPopupDelegate?
    private var mainDelegate: PathMainDelegate?

    /// The attempt in progress, if any. A second caller JOINS it and gets its
    /// answer; it used to be turned away with `.throttled`, which the callers
    /// showed as a failure while the real read was still going.
    private var inFlight: Task<SignIn, Never>?
    private var lastAttemptEndedAt: Date?
    private var duoReached = false
    /// True once this attempt has filled the form. Reset at the top of each
    /// attempt; the cross-attempt limit is the shared budget, not this flag.
    private var hasSubmittedCredentials = false
    private var bounceHandled = false
    /// The page must be loaded again before the next sign-in: its in-memory
    /// token died with the session, or its content process was killed.
    private var needsReload = false

    // MARK: Pure rules

    /// Whether the saved PennKey may be typed into Penn's form now. The same
    /// rule as `CanvasSessionRenewer.credentialSubmissionAllowed` in a
    /// foreground attempt, built on the renewer's own spacing constants (that
    /// function is main-actor isolated, so it cannot be called from here), plus
    /// the two latches: a password Penn rejected, or auto-login being off.
    nonisolated static func mayFillCredential(
        now: Date,
        lastSubmission: Date?,
        lastFailedSubmission: Date?,
        passwordRejected: Bool,
        autoLoginEnabled: Bool
    ) -> Bool {
        guard autoLoginEnabled, !passwordRejected else { return false }
        if let lastFailedSubmission,
           now.timeIntervalSince(lastFailedSubmission) < CanvasSessionRenewer.failedSubmissionSpacing {
            return false
        }
        if let lastSubmission,
           now.timeIntervalSince(lastSubmission) < CanvasSessionRenewer.foregroundCredentialSpacing {
            return false
        }
        return true
    }

    // MARK: Sign-in

    /// Signs in (or confirms the page already is). Concurrent callers share one
    /// attempt.
    func ensureSignedIn(force: Bool = false) async -> SignIn {
        if let running = inFlight { return await running.value }
        let task = Task { @MainActor [self] in await self.performSignIn(force: force) }
        inFlight = task
        let result = await task.value
        // Only the owner clears, and only its own task: `reset()` may already
        // have replaced it.
        if inFlight == task { inFlight = nil }
        return result
    }

    /// The page's session is no good (a call failed while the page still held
    /// a token): load the home page again at the next sign-in, which drops the
    /// in-memory token. Cookies and the WebView stay.
    func invalidateSession() {
        needsReload = true
        log("session invalidated")
    }

    private func performSignIn(force: Bool) async -> SignIn {
        // The clock-stale set is used on purpose (the old session reader
        // did the same): `load` applies the 24-hour rule and returns nothing
        // for a day-old session, but Penn's SSO may still honour it, and when
        // it does not the saved PennKey fill is the silent renewal. Only a
        // phone with neither has nothing to start from.
        let canvasCookies = SessionCookieStore.loadIncludingClockStale(service: .canvas)
        guard !canvasCookies.isEmpty || PennKeyCredentialStore.hasCredentials else {
            return .noCanvasSession
        }
        defer { releasePopup() }

        let view = makeWebViewIfNeeded()
        await inject(canvasCookies)

        // After an invalidation the old document is still on screen until the
        // new one commits, and it still says it has a token. Mark it first and
        // do not believe a readiness answer until the mark is gone.
        var awaitingFreshPage = false
        let reloading = needsReload
        if reloading || view.url?.host?.lowercased() != PathPage.host {
            needsReload = false
            if reloading {
                awaitingFreshPage = (await run(Self.markStaleScript, name: "mark", timeout: 5)) == "ok"
            }
            log("loading home")
            view.load(URLRequest(url: PathPage.homeURL))
        }

        // Wait for the page's own globals to exist.
        let readyDeadline = Date().addingTimeInterval(Self.readyWait)
        var pageReady = false
        var tokenPresent = false
        var challengeTitle = false
        while Date() < readyDeadline {
            if Task.isCancelled || webView == nil { return .timedOut }
            if awaitingFreshPage,
               await run(Self.freshnessScript, name: "fresh", timeout: 5) == "fresh" {
                awaitingFreshPage = false
            }
            if !awaitingFreshPage, let state = await readiness() {
                challengeTitle = PathPage.looksLikeChallenge(title: state.title)
                if state.page {
                    pageReady = true
                    tokenPresent = state.token
                    break
                }
            }
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }
        guard pageReady else {
            if challengeTitle {
                log("blocked: challenge title")
                return .blocked
            }
            log("page not ready")
            return .timedOut
        }
        log("page ready")
        if tokenPresent {
            log("token present")
            return .ready
        }

        // A sign-in attempt costs the student a possible Duo push, so a new
        // one is spaced from the END of the last failed one, even when the
        // caller is a retry loop. (The stamp used to be taken at the start,
        // so by the time an attempt had failed after its 60 seconds the
        // spacing was already used up and never throttled anything.)
        // `force` is a student's own tap and skips only this.
        let startedAt = Date()
        if !force, let last = lastAttemptEndedAt,
           startedAt.timeIntervalSince(last) < Self.minimumAttemptInterval {
            return .throttled
        }
        duoReached = false
        hasSubmittedCredentials = false
        bounceHandled = false

        guard let openJSON = await run(PathScripts.openSignIn, name: "openSignIn") else {
            log("sign-in script failed")
            return concludeAttempt(.timedOut)
        }
        guard PathBridgeDecoder.opened(openJSON) else {
            log("popup not opened")
            return concludeAttempt(.timedOut)
        }
        log("popup opened")

        while true {
            if Task.isCancelled || webView == nil { return concludeAttempt(.timedOut) }
            let limit = duoReached ? Self.signInWaitAfterDuo : Self.signInWait
            if Date().timeIntervalSince(startedAt) >= limit { break }
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            if let state = await readiness(), state.token {
                log("token arrived")
                return .ready
            }
        }
        if duoReached {
            log("duo not approved in time")
            return concludeAttempt(.needsDuo)
        }
        log("sign-in timed out")
        return concludeAttempt(.timedOut)
    }

    /// Every way an attempt ends without a token goes through here: it starts
    /// the 60-second spacing, and an attempt that typed the password and did
    /// not get a session counts against the shared failed-submission budget,
    /// exactly as a foreground renewer attempt does.
    private func concludeAttempt(_ result: SignIn) -> SignIn {
        guard result != .ready else { return result }
        let now = Date()
        lastAttemptEndedAt = now
        if hasSubmittedCredentials { onCredentialFailed?(now) }
        return result
    }

    // MARK: Reads

    func degrees() async -> [StudentDegree] {
        guard let json = await run(PathScripts.degrees, name: "degrees") else { return [] }
        let found = PathBridgeDecoder.degrees(json)
        if found.isEmpty { log("degrees: empty") }
        return found
    }

    /// The audit for one `degreeInfo`, already cut down in the page. `data` is
    /// nil on any failure, with the page's own (short) error text when it gave
    /// one.
    func auditData(degreeInfo: [String: String]) async -> (data: Data?, error: String?) {
        let arguments: [String: Any] = ["degreeInfo": degreeInfo]
        guard let json = await run(
            PathScripts.audit, name: "audit", arguments: arguments, timeout: Self.auditTimeout
        ) else {
            log("audit: no answer")
            return (nil, "no answer")
        }
        // The page's own wording is handed back to the caller and never
        // written to the debug log: it is text the page supplied.
        if let message = PathBridgeDecoder.error(json) {
            log("audit: page error")
            return (nil, message)
        }
        guard let data = PathBridgeDecoder.auditData(json) else {
            log("audit: no blocks")
            return (nil, "no blocks")
        }
        return (data, nil)
    }

    func programs() async -> [PathProgramListing] {
        guard let json = await run(PathScripts.programs, name: "programs") else { return [] }
        return PathBridgeDecoder.programs(json)
    }

    func programInfo(code: String) async -> PathProgramInfo? {
        let arguments: [String: Any] = ["code": code]
        guard let json = await run(PathScripts.programInfo, name: "programInfo", arguments: arguments) else { return nil }
        return PathBridgeDecoder.programInfo(json)
    }

    /// Course codes per term from the student's record; nil when the page did
    /// not answer, which the caller treats as "keep what you had".
    func history() async -> PathHistory? {
        guard let json = await run(PathScripts.history, name: "history") else { return nil }
        let found = PathBridgeDecoder.history(json)
        if found == nil { log("history: no answer") }
        return found
    }

    func dictionaries() async -> PathDictionaries? {
        guard let json = await run(PathScripts.dictionaries, name: "dictionaries") else { return nil }
        return PathBridgeDecoder.dictionaries(json)
    }

    // MARK: Teardown

    /// Drops both WebViews and the throttle. Called on a Canvas disconnect and
    /// a school switch. It does not purge cookies: the disconnect path owns
    /// that, and the data store is shared with the Canvas login.
    func reset() {
        releasePopup()
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
        }
        configuration?.userContentController.removeScriptMessageHandler(forName: DuoPromptAutoTap.handlerName)
        configuration?.userContentController.removeAllUserScripts()
        webView = nil
        configuration = nil
        mainDelegate = nil
        inFlight?.cancel()
        inFlight = nil
        lastAttemptEndedAt = nil
        duoReached = false
        hasSubmittedCredentials = false
        bounceHandled = false
        needsReload = false
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Only the page's own sign-in popup, and only from the main view.
        guard webView === self.webView,
              let host = navigationAction.request.url?.host?.lowercased(),
              host == PathPage.authHost
        else { return nil }
        releasePopup()
        // Built from the configuration WebKit passed in, never a new one: that
        // is what keeps `window.opener` alive for the token hand-off.
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.customUserAgent = LoginUserAgent.mobileSafari
        let delegate = PathPopupDelegate(portal: self)
        child.navigationDelegate = delegate
        child.uiDelegate = self
        popup = child
        popupDelegate = delegate
        log("popup opened: \(host)")
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popup else { return }
        log("popup closed")
        releasePopup()
    }

    // MARK: Popup callbacks (from `PathPopupDelegate`)

    fileprivate func popupDidFinish(_ child: WKWebView) {
        guard child === popup else { return }
        let url = child.url
        log("popup at \(url?.host?.lowercased() ?? "(no host)")")
        if PennKeyLoginForm.isDuo(url) {
            // Arriving on Duo after a submission means a push is (or will be)
            // waiting; the deadline moves out to two minutes.
            if !duoReached { log("duo reached") }
            duoReached = true
            return
        }
        guard PennKeyLoginForm.isLoginForm(url) else { return }
        Task { @MainActor [weak self, weak child] in
            guard let self, let child else { return }
            await self.considerCredentialForm(child)
        }
    }

    /// Fills the saved PennKey into Penn's credential form, once per attempt
    /// and only inside the shared budget; and, when the form comes back after
    /// our own fill, reads why.
    private func considerCredentialForm(_ child: WKWebView) async {
        guard child === popup, !bounceHandled else { return }
        let submittedAtStart = hasSubmittedCredentials
        // WebKit's `Any?` is narrowed to `String?` inside the handler: `Any?`
        // is not `Sendable` and cannot cross the continuation.
        let detected: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            child.evaluateJavaScript(PennKeyLoginForm.detectFormScript) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        // Re-check after the await: the attempt may have ended, and another
        // sighting may have filled meanwhile (that one is not a bounce for
        // this call). Nothing may sit between these checks and the flags.
        guard child === popup, !bounceHandled, hasSubmittedCredentials == submittedAtStart,
              PennKeyLoginForm.isLoginForm(child.url)
        else { return }
        let presence = PennKeyLoginForm.presence(from: detected)
        guard presence == .form || presence == .formError else { return }

        if hasSubmittedCredentials {
            // The form is back after OUR fill in this attempt. The renewer's
            // rule, exactly: only error text that names the credential counts
            // as a rejection (a Duo denial that bounces to the form does not),
            // and either way there is no second submission.
            bounceHandled = true
            let text: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                child.evaluateJavaScript(PennKeyLoginForm.errorTextScript) { value, _ in
                    continuation.resume(returning: value as? String)
                }
            }
            guard child === popup else { return }
            if PennKeyLoginForm.errorTextIndicatesBadCredential(text) {
                log("form bounce: credential error")
                onCredentialRejected?()
            } else {
                log("form bounce: no credential error")
            }
            return
        }

        guard let budget = credentialBudget?() else {
            log("credential fill skipped: budget unbound")
            return
        }
        guard Self.mayFillCredential(
            now: Date(),
            lastSubmission: budget.lastSubmission,
            lastFailedSubmission: budget.lastFailedSubmission,
            passwordRejected: budget.passwordRejected,
            autoLoginEnabled: budget.autoLoginEnabled
        ) else {
            // Not an error: the attempt waits on Penn's form until its
            // deadline and ends `.timedOut`.
            log("credential fill skipped: within budget")
            return
        }
        guard let credentials = PennKeyCredentialStore.load() else {
            log("credential fill skipped: none saved")
            return
        }
        hasSubmittedCredentials = true
        onCredentialSubmitted?(Date())
        log("login form filled")
        child.evaluateJavaScript(
            PennKeyLoginForm.fillAndSubmitScript(username: credentials.username, password: credentials.password),
            completionHandler: nil
        )
    }

    fileprivate func contentProcessDied() {
        needsReload = true
        log("content process terminated")
    }

    // MARK: Plumbing

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = LoginDataStores.canvas
        // Without this the page's `window.open` is swallowed and the sign-in
        // never starts.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let duoHandler = DuoPromptMessageHandler { [weak self] event in
            if event == .push { self?.noteDuoPush() }
        }
        configuration.userContentController.add(duoHandler, name: DuoPromptAutoTap.handlerName)
        configuration.userContentController.addUserScript(DuoPromptAutoTap.makeUserScript())

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        view.customUserAgent = LoginUserAgent.mobileSafari
        view.uiDelegate = self
        // Its only job is to hear that the content process died, so the next
        // sign-in loads the page again instead of reading a blank view.
        let delegate = PathMainDelegate(portal: self)
        view.navigationDelegate = delegate
        self.mainDelegate = delegate
        self.configuration = configuration
        self.webView = view
        return view
    }

    private func noteDuoPush() {
        if !duoReached { log("duo reached") }
        duoReached = true
    }

    private func releasePopup() {
        popup?.stopLoading()
        popup?.navigationDelegate = nil
        popup?.uiDelegate = nil
        popup = nil
        popupDelegate = nil
    }

    /// Present the Keychain's Canvas session first: a fresh WebView has none
    /// (WebKit drops session cookies between launches), and Penn's SSO would
    /// send the popup to the login form. Same fix as `EdSessionLauncher`.
    private func inject(_ cookies: [HTTPCookie]) async {
        for cookie in cookies {
            await LoginDataStores.canvas.httpCookieStore.setCookie(cookie)
        }
    }

    private func readiness() async -> PathBridgeDecoder.Readiness? {
        guard let json = await run(PathScripts.readiness, name: "readiness") else { return nil }
        return PathBridgeDecoder.readiness(json)
    }

    /// Runs one `PathScripts` body in the page's own world (its globals live
    /// there) and returns the JSON string it produced, or nil on any failure.
    ///
    /// The completion-handler form (two `in` labels: frame, then content
    /// world), not the `async throws` overload: that one returns `Any?`,
    /// which is not `Sendable`, and letting it cross an await is the
    /// "sending value risks causing data races" error `EdDiscussionProbe`
    /// and `CanvasSessionRenewer` already hit and document. The result is
    /// narrowed to a `String?` inside the handler, before it crosses the
    /// continuation.
    private func run(
        _ body: String,
        name: String,
        arguments: [String: Any] = [:],
        timeout: TimeInterval = PathPortal.scriptTimeout
    ) async -> String? {
        guard let view = webView else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // The page may never settle its promise, and the continuation must
            // resume exactly once whichever of the call and the timer comes
            // first; the late one is dropped by the box. A task group that
            // awaited the hung call would hang with it, which is the wrong fix.
            let box = PathOneShot(continuation)
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case let .success(value):
                    box.finish(value as? String)
                case .failure:
                    box.finish(nil)
                }
            }
            let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                if box.finish(nil) { self?.log("script timed out: \(name)") }
            }
        }
    }

    /// Two tiny page scripts of the portal's own, outside `PathScripts` on
    /// purpose: they read and write nothing but a marker on `window`.
    private static let markStaleScript = "window.__smoothStale = true; return \"ok\";"
    private static let freshnessScript = "return window.__smoothStale ? \"stale\" : \"fresh\";"

    private func log(_ line: String) {
        #if DEBUG
        DebugDegreeLog.record(line)
        #endif
    }
}

/// Watches the sign-in popup. Observe-only: it never cancels or redirects a
/// navigation, and leaves every decision to `PathPortal`.
@MainActor
private final class PathPopupDelegate: NSObject, WKNavigationDelegate {
    private weak var portal: PathPortal?

    init(portal: PathPortal) {
        self.portal = portal
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        portal?.popupDidFinish(webView)
    }
}

/// Resumes a continuation exactly once, from whichever thread gets there first.
/// `finish` returns true only for the call that actually resumed it.
private final class PathOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ value: String?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(returning: value)
        return true
    }
}

/// Hears that the main page's content process was killed (WebKit reclaims it
/// under memory pressure). Nothing else.
@MainActor
private final class PathMainDelegate: NSObject, WKNavigationDelegate {
    private weak var portal: PathPortal?

    init(portal: PathPortal) {
        self.portal = portal
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        portal?.contentProcessDied()
    }
}
