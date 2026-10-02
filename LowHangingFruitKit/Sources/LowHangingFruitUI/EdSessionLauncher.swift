import Foundation
import WebKit
import LowHangingFruitKit

/// Performs a Canvas course's "Ed Discussion" LTI launch in a hidden
/// `WKWebView` and hands back the Ed session cookies it produced, so
/// `EdClient` can read Ed's API natively with them (`docs/ED_DISCUSSION.md`).
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
/// **Privacy.** Only the cookies come out, filtered to a domain containing
/// `edstem`, and the caller stores them in the Keychain. Nothing here logs a
/// cookie value, a URL query string or a page body; `finalPage` is host and
/// path only.
///
/// **Throttling.** One launch in flight at a time, and at most one per 30
/// minutes unless `force`: a launch is a full redirect chain through Canvas
/// and Ed, so a sync loop that runs every five minutes must not repeat it,
/// and a broken launch must not turn into a retry storm against Canvas.
@MainActor
final class EdSessionLauncher {
    enum Outcome: Sendable {
        /// The chain landed on Ed and the store holds Ed cookies.
        case landed(cookies: [HTTPCookie], finalPage: String)
        /// The chain settled but no cookie on an `edstem` domain exists:
        /// most likely Canvas bounced the launch to its own login page.
        case noEdCookies(finalPage: String)
        /// The 40 s hard timeout fired before the WebView settled on Ed.
        case timedOut(finalPage: String)
        /// Another launch is in flight, or one ran less than 30 minutes ago.
        case throttled
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

        // Read-only harvest from the same persistent store the WebView just
        // navigated in, as the probe does. `getAllCookies` is the
        // completion-handler form wrapped in a continuation, the pattern
        // the probe and the renewer both use.
        let allCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.canvas.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let edCookies = allCookies.filter { $0.domain.localizedCaseInsensitiveContains("edstem") }
        return edCookies.isEmpty
            ? .noEdCookies(finalPage: finalPage)
            : .landed(cookies: edCookies, finalPage: finalPage)
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
