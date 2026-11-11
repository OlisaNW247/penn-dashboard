#if DEBUG
import Foundation
import LowHangingFruitKit

/// Owner-only trail for the Degree Works reader and client, the same shape as
/// `DebugRenewalLog`. Every line is words, a host and path, or JSON KEY NAMES
/// (the audit's shape, so Marco's capture session can see what Penn's reply
/// really looks like). Never a token, a cookie value, a query string, a
/// student id, a page body or any value from the audit.
///
/// Kept in `UserDefaults.lhf` (`debugDegreeLogV1`, last 30 lines) so it can be
/// read off a tethered phone with `devicectl`, and printed as `LHF-DEGREE`
/// for a live console. Inert under `swift test` for the same reason
/// `DebugRenewalLog` is.
@MainActor
enum DebugDegreeLog {
    private static let key = "debugDegreeLogV1"
    private static let cap = 30

    static func record(_ line: String) {
        guard !SharedDefaults.isTestRunner else { return }
        print("LHF-DEGREE \(line)")
        var entries = UserDefaults.lhf.stringArray(forKey: key) ?? []
        entries.append(line)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
        UserDefaults.lhf.set(entries, forKey: key)
    }

    static var lines: [String] {
        guard !SharedDefaults.isTestRunner else { return [] }
        return UserDefaults.lhf.stringArray(forKey: key) ?? []
    }

    static func clear() {
        guard !SharedDefaults.isTestRunner else { return }
        UserDefaults.lhf.removeObject(forKey: key)
    }
}
#endif
