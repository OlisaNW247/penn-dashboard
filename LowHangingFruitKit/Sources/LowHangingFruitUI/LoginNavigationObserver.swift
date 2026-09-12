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
/// Deliberately does (almost) nothing to steer navigation. No URL rewriting
/// or automatic restart: a false-positive recovery could burn a second
/// `SAMLRequest` mid-flow. The single exception to "always allow" is a repeat
/// main-frame POST to the same URL while the previous POST's response has not yet
/// committed (20s cap) is cancelled, because a double-submitted credential
/// form is what consumed Shibboleth's one-shot login conversation and
/// produced every deterministic "Stale Request" — see
/// `decidePolicyFor navigationAction` for the on-device evidence. Once any
/// page commits, the guard disarms, so a human resubmitting a re-rendered
/// form (e.g. after a wrong password) is never touched.
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
    /// on the currently-loaded page. Cleared automatically as soon as a new
    /// main-frame navigation starts (see `didStartProvisionalNavigation`) — a multi-hop SSO chain
    /// (Canvas → Shibboleth → Duo → back) can pass through a transient
    /// error-titled intermediate page without permanently latching this flag
    /// for the rest of the flow.
    @Published private(set) var detectedKnownErrorPage = false

    /// The actual page title that tripped `detectedKnownErrorPage`, kept for
    /// diagnostics. Cleared everywhere `detectedKnownErrorPage` is cleared.
    @Published private(set) var detectedErrorPageTitle: String?

    /// Host substring the caller considers signed in once a non-login page
    /// actually renders (for example Canvas or Gradescope's own host).
    var signedInHostMarker: String?
    /// Canvas must leave its host for Penn SSO before returning. Gradescope's
    /// own login stays on gradescope.com, so its pane disables this requirement
    /// and relies on the transition away from a `/login` path instead.
    var signedInRequiresForeignHost = true

    /// Host this pane must defend against iOS's universal-link ("app link")
    /// hijacking on the SAML return hop (confirmed on a real phone,
    /// 2026-09-12: with Canvas Student installed, Canvas connect "just opens
    /// the Canvas app" and never comes back; deleting Canvas Student made it
    /// work). The mechanism: WebKit treats a main-frame navigation as an
    /// app-link candidate when it traces back to a user gesture AND the
    /// destination host differs from the current main-frame host. Penn's IdP
    /// page was loaded by the student's own tap (through Duo), and WebKit
    /// propagates that "was user-initiated" permission forward to
    /// navigations the IdP page itself starts — including the auto-submitted
    /// SAML POST it fires back at `canvas.upenn.edu`. Canvas Student claims
    /// universal links for that host, so iOS routes the hop to the installed
    /// app instead of letting this `WKWebView` render it, and this delegate
    /// never sees the signed-in page or its cookies.
    ///
    /// `nil` for Gradescope's pane: no Gradescope iOS app claims those links,
    /// so the hijack cannot happen there and the guard would just be dead
    /// weight (and an extra thing to get wrong).
    ///
    /// The fix is to detect exactly that cross-host, gesture-descended hop
    /// (`needsAppLinkGuard`) and re-issue it ourselves as a *programmatic*
    /// `WKWebView.load(_:)` — which is never an app-link candidate, and
    /// neither are the redirects it produces, because the gesture lineage
    /// that made the original hop eligible doesn't attach to a load this
    /// delegate initiates. The wrong fix, which looks obviously simpler, is
    /// to cancel the hijacked navigation and call
    /// `webView.load(navigationAction.request)` with the request WebKit
    /// handed us: `WKNavigationAction.request` never carries a POST body
    /// (WebKit strips it before this delegate method sees it), so replaying
    /// it verbatim silently turns the SAML POST into a bodyless GET and the
    /// IdP rejects it. The actual fix instead reads the on-screen HTML form
    /// itself (`formSerializerScript`) and reissues a real POST with the
    /// form's own serialized body.
    var appLinkGuardHost: String?

    /// How many times `decidePolicyFor navigationAction` has re-issued a hop
    /// for the app-link guard during the *current* login attempt. A
    /// programmatic reissue's own redirect chain re-enters this delegate —
    /// e.g. a reissued POST followed by two 302s still lands back on the
    /// foreign-then-Canvas boundary and can trip the guard again on each
    /// hop — so this is a loop-breaker, not an expected-count tally. Reset
    /// whenever `startURL` is (re)established, i.e. once per fresh login
    /// attempt (see `startURL`'s `didSet`).
    private var appLinkReissueCount = 0
    /// Generous on purpose: a single guarded hop's own redirect chain can
    /// burn several re-issues on its own (see `appLinkReissueCount`'s doc
    /// comment), and the cap only exists to stop a genuinely pathological
    /// loop, not to bound the ordinary case tightly.
    private static let maxAppLinkReissues = 8

    /// True once a page matching `signedInHostMarker` has committed. Both
    /// login panes use this to connect automatically after authentication.
    @Published private(set) var reachedSignedInDestination = false

    /// True once any observed navigation hop has landed on a host that
    /// does NOT contain `signedInHostMarker`. The Canvas login pane's very
    /// first load IS `https://canvas.upenn.edu`, which then redirects out
    /// to Penn's SSO chain (Shibboleth, Duo, ...) before bouncing back —
    /// so a Canvas hop before any foreign host has been seen is the START
    /// of that chain, not the end of it, and must not be mistaken for
    /// arrival.
    private var sawForeignHost = false

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

    /// The most recent main-frame POST this observer allowed through, used
    /// to suppress the flow-killing duplicate submit — see the
    /// `decidePolicyFor navigationAction` doc comment for the evidence.
    private var lastMainFramePOST: (url: URL, at: Date)?

    /// The URL the login pane originally loaded (set by `makeWebView`), so
    /// auto-recovery can restart the SSO chain from the top. `makeWebView`
    /// sets this exactly once per fresh `WKWebView` — i.e. once per login
    /// attempt — so its `didSet` doubles as "a new attempt just started" and
    /// is where `appLinkReissueCount` resets; a stale count carried over
    /// from an earlier attempt could reach the cap on the very first hop of
    /// a brand-new one.
    var startURL: URL? {
        didSet { appLinkReissueCount = 0 }
    }
    /// Markers for the one dead-end this delegate self-heals: the duplicate
    /// POST replaces (and kills, code -999) the real credential POST, and
    /// the guard then cancels the duplicate — leaving NOTHING in flight and
    /// a login conversation that is already consumed server-side, so any
    /// manual re-submit of the on-screen form is doomed to "Stale Request".
    /// Seen on device 2026-08-22 as the only failure in a 5/6 run. When both
    /// markers land within the duplicate window (either order), the pane
    /// reloads `startURL`: cookies survive, a fresh conversation starts.
    private var duplicateCanceledAt: Date?
    private var postProvisionalDiedAt: Date?
    /// 20s, not 3s: on-device (2026-08-22) the re-submits came in two waves —
    /// an echo ~1s after the real POST and a re-issue ~6s later that slipped
    /// a 3s window and drew the Stale Request anyway. During a login flow a
    /// same-URL main-frame re-POST inside 20s is always the pathological
    /// repeat; a genuine user retry (re-type, re-tap) lands later than that.
    private static let duplicatePOSTWindow: TimeInterval = 20

    func reset() {
        loadError = nil
        detectedKnownErrorPage = false
        detectedErrorPageTitle = nil
        lastMainFramePOST = nil
        duplicateCanceledAt = nil
        postProvisionalDiedAt = nil
        reachedSignedInDestination = false
        sawForeignHost = false
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
            return "You're offline. Check your connection and try again."
        case NSURLErrorTimedOut:
            return "That took too long to load. Try again."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Couldn't reach the sign-in service. Check your connection and try again."
        default:
            return "Couldn't load the sign-in page. Try again."
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
        // A committed page disarms the duplicate-POST guard: everything the
        // user does on a rendered page is a deliberate action, and the
        // legitimate wrong-password retry is a same-URL POST from the
        // re-rendered form (Shibboleth keeps the URL on credential errors).
        // The pathological duplicates this guard exists for all arrive
        // BEFORE the original POST's response commits — every on-device
        // trace showed [start] → echo with no commit in between.
        lastMainFramePOST = nil
    }

    private func logHop(_ kind: String, url: URL?) {
        guard let url, let host = url.host else { return }
        appendLogEntry(host: host, path: "\(url.path) [\(kind)]", status: nil)

        // Drives `reachedSignedInDestination` (see that property's and
        // `isSignedInDestination`'s doc comments). `didStartProvisionalNavigation`,
        // `didReceiveServerRedirectForProvisionalNavigation` and `didCommit`
        // all funnel through here, which is what lets a single check see
        // the whole SSO chain rather than just one callback's slice of it.
        guard let marker = signedInHostMarker else { return }
        if !host.localizedCaseInsensitiveContains(marker) {
            sawForeignHost = true
        } else if kind == "commit",
                  Self.isSignedInDestination(
                    host: host,
                    path: url.path,
                    marker: marker,
                    sawForeignHost: sawForeignHost,
                    requiresForeignHost: signedInRequiresForeignHost
                  ) {
            // Only `didCommit` counts as "reached" — a page actually
            // rendering, not merely a redirect in flight that might yet
            // bounce onward.
            reachedSignedInDestination = true
        }
    }

    /// Pure predicate for "has the login pane actually landed back at the
    /// signed-in destination", pulled out of `logHop` so it's testable
    /// without a live `WKWebView` (see `CanvasLoginHardeningTests`). Every
    /// condition below is load-bearing:
    /// - `marker` must be set and `host` must contain it (case-insensitive).
    /// - When `requiresForeignHost` is true, a foreign host must have been
    ///   observed first. Canvas starts on its destination host before leaving
    ///   for Penn SSO, while Gradescope signs in entirely on one host and
    ///   disables this requirement.
    /// - `path` must not contain "/login": Canvas bounces a failed or
    ///   partial SSO attempt back to its own `/login/...` pages, which are
    ///   on the Canvas host but are not a signed-in session.
    ///
    /// `nonisolated` because this touches only its own value-type
    /// parameters, not the class's `@MainActor` state — without it, the
    /// class's actor isolation spreads to this static func too, and the
    /// synchronous tests calling it directly (no live `WKWebView`, no
    /// `await`) fail to compile.
    nonisolated static func isSignedInDestination(
        host: String,
        path: String,
        marker: String?,
        sawForeignHost: Bool,
        requiresForeignHost: Bool = true
    ) -> Bool {
        guard let marker, !marker.isEmpty else { return false }
        guard host.localizedCaseInsensitiveContains(marker) else { return false }
        guard sawForeignHost || !requiresForeignHost else { return false }
        guard !path.localizedCaseInsensitiveContains("/login") else { return false }
        return true
    }

    /// Header our own re-issued loads carry so a subsequent pass through
    /// `decidePolicyFor navigationAction` recognizes them as already-guarded
    /// and lets them through — without this, a reissued load's own
    /// cross-host arrival (it is, after all, the same hop) would trip the
    /// guard again forever.
    nonisolated static let reissueMarkerHeader = "X-LHF-Reissued"

    /// Pure predicate for "is this main-frame hop the app-link hijack
    /// pattern", pulled out of `decidePolicyFor navigationAction` so it's
    /// testable without a live `WKWebView`/`WKNavigationAction` (see
    /// `AppLinkGuardTests`). See `appLinkGuardHost`'s doc comment for the
    /// mechanism this defends against. Every condition is load-bearing:
    /// - `guardHost` must be configured (Gradescope's pane leaves it `nil`)
    ///   and must equal `destinationHost` case-insensitively: this only ever
    ///   fires for the exact host an installed app has claimed, not any
    ///   cross-host hop.
    /// - `currentHost` must be non-nil and differ from `destinationHost`: a
    ///   same-host hop is never an app-link candidate, and the very first
    ///   programmatic load of a fresh `WKWebView` has a nil `webView.url`,
    ///   which must not be mistaken for "arriving from a foreign host".
    /// - `navigationType` must not be `.backForward`: back/forward
    ///   navigation is browser-history-driven, never an app-link candidate.
    /// - `hasReissueMarker` must be false: our own re-issued loads carry the
    ///   marker precisely so they fall through to the ordinary allow path
    ///   instead of guarding themselves forever.
    ///
    /// `nonisolated` for the same reason as `isSignedInDestination` above —
    /// this touches only its own value-type parameters, and swift-testing
    /// calls it synchronously off the main actor.
    nonisolated static func needsAppLinkGuard(
        destinationHost: String?,
        currentHost: String?,
        guardHost: String?,
        navigationType: WKNavigationType,
        hasReissueMarker: Bool
    ) -> Bool {
        guard !hasReissueMarker else { return false }
        guard navigationType != .backForward else { return false }
        guard let guardHost, !guardHost.isEmpty else { return false }
        guard let destinationHost,
              destinationHost.caseInsensitiveCompare(guardHost) == .orderedSame else { return false }
        guard let currentHost,
              currentHost.caseInsensitiveCompare(destinationHost) != .orderedSame else { return false }
        return true
    }

    /// Builds the programmatic reissue for a hop the app-link guard just
    /// cancelled. `.reloadIgnoringLocalAndRemoteCacheData` matches
    /// `makeWebView`'s own load policy, for the same reason: a cached copy
    /// of a login/redirect hop can carry a stale embedded flow-execution
    /// token. Marking every reissue with `reissueMarkerHeader` is what keeps
    /// it from re-triggering `needsAppLinkGuard` on its own way through this
    /// delegate again.
    nonisolated static func reissuedRequest(url: URL, method: String, body: String?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = method
        request.setValue("1", forHTTPHeaderField: reissueMarkerHeader)
        if method == "POST" {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body?.data(using: .utf8)
        }
        return request
    }

    /// Drops a URL's `#fragment`, used both to build the comparison the JS
    /// form-serializer runs in-page and by `AppLinkGuardTests` directly.
    nonisolated static func stripFragment(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    /// Escapes `string` for embedding as a JSON string literal inside the
    /// generated JavaScript — manual escaping (backslash, then double quote;
    /// order matters, or a quote's own inserted backslash would itself get
    /// re-escaped) rather than a raw string, per the repo's own trap about
    /// raw strings and escapes: this needs a literal backslash-quote pair in
    /// the *output*, which a `#"..."#` raw string cannot produce without
    /// contortion, and getting it wrong here means a URL containing a quote
    /// breaks out of the JS string literal into the surrounding script.
    nonisolated static func jsonStringLiteral(for string: String) -> String {
        var escaped = string.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// JavaScript run in-page (via `evaluateJavaScript(_:in:in:completionHandler:)`)
    /// to recover the POST body WebKit never hands this delegate:
    /// `WKNavigationAction.request` for a form submission never carries the
    /// body (see `appLinkGuardHost`'s doc comment on why replaying that
    /// request verbatim is the wrong fix), but the on-screen `<form>` that
    /// produced the navigation is still live in the DOM at the moment this
    /// delegate is asked to decide, so this script finds it and serializes
    /// it directly instead.
    ///
    /// Matches by resolving every form's `action` against `location.href`
    /// (a bare `action=""` or a relative path both need this) and comparing
    /// it to the target with any `#fragment` stripped from both sides — the
    /// navigation's destination URL and a form's resolved action can differ
    /// only in fragment and still be the same submission. Returns
    /// `{action, body}` for the first match, built with `URLSearchParams`
    /// over the form's own `FormData` (skipping any non-string value — a
    /// `<input type="file">` would otherwise stringify to something like
    /// `"[object File]"` instead of being silently dropped, which is what an
    /// IdP login form should do with a field it never has). Returns `null`
    /// on no match or on any exception, which the caller treats as "allow,
    /// unchanged" — never worse than not having this guard at all.
    nonisolated static func formSerializerScript(targetURL: URL) -> String {
        let target = jsonStringLiteral(for: stripFragment(targetURL))
        return """
        (function() {
          try {
            var target = \(target);
            var targetNoFrag = target.split('#')[0];
            var forms = document.forms;
            for (var i = 0; i < forms.length; i++) {
              var form = forms[i];
              var resolved = new URL(form.action || location.href, location.href).href;
              var resolvedNoFrag = resolved.split('#')[0];
              if (resolvedNoFrag === targetNoFrag) {
                var params = new URLSearchParams();
                var formData = new FormData(form);
                formData.forEach(function(value, key) {
                  if (typeof value === 'string') {
                    params.append(key, value);
                  }
                });
                return { action: resolved, body: params.toString() };
              }
            }
            return null;
          } catch (e) {
            return null;
          }
        })();
        """
    }

    // The ONE deliberate exception to this delegate's observe-only rule,
    // earned by on-device evidence (2026-08-22): failing PennKey logins
    // showed the credential form POSTing TWICE to the same URL within a
    // second (two `[action POST type=1]` entries — genuine formSubmitted
    // navigations both times). Shibboleth's login conversation is one-shot:
    // the first POST consumes it, the duplicate then trips the IdP's
    // "Stale Request" page every time — which is exactly the deterministic
    // failure this whole investigation chased. The single success that
    // reached Duo that night had a single POST.
    //
    // So: an identical main-frame POST to the SAME URL is cancelled while
    // the previous POST is still un-committed (20s cap). The first submit
    // is never touched; a different URL always passes; and `didCommit`
    // disarms the guard, so a deliberate resubmit from a re-rendered page
    // (wrong password → error form → retry) always passes too. A false
    // positive costs one extra tap — strictly better than a dead login.
    // Same signature discipline as the response variant below: the
    // decisionHandler MUST be typed `@MainActor @Sendable` or this silently
    // stops being called.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let host = url.host {
            // The app-link guard runs FIRST, ahead of the duplicate-POST
            // check below: a hijacked hop never reaches `lastMainFramePOST`
            // bookkeeping at all (it's cancelled and replaced wholesale), so
            // ordering it after would let a guarded POST get recorded and
            // then have its own re-issued replay spuriously read as a
            // duplicate within the 20s window.
            let hasReissueMarker = navigationAction.request.value(forHTTPHeaderField: Self.reissueMarkerHeader) != nil
            if Self.needsAppLinkGuard(
                destinationHost: host,
                currentHost: webView.url?.host,
                guardHost: appLinkGuardHost,
                navigationType: navigationAction.navigationType,
                hasReissueMarker: hasReissueMarker
            ) {
                performAppLinkGuard(webView, navigationAction: navigationAction, url: url, host: host, decisionHandler: decisionHandler)
                return
            }

            let method = navigationAction.request.httpMethod ?? "?"
            if method == "POST" {
                if let last = lastMainFramePOST,
                   last.url == url,
                   Date().timeIntervalSince(last.at) < Self.duplicatePOSTWindow {
                    appendLogEntry(host: host, path: "\(url.path) [action POST duplicate-canceled]", status: nil)
                    decisionHandler(.cancel)
                    duplicateCanceledAt = Date()
                    autoRecoverIfBothNavigationsDead(webView)
                    return
                }
                lastMainFramePOST = (url, Date())
            }
            appendLogEntry(host: host, path: "\(url.path) [action \(method) type=\(navigationAction.navigationType.rawValue)]", status: nil)
        }
        decisionHandler(.allow)
    }

    /// Cancels a hop `needsAppLinkGuard` flagged and replaces it with a
    /// programmatic reissue — see `appLinkGuardHost`'s doc comment for why
    /// a programmatic `WKWebView.load(_:)` is immune to the app-link
    /// hijack a WebKit-initiated navigation is vulnerable to. Always calls
    /// `decisionHandler` exactly once, either synchronously here or from the
    /// `evaluateJavaScript` completion below.
    private func performAppLinkGuard(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        url: URL,
        host: String,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard appLinkReissueCount < Self.maxAppLinkReissues else {
            appendLogEntry(host: host, path: "\(url.path) [app-link guard cap reached, allowing]", status: nil)
            decisionHandler(.allow)
            return
        }
        appLinkReissueCount += 1

        let method = navigationAction.request.httpMethod ?? "GET"
        guard method == "POST" else {
            appendLogEntry(host: host, path: "\(url.path) [app-link guard reissue GET]", status: nil)
            decisionHandler(.cancel)
            webView.load(Self.reissuedRequest(url: url, method: "GET", body: nil))
            return
        }

        // A POST's body lives only in the on-screen form, not in
        // `navigationAction.request` (see `appLinkGuardHost`'s doc comment
        // on why replaying that request verbatim is the wrong fix), so
        // recover it by asking the page itself. `sourceFrame` is an
        // implicitly-unwrapped optional on current SDKs; a `nil` here (seen
        // for a navigation with no originating frame, e.g. one WebKit
        // synthesizes itself) takes the same "allow, unchanged" path as a
        // script that finds no matching form — never worse than not having
        // this guard.
        // `sourceFrame` is non-optional in the current SDK (it was implicitly
        // unwrapped in older ones); the form-not-found path below already
        // covers a frame that has no matching form.
        let sourceFrame = navigationAction.sourceFrame
        let script = Self.formSerializerScript(targetURL: url)
        webView.evaluateJavaScript(script, in: sourceFrame, in: .page) { [weak self] result in
            guard let self else {
                decisionHandler(.allow)
                return
            }
            if case .success(let value) = result,
               let dict = value as? [String: Any],
               let action = dict["action"] as? String,
               let body = dict["body"] as? String {
                self.appendLogEntry(host: host, path: "\(url.path) [app-link guard reissue POST]", status: nil)
                decisionHandler(.cancel)
                webView.load(Self.reissuedRequest(url: URL(string: action) ?? url, method: "POST", body: body))
            } else {
                self.appendLogEntry(host: host, path: "\(url.path) [app-link guard: form not found, allowing]", status: nil)
                decisionHandler(.allow)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        recordNavigationFailure(webView, error: error, phase: "provisional-failed")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordNavigationFailure(webView, error: error, phase: "failed")
    }

    /// Logs every dead navigation with its error code — code -999
    /// (NSURLErrorCancelled) is the interesting one: it marks a navigation
    /// WebKit abandoned because something replaced it, which is how the
    /// credential POST that actually consumed the IdP's login conversation
    /// was vanishing from the record without a trace. Cancelled navigations
    /// keep `loadError` nil (they were never a user-visible failure).
    private func recordNavigationFailure(_ webView: WKWebView, error: Error, phase: String) {
        let nsError = error as NSError
        appendLogEntry(
            host: webView.url?.host ?? "(no url)",
            path: "\(webView.url?.path ?? "") [\(phase) code=\(nsError.code)]",
            status: nil
        )
        let message = Self.plainLanguageMessage(for: error)
        loadError = message.isEmpty ? nil : message
        // A cancelled (-999, i.e. replaced) navigation while a credential
        // POST is in play is one of the two markers of the dead-air dead
        // end — see `duplicateCanceledAt`'s doc comment.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled,
           let last = lastMainFramePOST,
           Date().timeIntervalSince(last.at) < Self.duplicatePOSTWindow {
            postProvisionalDiedAt = Date()
            autoRecoverIfBothNavigationsDead(webView)
        }
    }

    /// Fires only when BOTH markers are present within the duplicate window
    /// (either order): the real POST died replaced AND its replacement was
    /// cancelled by the guard. Nothing is in flight, the on-screen form's
    /// conversation is consumed, so restart the chain from the top. Cookies
    /// are untouched, so this is the same recovery a Safari user gets by
    /// re-entering the site — not a purge.
    private func autoRecoverIfBothNavigationsDead(_ webView: WKWebView) {
        guard let canceled = duplicateCanceledAt,
              let died = postProvisionalDiedAt,
              abs(canceled.timeIntervalSince(died)) < Self.duplicatePOSTWindow,
              let startURL else { return }
        duplicateCanceledAt = nil
        postProvisionalDiedAt = nil
        lastMainFramePOST = nil
        appendLogEntry(host: startURL.host ?? "", path: "\(startURL.path) [auto-recover reload]", status: nil)
        webView.load(URLRequest(url: startURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
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
