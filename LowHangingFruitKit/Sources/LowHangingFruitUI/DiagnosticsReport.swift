import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the copyable diagnostics report (docs/CANVAS_LOGIN_HARDENING.md
/// item 3e) — meant to be pasted into a support email/message when Canvas
/// login is stuck. Contains ONLY what's needed to reproduce/diagnose:
/// - Device/OS/app version.
/// - Which connect path was used for Canvas (in-app login vs. pasted feed
///   link vs. not connected), and each service's connected/expired state.
/// - The redirect log (host + path + HTTP status only — see
///   `LoginRedirectLogEntry`'s doc comment).
///
/// Never includes: credentials, cookie values/names, the ICS feed URL/token,
/// or query strings of any kind.
@MainActor
enum DiagnosticsReport {
    static func generate(state: AppState) -> String {
        var lines: [String] = []
        lines.append("LHF diagnostics report")
        lines.append("Generated: \(isoFormatter.string(from: Date()))")
        lines.append("")
        lines.append("App version: \(appVersionString())")
        lines.append("Device: \(deviceModelString())")
        lines.append("OS version: \(osVersionString())")
        lines.append("")
        lines.append("Canvas connected (feed): \(state.isCanvasConnected)")
        lines.append("Canvas login session expired: \(state.canvasSessionExpired)")
        lines.append("Canvas connect path: \(canvasConnectPath(state: state))")
        lines.append("Gradescope connected: \(state.isGradescopeConnected)")
        lines.append("")
        lines.append("Recent login redirects (host/path/status only — no tokens or query strings):")
        let entries = LoginDiagnosticsLog.shared.entries
        if entries.isEmpty {
            lines.append("(none recorded this session)")
        } else {
            for entry in entries {
                lines.append("  \(relativeTime(entry.at))  \(entry.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Best-effort description of how Canvas got connected, purely from
    /// locally-observable state — never a network call. "Login" if a Canvas
    /// cookie session was ever captured (even if since expired); "Pasted
    /// calendar link" if connected with no cookie session on record; "Not
    /// connected" otherwise.
    private static func canvasConnectPath(state: AppState) -> String {
        guard state.isCanvasConnected else { return "Not connected" }
        let hasCookieSession = !SessionCookieStore.load(service: .canvas).isEmpty || state.canvasSessionExpired
        return hasCookieSession ? "In-app login" : "Pasted calendar link"
    }

    private static func appVersionString() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func deviceModelString() -> String {
        #if os(iOS)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    private static func osVersionString() -> String {
        #if os(iOS)
        return "iOS \(UIDevice.current.systemVersion)"
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()
}
