import Foundation
import Security

/// Persists the user's own Anthropic API key in the Keychain, not
/// UserDefaults — mirrors `ICSFeedURLStore`'s reasoning exactly.
///
/// The key is a bearer credential: anyone who has it can make billed API
/// calls against the owner's Anthropic account with no further
/// authentication, the same shape of risk `ICSFeedURLStore` documents for
/// Canvas's token-bearing feed URL. UserDefaults is unencrypted, included in
/// unencrypted device backups, and readable by anything with app-container
/// access; Keychain (like `SessionCookieStore` and `ICSFeedURLStore`, which
/// already treat their own bearer credentials this way) is the appropriate
/// place for a value that grants access on its own.
///
/// Unlike `ICSFeedURLStore`, there is no UserDefaults-migration path here:
/// the Claude backend and its API key are new in this change, so there is no
/// pre-existing UserDefaults value anywhere to migrate away from — adding a
/// migration step for a key that never existed would be dead code, not
/// defensive code.
enum AnthropicKeyStore {
    private static let service = "com.lhf.lowhangingfruit.anthropicKey"
    private static let account = "apiKey"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ key: String) {
        guard !key.isEmpty else {
            clear()
            return
        }
        guard let data = key.data(using: .utf8) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    static func load() -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        return ""
    }
}
