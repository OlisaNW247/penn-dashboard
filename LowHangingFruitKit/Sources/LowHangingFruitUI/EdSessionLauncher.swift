import Foundation
import WebKit
import LowHangingFruitKit

/// Performs a Canvas course's "Ed Discussion" LTI launch in a hidden
/// `WKWebView` and hands back the Ed session it produced (the `authToken`
/// from Ed's `localStorage`, plus any Ed cookies), so `EdClient` can read
/// Ed's API natively with it (`docs/ED_DISCUSSION.md`).
///
/// **Why a WebView at all.** Ed has no API key and no sign-in the app can
/// drive: the only way a student is "logged in" to Ed is that Canvas's LTI
/// tool signs them in. That launch is a chain of redirects and auto-submitting
/// forms that only a real browser engine follows, and it only succeeds on the
/// Canvas session cookies the login WebView already holds. So the WebView is
/// bound to `LoginDataStores.canvas` (never `.default()` or a fresh store, or
/// there is no session to ride), and it is never added to a view hierarchy.
///
/// **Why this duplicates `EdDiscussionProbe.run`'s WebView code instead of
/// sharing it.** The probe is a DEBUG-only diagnostic (`#if DEBUG`, the type
/// does not exist in a Release build) and may be deleted once the feature is
/// proven; the launcher ships and must not depend on it. The shape is
/// deliberately identical (same configuration, user agent, `SettleWaiter`,
/// settle delay and hard timeout) so what the owner verified with the probe
/// on his phone is what runs here. The wrong version of "share it" is to
/// lift the probe out of `#if DEBUG`: that puts a report-formatting
/// diagnostic, which reads page storage names, into every shipping build.
///
/// **Why a token and not just cookies.** The 2026-10-09 real-phone probe
/// showed Ed's web client keeps its session in `localStorage` (`authToken`),
/// `document.cookie` is empty, and a cookie-only `GET /api/user` is a 401. So
/// after the page settles on an Ed host this reads `authToken` (falling back
/// to `authToken:us`) with `callAsyncJavaScript`, and still harvests any
/// `edstem` cookies as a fallback that costs nothing.
///
/// **Privacy.** The token and the cookies leave this file only through the
/// returned `Outcome`; the caller stores them in the Keychain. Nothing here
/// logs, prints or interpolates a token, a cookie value, a URL query string
/// or a page body; `finalPage` is host and path only, and `EdSession`'s
/// description redacts the token.
///
/// **Throttling.** One launch in flight at a time, and at most one per 30
/// minutes unless `force`: a launch is a full redirect chain through Canvas
/// and Ed, so a sync loop that runs every five minutes must not repeat it,
/// and a broken launch must not turn into a retry storm against Canvas.
@MainActor
final class EdSessionLauncher {
    /// What a landing produced. Either half may be empty, never both (that is
    /// `Outcome.noEdSession`). `description` is redacted so that no string
    /// interpolation or `print` of an outcome can ever reveal the token.
    struct EdSession: Sendable, CustomStringConvertible {
        /// Ed's `authToken` from `localStorage`; the session `EdClient` uses.
        let token: String?
        /// Cookies on an `edstem` domain; empty on the 2026-10-09 phone.
        let cookies: [HTTPCookie]

        var description: String {
            "EdSession(token: \(token == nil ? "absent" : "present"), cookies: \(cookies.count))"
        }
    }

    enum Outcome: Sendable {
        /// The chain landed on Ed and produced a token and/or Ed cookies.
        case landed(session: EdSession, finalPage: String)
        /// The chain settled but there is neither a token nor a cookie on an
        /// `edstem` domain: most likely Canvas bounced the launch to its own
        /// login page.
        case noEdSession(finalPage: String)
        /// The 40 s hard timeout fired before the WebView settled on Ed.
        case timedOut(finalPage: String)
        /// Another launch is in flight, or one ran less than 30 minutes ago.
        case throttled
        /// The Keychain holds no Canvas cookies, so there is nothing to
        /// present to Canvas; nothing was loaded.
        case noCanvasSession
    }

    /// Mirrors `EdDiscussionProbe.settleAfterLandingOnEd`: Ed's single-page
    /// app needs a moment after the first `didFinish` on its host to finish
    /// writing the cookies the API wants. Not measured against a real session.
    nonisolated fileprivate static let settleAfterLandingOnEd: TimeInterval = 3
    /// Same 40 s as the probe: two or three redirects normally finish in a
    /// couple of seconds, and this is headroom for a slow network, not a
    /// target.
    private static let hardTimeout: TimeInterval = 40
    private static let minimumInterval: TimeInterval = 30 * 60

    /// See `CanvasSessionRenewer.activeWebView`: `navigationDelegate` is
    /// weak and the WebView would otherwise have no owner across the `await`
    /// below, so all three are held here and cleared in one `defer`.
    private var activeWebView: WKWebView?
    private var activeDelegate: EdLaunchNavigationDelegate?
    private var activeWaiter: SettleWaiter?

    private var isLaunching = false
    private var lastLaunchAt: Date?

    /// Forgets when the last launch ran, so the next one is not throttled.
    /// Called on a Canvas disconnect: the 30 minutes belonged to the old
    /// account. Does not interrupt a launch in flight.
    func resetThrottle() {
        lastLaunchAt = nil
    }

    func launch(url: URL, force: Bool = false) async -> Outcome {
        guard !isLaunching else { return .throttled }
        if !force, let lastLaunchAt, Date().timeIntervalSince(lastLaunchAt) < Self.minimumInterval {
            return .throttled
        }
        // Checked before the throttle clock starts: a launch that never
        // loaded anything must not cost the next real attempt 30 minutes.
        let canvasCookies = SessionCookieStore.load(service: .canvas)
        guard !canvasCookies.isEmpty else { return .noCanvasSession }
        isLaunching = true
        lastLaunchAt = Date()
        defer { isLaunching = false }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = LoginDataStores.canvas
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = LoginUserAgent.mobileSafari

        let waiter = SettleWaiter()
        let delegate = EdLaunchNavigationDelegate(waiter: waiter)
        webView.navigationDelegate = delegate
        activeWebView = webView
        activeDelegate = delegate
        activeWaiter = waiter
        defer {
            activeWebView?.navigationDelegate = nil
            activeWebView = nil
            activeDelegate = nil
            activeWaiter = nil
        }

        // Present the Keychain's Canvas session to the WebView before it
        // loads anything. The probe's first real-phone run (2026-10-09)
        // showed a fresh hidden WebView on `LoginDataStores.canvas` ends at
        // `weblogin.pennkey.upenn.edu` ("Penn WebLogin"): the app's session
        // lives in the Keychain and is attached to URLSession requests by
        // hand, and WebKit drops session cookies between launches, so
        // Canvas sees no session and redirects to the identity provider.
        // The wrong fix is running `CanvasSessionRenewer` first: it walks
        // the IdP with the stored password and would push Duo whenever
        // trust is absent, while the Keychain session is already valid
        // (the `/tabs` calls just before a launch prove it).
        for cookie in canvasCookies {
            await LoginDataStores.canvas.httpCookieStore.setCookie(cookie)
        }

        // GET-only, exactly one `load`: the probe's discipline, for the
        // same reason. A second load could re-launch the LTI tool.
        webView.load(URLRequest(url: url))

        let timeoutTask = Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hardTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            waiter?.signal(.timedOut)
        }
        let signal = await waiter.wait()
        timeoutTask.cancel()

        let finalPage = Self.hostPath(webView.url) ?? "(no page)"
        if case .timedOut = signal {
            return .timedOut(finalPage: finalPage)
        }

        // Ed's session is a token in the page's localStorage, so it is read
        // first and only while the WebView is on an Ed host.
        let token = await Self.readAuthToken(from: webView)

        // Read-only harvest from the same persistent store the WebView just
        // navigated in, as the probe does. `getAllCookies` is the
        // completion-handler form wrapped in a continuation, the pattern
        // the probe and the renewer both use. Kept as a fallback: on the
        // 2026-10-09 phone it held only an OIDC `state` cookie.
        let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.canvas.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let edCookies = allCookies.filter { $0.domain.localizedCaseInsensitiveContains("edstem") }
        if token == nil && edCookies.isEmpty {
            return .noEdSession(finalPage: finalPage)
        }
        return .landed(session: EdSession(token: token, cookies: edCookies), finalPage: finalPage)
    }

    /// Reads Ed's session token out of the page's `localStorage`:
    /// `authToken`, else `authToken:us` (both keys were present on the
    /// 2026-10-09 phone). `nil` when the WebView is not on an Ed host (so
    /// Canvas's or the identity provider's storage is never read), when
    /// neither key exists, when the value is empty, or when the script fails.
    ///
    /// Uses the completion-handler form of `callAsyncJavaScript` in the
    /// `.page` world, exactly as `EdDiscussionProbe.formattedReport` does
    /// (the page world is where Ed's own client wrote its storage), and
    /// narrows the `Result<Any, Error>` to a `String?` inside the handler:
    /// `Any` must not cross the continuation. The value is returned to the
    /// caller and nowhere else; no failure path puts it, or the script's
    /// error text, into a string.
    ///
    /// Internal rather than private so the DEBUG probe reports on the very
    /// script that ships.
    static func readAuthToken(from webView: WKWebView) async -> String? {
        guard EdHosts.isEd(webView.url) else { return nil }
        let value: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            webView.callAsyncJavaScript(
                #"return localStorage.getItem("authToken") || localStorage.getItem("authToken:us");"#,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                if case let .success(raw) = result, let string = raw as? String, !string.isEmpty {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        return value
    }

    /// Host and path only, never the query string. A private twin of
    /// `CanvasSessionRenewer.hostPathString`, which is `#if DEBUG`.
    private static func hostPath(_ url: URL?) -> String? {
        guard let url, let host = url.host else { return nil }
        return "\(host)\(url.path)"
    }
}

/// Observe-only delegate: settles three seconds after the first `didFinish`
/// on an Ed host, keeps waiting through `didFail*` (a borderless LTI launch
/// can produce one aborted intermediate hop that WebKit reports as a
/// failure), and always allows navigation. Same posture as the probe's
/// delegate and `CanvasSessionRenewer`'s: it never cancels, redirects or
/// re-navigates, so a launch can only ever be one chain.
@MainActor
private final class EdLaunchNavigationDelegate: NSObject, WKNavigationDelegate {
    private let waiter: SettleWaiter
    /// Settle-after-boot must start once: Ed's SPA can fire `didFinish`
    /// again on a same-host client-side navigation.
    private var hasSeenEd = false

    init(waiter: SettleWaiter) {
        self.waiter = waiter
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !hasSeenEd, EdHosts.isEd(webView.url) else { return }
        hasSeenEd = true
        Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(EdSessionLauncher.settleAfterLandingOnEd * 1_000_000_000))
            guard !Task.isCancelled else { return }
            waiter?.signal(.finished)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}

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
