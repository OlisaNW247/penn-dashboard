import Foundation
import Security
import LowHangingFruitKit

/// Keeps the ambassador's code in the Keychain.
///
/// **Why the Keychain (Tier 3).** The code is a bearer secret in the exact
/// sense the three-tier rule means: whoever has it is that ambassador on the
/// server (their numbers, their checklist, the power to log posts in their
/// name). It is far less sensitive than a Canvas session, but the rule is
/// about kind, not degree, and `UserDefaults` is readable from a backup. So
/// it follows `EdSessionTokenStore` exactly: its own item, after first unlock
/// only, never synchronizable, never logged, removed by "sign out".
///
/// **Under `swift test`** every operation is inert, for the reason that file
/// documents: an unsandboxed macOS test run would otherwise read and delete
/// the developer's own code. `AmbassadorModel` takes the store as closures,
/// so tests use an in-memory one and never arrive here.
enum AmbassadorCodeStore {
    private static let service = "com.lhf.lowhangingfruit.ambassador.code"
    private static let account = "ambassadorCode"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    @discardableResult
    static func save(_ code: String) -> Bool {
        guard !SharedDefaults.isTestRunner else { return false }
        guard !code.isEmpty, let data = code.data(using: .utf8) else { return false }
        return KeychainItem.write(data, base: baseQuery()) == errSecSuccess
    }

    static func load() -> String? {
        guard !SharedDefaults.isTestRunner else { return nil }
        return KeychainItem.read(baseQuery()).decoded { data in
            guard let code = String(data: data, encoding: .utf8), !code.isEmpty else { return nil }
            return code
        }.value
    }

    static func remove() {
        guard !SharedDefaults.isTestRunner else { return }
        KeychainItem.delete(baseQuery())
    }
}
