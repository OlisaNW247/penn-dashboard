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

    private static let readyWait: TimeInterval = 20
    private static let signInWait: TimeInterval = 60
    private static let signInWaitAfterDuo: TimeInterval = 120
    private static let minimumAttemptInterval: TimeInterval = 60
    private static let pollNanoseconds: UInt64 = 500_000_000

    private var configuration: WKWebViewConfiguration?
    private var webView: WKWebView?
    private var popup: WKWebView?
    private var popupDelegate: PathPopupDelegate?

    private var isEnsuring = false
    private var lastAttemptStartedAt: Date?
    private var duoReached = false
    private var hasSubmittedCredentials = false

    // MARK: Sign-in

    func ensureSignedIn(force: Bool = false) async -> SignIn {
        guard !isEnsuring else { return .throttled }

        // The clock-stale set is used on purpose (the old session reader
        // did the same): `load` applies the 24-hour rule and returns nothing
        // for a day-old session, but Penn's SSO may still honour it, and when
        // it does not the saved PennKey fill is the silent renewal. Only a
        // phone with neither has nothing to start from.
        let canvasCookies = SessionCookieStore.loadIncludingClockStale(service: .canvas)
        guard !canvasCookies.isEmpty || PennKeyCredentialStore.hasCredentials else {
            return .noCanvasSession
        }
        isEnsuring = true
        defer {
            isEnsuring = false
            releasePopup()
        }

        let view = makeWebViewIfNeeded()
        await inject(canvasCookies)

        if view.url?.host?.lowercased() != PathPage.host {
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
            if let state = await readiness() {
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
        // one is spaced even when the caller is a retry loop.
        let startedAt = Date()
        if !force, let last = lastAttemptStartedAt,
           startedAt.timeIntervalSince(last) < Self.minimumAttemptInterval {
            return .throttled
        }
        lastAttemptStartedAt = startedAt
        duoReached = false
        hasSubmittedCredentials = false

        guard let openJSON = await run(PathScripts.openSignIn) else {
            log("sign-in script failed")
            return .timedOut
        }
        guard PathBridgeDecoder.opened(openJSON) else {
            log("popup not opened")
            return .timedOut
        }
        log("popup opened")

        while true {
            if Task.isCancelled || webView == nil { return .timedOut }
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
            return .needsDuo
        }
        log("sign-in timed out")
        return .timedOut
    }

    // MARK: Reads

    func degrees() async -> [StudentDegree] {
        guard let json = await run(PathScripts.degrees) else { return [] }
        return PathBridgeDecoder.degrees(json)
    }

    /// The audit for one `degreeInfo`, already cut down in the page. `data` is
    /// nil on any failure, with the page's own (short) error text when it gave
    /// one.
    func auditData(degreeInfo: [String: String]) async -> (data: Data?, error: String?) {
        let arguments: [String: Any] = ["degreeInfo": degreeInfo]
        guard let json = await run(PathScripts.audit, arguments: arguments) else {
            log("audit error: no answer")
            return (nil, "no answer")
        }
        if let message = PathBridgeDecoder.error(json) {
            log("audit error: \(message)")
            return (nil, message)
        }
        guard let data = PathBridgeDecoder.auditData(json) else {
            log("audit error: no blocks")
            return (nil, "no blocks")
        }
        return (data, nil)
    }

    func programs() async -> [PathProgramListing] {
        guard let json = await run(PathScripts.programs) else { return [] }
        return PathBridgeDecoder.programs(json)
    }

    func programInfo(code: String) async -> PathProgramInfo? {
        let arguments: [String: Any] = ["code": code]
        guard let json = await run(PathScripts.programInfo, arguments: arguments) else { return nil }
        return PathBridgeDecoder.programInfo(json)
    }

    func dictionaries() async -> PathDictionaries? {
        guard let json = await run(PathScripts.dictionaries) else { return nil }
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
        lastAttemptStartedAt = nil
        duoReached = false
        hasSubmittedCredentials = false
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

    /// Fills the saved PennKey into Penn's credential form, once per attempt.
    private func considerCredentialForm(_ child: WKWebView) async {
        guard !hasSubmittedCredentials, child === popup else { return }
        // WebKit's `Any?` is narrowed to `String?` inside the handler: `Any?`
        // is not `Sendable` and cannot cross the continuation.
        let detected: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            child.evaluateJavaScript(PennKeyLoginForm.detectFormScript) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        // Re-check after the await: the attempt may have ended, and nothing
        // may sit between this check and the flag below.
        guard !hasSubmittedCredentials, child === popup, PennKeyLoginForm.isLoginForm(child.url) else { return }
        let presence = PennKeyLoginForm.presence(from: detected)
        guard presence == .form || presence == .formError else { return }
        guard let credentials = PennKeyCredentialStore.load() else {
            log("credential fill skipped: none saved")
            return
        }
        hasSubmittedCredentials = true
        log("login form filled")
        child.evaluateJavaScript(
            PennKeyLoginForm.fillAndSubmitScript(username: credentials.username, password: credentials.password),
            completionHandler: nil
        )
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
        guard let json = await run(PathScripts.readiness) else { return nil }
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
    private func run(_ body: String, arguments: [String: Any] = [:]) async -> String? {
        guard let view = webView else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case let .success(value):
                    continuation.resume(returning: value as? String)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

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
