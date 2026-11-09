import Foundation
import WebKit
import LowHangingFruitKit

/// Opens Penn's Degree Works dashboard in a hidden `WKWebView`, rides the
/// student's existing Canvas/PennKey session through Penn's SSO, and hands
/// back the two token cookies Degree Works sets when it lets them in
/// (`DegreeWorksTokens`), so `DegreeWorksClient` can read the audit natively.
///
/// **Why a WebView.** Degree Works has no API key and no sign-in the app can
/// drive: the only way a student is "logged in" is that Penn WebLogin's SAML
/// hop bounces back with `X-AUTH-TOKEN` and `REFRESH_TOKEN` set. That chain
/// is redirects and auto-submitting forms that only a browser engine follows,
/// the same reason `EdSessionLauncher` exists. The shape is deliberately the
/// same (one `load`, `LoginDataStores.canvas`, Keychain Canvas cookies
/// injected first, mobile Safari user agent, `SettleWaiter`) so what is
/// proven for Ed carries over.
///
/// **The one-submission rule.** If the chain lands on Penn's credential form
/// (the Canvas session did not cover Degree Works' SAML request), the saved
/// PennKey pair is filled and submitted AT MOST ONCE per read, and only on a
/// `PennKeyLoginForm` host after `detectFormScript` confirms a real form is
/// on the page. A second sighting of the form means the password was refused
/// or Duo bounced; resubmitting would risk locking the PennKey account, so
/// the read simply runs out its clock. The SAML response form the browser
/// posts back is never touched. Duo's own buttons are tapped by
/// `DuoPromptAutoTap`, exactly as the silent renewer does in the foreground.
///
/// **Unverified.** The entry URL (`DegreeWorksEndpoints.dashboardPath`) and
/// the claim that the token cookies appear on the Degree Works host have not
/// been observed against Penn's live system (2026-11-09).
///
/// **Privacy.** A token leaves this file only through `Outcome.landed`; the
/// caller stores it in the Keychain. The log carries words and host/path
/// only: never a token, a query string, a cookie value or a body.
///
/// **Throttling.** One read in flight, and at most one per 10 minutes unless
/// forced; a broken read must not become a retry storm against Penn's SSO.
@MainActor
final class DegreeWorksSessionReader {
    enum Outcome: Sendable {
        /// The chain landed on Degree Works and both cookies (or at least the
        /// auth one) were in the store.
        case landed(DegreeWorksTokens, finalPage: String)
        /// Duo was reached and nobody approved it before the cap.
        case needsDuo(finalPage: String)
        /// The chain settled but no token cookie exists.
        case noSession(finalPage: String)
        /// The hard timeout fired.
        case timedOut(finalPage: String)
        /// Another read is in flight, or one ran under 10 minutes ago.
        case throttled
        /// The Keychain holds no Canvas cookies; nothing was loaded.
        case noCanvasSession
    }

    nonisolated fileprivate static let settleAfterLanding: TimeInterval = 3
    private static let hardTimeout: TimeInterval = 60
    private static let hardTimeoutAfterDuo: TimeInterval = 120
    private static let minimumInterval: TimeInterval = 10 * 60

    /// `navigationDelegate` is weak, so the WebView, delegate and waiter are
    /// held here across the `await` and released in one `defer`
    /// (`CanvasSessionRenewer.activeWebView` explains).
    private var activeWebView: WKWebView?
    private var activeDelegate: DegreeWorksNavigationDelegate?
    private var activeWaiter: SettleWaiter?

    private var isReading = false
    private var lastReadAt: Date?

    /// Forgets when the last read ran. Called on a Canvas disconnect: the
    /// 10 minutes belonged to the old account. Does not interrupt a read.
    func resetThrottle() {
        lastReadAt = nil
    }

    func read(force: Bool = false) async -> Outcome {
        guard !isReading else { return .throttled }
        if !force, let lastReadAt, Date().timeIntervalSince(lastReadAt) < Self.minimumInterval {
            return .throttled
        }
        // Checked before the throttle clock starts: a read that loaded
        // nothing must not cost the next real attempt 10 minutes.
        // The clock-stale set is used on purpose: `load` applies the 24-hour
        // rule and returns nothing for a day-old session, but Penn's SSO may
        // still honour it, and when it does not the saved PennKey fill below
        // is the silent renewal. Only a phone with neither cookies nor a saved
        // PennKey has nothing to start from.
        let canvasCookies = SessionCookieStore.loadIncludingClockStale(service: .canvas)
        guard !canvasCookies.isEmpty || PennKeyCredentialStore.hasCredentials else {
            return .noCanvasSession
        }
        isReading = true
        // The throttle clock is stamped only when a read lands (just before `.landed` returns): a
        // read that found no session, waited on Duo or timed out must not
        // cost the student's retry ten minutes.
        defer { isReading = false }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = LoginDataStores.canvas

        let waiter = SettleWaiter()
        let delegate = DegreeWorksNavigationDelegate(waiter: waiter)
        // Foreground only: a Duo push needs a person, and this feature never
        // runs from a background wake. The handler is removed in `defer`.
        let duoHandler = DuoPromptMessageHandler { [weak delegate] event in
            if event == .push { delegate?.noteDuoPush() }
        }
        configuration.userContentController.add(duoHandler, name: DuoPromptAutoTap.handlerName)
        configuration.userContentController.addUserScript(DuoPromptAutoTap.makeUserScript())

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = LoginUserAgent.mobileSafari
        webView.navigationDelegate = delegate
        activeWebView = webView
        activeDelegate = delegate
        activeWaiter = waiter
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: DuoPromptAutoTap.handlerName)
            activeWebView?.navigationDelegate = nil
            activeWebView = nil
            activeDelegate = nil
            activeWaiter = nil
        }

        // Present the Keychain's Canvas session first: a fresh hidden WebView
        // has none (WebKit drops session cookies between launches), and
        // Penn's SSO would send it to the login form. Same fix and same
        // reason as `EdSessionLauncher`.
        for cookie in canvasCookies {
            await LoginDataStores.canvas.httpCookieStore.setCookie(cookie)
        }

        // Exactly one `load`: a second could restart the SAML chain.
        let entry = DegreeWorksEndpoints.baseURL.appendingPathComponent(DegreeWorksEndpoints.dashboardPath)
        #if DEBUG
        DebugDegreeLog.record("read: loading \(entry.host ?? "(no host)")\(entry.path)")
        #endif
        webView.load(URLRequest(url: entry))

        // The deadline moves out to 120 s once Duo is reached, so the timer
        // re-checks instead of sleeping one fixed span.
        let started = Date()
        let timeoutTask = Task { @MainActor [weak waiter, weak delegate] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                let limit = (delegate?.duoReached ?? false) ? Self.hardTimeoutAfterDuo : Self.hardTimeout
                if Date().timeIntervalSince(started) >= limit {
                    waiter?.signal(.timedOut)
                    return
                }
            }
        }
        let signal = await waiter.wait()
        timeoutTask.cancel()

        let finalURL = webView.url
        let finalPage = Self.hostPath(finalURL) ?? "(no page)"
        #if DEBUG
        DebugDegreeLog.record("read: settled \(finalPage)")
        #endif

        switch signal {
        case .timedOut, .aborted, .failed:
            if delegate.duoReached && PennKeyLoginForm.isDuo(finalURL) {
                return .needsDuo(finalPage: finalPage)
            }
            if case .failed = signal { return .noSession(finalPage: finalPage) }
            return .timedOut(finalPage: finalPage)
        case .finished:
            break
        }

        let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.canvas.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        guard let tokens = DegreeWorksTokens.from(cookies: allCookies) else {
            return .noSession(finalPage: finalPage)
        }
        lastReadAt = Date()
        return .landed(tokens, finalPage: finalPage)
    }

    /// Host and path only, never the query string.
    private static func hostPath(_ url: URL?) -> String? {
        guard let url, let host = url.host else { return nil }
        return "\(host)\(url.path)"
    }
}

/// Watches one chain. It always allows navigation and never re-navigates; the
/// only thing it may do to a page is the single credential fill described on
/// `DegreeWorksSessionReader`, and only on a Penn IdP host.
@MainActor
private final class DegreeWorksNavigationDelegate: NSObject, WKNavigationDelegate {
    private let waiter: SettleWaiter
    /// Settling starts once: a single-page app can fire `didFinish` again.
    private var hasSeenDegreeWorks = false
    /// The one submission this read may make.
    private var hasSubmittedCredentials = false
    private(set) var duoReached = false

    init(waiter: SettleWaiter) {
        self.waiter = waiter
    }

    func noteDuoPush() {
        duoReached = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let url = webView.url
        #if DEBUG
        DebugDegreeLog.record("finished: \(url?.host ?? "(no host)")\(url?.path ?? "")")
        #endif
        if let host = url?.host, host.localizedCaseInsensitiveContains(DegreeWorksEndpoints.host) {
            guard !hasSeenDegreeWorks else { return }
            hasSeenDegreeWorks = true
            Task { @MainActor [weak waiter] in
                try? await Task.sleep(nanoseconds: UInt64(DegreeWorksSessionReader.settleAfterLanding * 1_000_000_000))
                guard !Task.isCancelled else { return }
                waiter?.signal(.finished)
            }
            return
        }
        if PennKeyLoginForm.isDuo(url) {
            // Arriving on Duo after a submission means a push is (or will be)
            // waiting; the deadline moves out to two minutes. Never settle
            // here: Duo's own page finishes before its redirect back
            // (`CanvasSessionRenewer`, round 3 of 2026-09-21).
            duoReached = true
            return
        }
        guard PennKeyLoginForm.isLoginForm(url) else { return }
        Task { @MainActor [weak self] in
            await self?.considerCredentialForm(webView)
        }
    }

    /// Fills the saved PennKey into Penn's credential form, once.
    private func considerCredentialForm(_ webView: WKWebView) async {
        guard !hasSubmittedCredentials, !waiter.isSettled else { return }
        // WebKit's `Any?` is narrowed to `String?` inside the handler: `Any?`
        // is not `Sendable` and cannot cross the continuation.
        let detected: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(PennKeyLoginForm.detectFormScript) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        // Re-check after the await: the read may have ended, and nothing may
        // sit between this check and the flag below that could interleave.
        guard !hasSubmittedCredentials, !waiter.isSettled,
              PennKeyLoginForm.isLoginForm(webView.url)
        else { return }
        let presence = PennKeyLoginForm.presence(from: detected)
        #if DEBUG
        DebugDegreeLog.record("login form check: \(presence.rawValue)")
        #endif
        guard presence == .form || presence == .formError else { return }
        guard let credentials = PennKeyCredentialStore.load() else {
            #if DEBUG
            DebugDegreeLog.record("credential fill skipped: none saved")
            #endif
            return
        }
        hasSubmittedCredentials = true
        webView.evaluateJavaScript(
            PennKeyLoginForm.fillAndSubmitScript(username: credentials.username, password: credentials.password),
            completionHandler: nil
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func fail(_ error: Error) {
        guard !Self.isBenignInterruption(error) else { return }
        #if DEBUG
        let nsError = error as NSError
        DebugDegreeLog.record("navigation failed: \(nsError.domain)/\(nsError.code)")
        #endif
        waiter.signal(.failed)
    }

    /// `NSURLErrorCancelled` is one hop interrupted by the next, routine in
    /// an SSO chain (`CanvasSessionRenewer.isBenignInterruption`).
    private static func isBenignInterruption(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

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
