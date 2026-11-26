import Foundation
import WebKit

/// The pure parts of the app-link guard, shared by the visible login pane
/// (`LoginNavigationObserver`) and the hidden renewer's navigation delegate
/// (`CanvasSessionRenewer`). With Canvas Student installed, iOS hands the
/// SAML return hop (IdP back to the Canvas host) to that app unless the load
/// is programmatic; see `LoginNavigationObserver.appLinkGuardHost` for the
/// mechanism and why replaying `navigationAction.request` is the wrong fix.
enum AppLinkGuard {
    /// How many reissues one login attempt may make; a loop-breaker, not a
    /// tally of the expected case.
    nonisolated static let maxAppLinkReissues = 8

    /// Whether one more reissue is allowed after `count` already made.
    nonisolated static func reissueAllowed(count: Int) -> Bool {
        count < maxAppLinkReissues
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
}
