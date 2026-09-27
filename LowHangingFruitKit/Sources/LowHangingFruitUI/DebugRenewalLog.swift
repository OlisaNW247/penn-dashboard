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
#endif
