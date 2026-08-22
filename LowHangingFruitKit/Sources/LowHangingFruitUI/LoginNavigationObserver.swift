import Foundation
import WebKit
import os

/// One entry in the login pane's in-memory redirect log. Deliberately
/// carries only host + path + HTTP status — never a query string, cookie
/// value, or the ICS feed token — so it's safe to surface verbatim in the
/// copyable diagnostics report (docs/CANVAS_LOGIN_HARDENING.md item 3e)
/// without redaction logic having to catch anything after the fact.
struct LoginRedirectLogEntry: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let path: String
    let status: Int?
    let at: Date

    var description: String {
        let statusText = status.map(String.init) ?? "?"
        return "\(statusText)  \(host)\(path)"
    }
}

/// App-wide (process-lifetime, in-memory only — never persisted to disk)
/// home for the redirect log, so Settings' diagnostics report
/// (docs/CANVAS_LOGIN_HARDENING.md item 3e) can read the most recent login
/// attempt's entries even after that login pane has been dismissed. Every
/// `LoginNavigationObserver` writes here in addition to its own
/// pane-scoped copy.
@MainActor
final class LoginDiagnosticsLog: ObservableObject {
    static let shared = LoginDiagnosticsLog()
    private init() {}

    @Published private(set) var entries: [LoginRedirectLogEntry] = []
    private let maxEntries = 30

    func record(_ entry: LoginRedirectLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    /// Cleared whenever login data is reset, so diagnostics never outlive a
    /// "Reset login data" tap.
    func clear() {
        entries = []
    }
}

/// Observe-only `WKNavigationDelegate` for the Canvas/Gradescope login panes
/// (docs/CANVAS_LOGIN_HARDENING.md item 3a).
///
/// Deliberately does nothing to steer navigation: every `decidePolicyFor`
/// call always allows. No `.cancel`, no URL rewriting, no auto-purge-and-
/// retry — a false-positive "known error page" detection that silently
/// purged and reloaded would burn a second `SAMLRequest` mid-flow and could
/// easily make the exact bug this file exists to diagnose *worse*. Recovery
/// from a detected error is always a user-initiated tap ("Start over" /
/// "Use calendar link instead"), never automatic.
///
/// What this DOES do:
/// - Surfaces a plain-language message on `didFailProvisionalNavigation`
///   (e.g. offline, DNS failure) instead of leaving the pane on a blank box.
/// - Keeps a short, privacy-safe redirect log (host + path + status only).
/// - Flags known Shibboleth/IdP error pages by their page title, so the pane
///   can swap in a plain-language card instead of leaving WebKit's own error
///   page on screen.
@MainActor
final class LoginNavigationObserver: NSObject, ObservableObject {
    /// Plain-language message for a failed load (offline, DNS, timeout, …).
    /// `nil` once a subsequent navigation attempt starts.
    @Published private(set) var loadError: String?

    /// True once a known IdP/Shibboleth error page's title has been observed
    /// on the currently-loaded page. Reset by the pane's "Start over"/"Reload"
    /// actions (which recreate this observer or explicitly clear it), and
    /// also cleared automatically as soon as a new main-frame navigation
    /// starts (see `didStartProvisionalNavigation`) — a multi-hop SSO chain
    /// (Canvas → Shibboleth → Duo → back) can pass through a transient
    /// error-titled intermediate page without permanently latching this flag
    /// for the rest of the flow.
    @Published private(set) var detectedKnownErrorPage = false

    /// The actual page title that tripped `detectedKnownErrorPage`, kept for
    /// diagnostics. Cleared everywhere `detectedKnownErrorPage` is cleared.
    @Published private(set) var detectedErrorPageTitle: String?

    /// Most recent entries first; capped so a long back-and-forth SSO chain
    /// can't grow this unbounded across a long session.
    @Published private(set) var redirectLog: [LoginRedirectLogEntry] = []
    private let maxLogEntries = 30

    /// Page titles that indicate a known IdP/SSO error state rather than a
    /// normal login step. Matched case-insensitively as a substring.
    private static let knownErrorTitleMarkers = [
        "stale request",
        "session has expired",
        "unable to locate session",
        "no saml response",
        "request has expired",
    ]

    func reset() {
        loadError = nil
        detectedKnownErrorPage = false
        detectedErrorPageTitle = nil
    }

    /// Mirrors every redirect-log entry to the unified system log, so the
    /// chain is visible live in Xcode's console (or Console.app) while
    /// reproducing a login failure — no in-app export step needed. Same
    /// privacy budget as the report: host + path + status only, which is
    /// why `.public` is safe here.
    private static let consoleLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LHF",
        category: "login-redirects"
    )

    fileprivate func appendLogEntry(host: String, path: String, status: Int?) {
        let entry = LoginRedirectLogEntry(host: host, path: path, status: status, at: Date())
        Self.consoleLog.info("\(entry.description, privacy: .public)")
        redirectLog.insert(entry, at: 0)
        if redirectLog.count > maxLogEntries {
            redirectLog.removeLast(redirectLog.count - maxLogEntries)
        }
        LoginDiagnosticsLog.shared.record(entry)
    }

    fileprivate static func plainLanguageMessage(for error: Error) -> String {
        let nsError = error as NSError
        // A user-initiated cancel (e.g. navigating away) isn't a real error.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return ""
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "You're offline. Check your connection and try Reload."
        case NSURLErrorTimedOut:
            return "That took too long to load. Try Reload."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Couldn't reach Canvas. Check your connection and try Reload."
        default:
            return "Couldn't load the sign-in page. Try Reload or Start over."
        }
    }
}

// MARK: - WKNavigationDelegate
//
// In its own extension (rather than declared on the class itself) so the
// compiler doesn't warn that `decidePolicyFor navigationResponse:` "nearly
// matches" the sibling `decidePolicyFor navigationAction:` requirement —
// both are real, distinct optional requirements of `WKNavigationDelegate`;
// this is the standard shape for implementing only the response variant.
extension LoginNavigationObserver: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        // A new main-frame navigation means the flow has moved past whatever
        // was previously on screen. Penn SSO is a multi-hop redirect chain
        // (Canvas → Shibboleth → Duo → back); if an intermediate page's
        // title happened to match a known-error marker, that page is gone
        // now, so don't let the flag (or the title that caused it) latch
        // for the rest of the flow.
        detectedKnownErrorPage = false
        detectedErrorPageTitle = nil
        logHop("start", url: webView.url)
    }

    // The two below exist purely to make the redirect chain observable
    // through callbacks that provably fire (same plain notification family
    // as `didFinish` above) — they carry no HTTP status, so entries from the
    // policy callback are still preferred when it works. Server-redirect is
    // the important one: Penn SSO is a chain of 302s, and this fires once
    // per hop.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        logHop("redirect", url: webView.url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        logHop("commit", url: webView.url)
    }

    private func logHop(_ kind: String, url: URL?) {
        guard let url, let host = url.host else { return }
        appendLogEntry(host: host, path: "\(url.path) [\(kind)]", status: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadError = Self.plainLanguageMessage(for: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = Self.plainLanguageMessage(for: error)
    }

    // The `@MainActor @Sendable` on the decisionHandler is the load-bearing
    // part: the SDK requirement types the completion as
    // `@escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void`,
    // and without those annotations this method does NOT satisfy the
    // requirement — the compiler emits only a "nearly matches" warning, no
    // @objc is inferred, `respondsToSelector` returns false, and WebKit
    // silently never delivers the callback. That exact mismatch (silenced
    // with `private` at some point, which hides the warning but not the
    // problem) is why the diagnostics report's redirect chain was empty on
    // device. Do not add an explicit `@objc(...)` selector instead of
    // matching the type — the compiler rejects that as a conflict with the
    // requirement. `makeWebView` logs a respondsToSelector probe so a
    // regression here shows up in the very first console line of a login.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse, let url = http.url {
            appendLogEntry(host: url.host ?? "", path: url.path, status: http.statusCode)
        }
        // Observe-only: always allow. Never cancel, never redirect.
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.title") { [weak self] result, _ in
            guard let self, let title = result as? String else { return }
            let lower = title.lowercased()
            if Self.knownErrorTitleMarkers.contains(where: lower.contains) {
                self.detectedKnownErrorPage = true
                self.detectedErrorPageTitle = title
                // A page title is safe to log verbatim (no query string,
                // cookie value, or ICS feed token can end up here — see
                // `LoginRedirectLogEntry`'s doc comment), so it's fine to
                // surface in the copyable diagnostics report via the same
                // path as the host/path/status entries below.
                self.appendLogEntry(host: "(page title)", path: " \(title)", status: nil)
            }
        }
    }
}
