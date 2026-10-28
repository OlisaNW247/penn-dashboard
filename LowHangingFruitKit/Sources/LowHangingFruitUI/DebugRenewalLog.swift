#if DEBUG
import Foundation
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#endif

/// Owner-only diagnostic trail for the Canvas silent-renewal trigger
/// (CLAUDE.md Known gaps: "stay signed in has never met a real PennKey" —
/// this is the seam that will let a real launch/foreground/background wake
/// be read back afterward instead of trusted on faith). Two channels at
/// once, both fed by the same `record(_:)` call:
/// - `print`, prefixed `LHF-RENEW `, so `xcrun devicectl ... --console`
///   shows each line live during a tethered test.
/// - A capped, newest-last array in `UserDefaults.lhf`
///   (`debugRenewalLogV1`), so the trail can be pulled from a device after
///   the fact (Settings → ... or a future debug-only viewer) without a
///   cable attached at the moment it mattered.
///
/// Every line is `ISO-8601 timestamp | app state | status` — a short,
/// static status word (or a static reason string already vetted as
/// non-sensitive by `CanvasSessionRenewer.Outcome`/`gate(...)`), never a
/// cookie, a URL path or query, a username, or a password, matching the
/// same privacy rule `CanvasSessionRenewer.logAttempt` already holds for
/// its own on-device `LoginDiagnosticsLog` entries.
///
/// No-ops entirely under `swift test` (`SharedDefaults.isTestRunner`) —
/// both the `print` and the `UserDefaults` write — so a full test run
/// doesn't fill the log with hundreds of `AppState.init` renewal checks
/// that never touch a real network, and so this can never resolve the
/// App Group container without the entitlement the way an unguarded
/// `UserDefaults.lhf` read/write would (see CLAUDE.md's App Group trap).
@MainActor
enum DebugRenewalLog {
    private static let key = "debugRenewalLogV1"
    private static let cap = 50

    static func record(_ status: String) {
        guard !SharedDefaults.isTestRunner else { return }
        let line = "\(timestamp()) | \(appStateWord()) | \(status)"
        print("LHF-RENEW \(line)")
        var entries = UserDefaults.lhf.stringArray(forKey: key) ?? []
        entries.append(line)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
        UserDefaults.lhf.set(entries, forKey: key)
    }

    private static func timestamp() -> String {
        isoFormatter.string(from: Date())
    }

    private static func appStateWord() -> String {
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
        #else
        return "mac"
        #endif
    }

    // `ISO8601DateFormatter` isn't `Sendable`, but every use here is a
    // stateless format call on the main actor (this whole enum is
    // `@MainActor`) — same reasoning `SessionCookieStore.isoFormatter`
    // documents for its own shared instance.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()
}

/// `-LHFSessionDiagnostics`: a snapshot of what the silent re-login has to
/// work with on this phone, taken at launch before anything else touches it.
/// Printed as `LHF-DIAG` lines and kept in `UserDefaults.lhf`
/// `debugSessionDiagnosticsV1` so it can be read back off a tethered phone
/// with `devicectl`, the same way `debugRenewalLogV1` is.
///
/// It answers the two questions the renewal log cannot (2026-10-08, a phone
/// that kept asking for a refresh while its flags all read healthy): is a
/// PennKey password actually on file behind `stayLoggedInEnabledV1`, and
/// does the persisted Canvas cookie set hold anything that keeps the 24h
/// rule from ever tripping. Booleans, cookie names, domains and dates only;
/// never a cookie value, the username or the password.
@MainActor
enum DebugSessionDiagnostics {
    private static let key = "debugSessionDiagnosticsV1"

    static func recordIfRequested() {
        guard !SharedDefaults.isTestRunner,
              ProcessInfo.processInfo.arguments.contains("-LHFSessionDiagnostics")
        else { return }
        let entries = SessionCookieStore.debugEntrySummaries(service: .canvas)
        var lines = [
            "taken \(ISO8601DateFormatter().string(from: Date()))",
            "pennkey password on file: \(PennKeyCredentialStore.hasCredentials)",
            "canvas cookies persisted: \(entries.count), still fresh: \(SessionCookieStore.load(service: .canvas).count), isExpired: \(SessionCookieStore.isExpired(service: .canvas))",
        ]
        lines.append(contentsOf: entries)
        // After the reads above, so the snapshot's own are counted. A nonzero
        // failure count here means the Keychain refused something this launch
        // (`KeychainStatusLog`); the pairs say which call and which status.
        lines.append("keychain statuses: \(KeychainStatusLog.shared.summary)")
        lines.forEach { print("LHF-DIAG \($0)") }
        UserDefaults.lhf.set(lines, forKey: key)
    }
}
#endif
