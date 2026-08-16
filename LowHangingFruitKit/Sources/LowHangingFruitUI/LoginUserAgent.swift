import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A genuine Mobile Safari user agent for the device/iOS version this process
/// is running on, constructed at runtime rather than hardcoded — see
/// docs/CANVAS_LOGIN_DIAGNOSIS.md item 1d / docs/CANVAS_LOGIN_HARDENING.md.
///
/// `WKWebView`'s default UA omits Safari's own `Version/x.y … Safari/604.1`
/// tokens (it advertises as a generic "Mobile/…" WebKit client instead of
/// Safari). Plain Mobile Safari logs into Canvas/Penn SSO fine on the same
/// device; the in-app WKWebView does not — this is exactly the fingerprint an
/// SSO/bot-protection stack can key on to tell the two apart. Presenting an
/// indistinguishable UA removes that variable without touching anything else
/// about the login flow.
///
/// Centralized here as the one place to update if Apple ever changes Mobile
/// Safari's UA format.
enum LoginUserAgent {
    /// The user agent string to set via `WKWebView.customUserAgent` on every
    /// login pane's WebView.
    static var mobileSafari: String {
        #if os(iOS)
        let device = UIDevice.current
        let systemVersion = device.systemVersion   // e.g. "18.0" or "17.5.1"
        let underscored = systemVersion.replacingOccurrences(of: ".", with: "_")
        // Safari's own Version/x.y tracks iOS's major.minor on modern
        // releases; this is the closest available approximation without
        // Safari's private UA API.
        let versionComponents = systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        let platform = device.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return "Mozilla/5.0 (\(platform); CPU \(platform) OS \(underscored) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(versionComponents) Mobile/15E148 Safari/604.1"
        #else
        // macOS build target: a current desktop Safari UA. Less critical (the
        // reported bug is iPhone-only), but kept consistent for the same reason.
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        #endif
    }
}
