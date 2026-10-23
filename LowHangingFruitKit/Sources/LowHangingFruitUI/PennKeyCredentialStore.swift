import Foundation
import Security

/// Device-only storage for automatic Penn Canvas reconnection. The visible login
/// explains this before entry. A submitted pair is saved only after Canvas confirms
/// the connection; credentials never go to Smooth, logs, defaults, or iCloud.
/// Disconnecting Canvas removes the item. Duo remains interactive when required.
enum PennKeyCredentialStore {
    private static let service = "com.lhf.lowhangingfruit.pennkeyCredentials"
    private static let account = "pennkeyCredentialsV1"

    private struct Payload: Codable {
        let username: String
        let password: String
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Update atomically, retaining the previous item if Keychain refuses the write.
    @discardableResult
    static func save(
        username: String,
        password: String,
        update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
        add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(Payload(username: username, password: password)) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = update(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var query = baseQuery()
        attributes.forEach { query[$0.key] = $0.value }
        return add(query as CFDictionary) == errSecSuccess
    }

    /// The persisted PennKey username/password, if any.
    static func load() -> (username: String, password: String)? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return (payload.username, payload.password)
    }

    /// Removes the persisted credentials outright — called when the "stay
    /// signed in" toggle goes off (`AppState.disableStayLoggedIn()`) and,
    /// transitively, on Canvas disconnect.
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// Whether a credential pair is currently on file, without exposing
    /// either value — the only question most callers (`AppState.canAutoLogin`,
    /// tests asserting a clear actually happened) need answered.
    static var hasCredentials: Bool {
        load() != nil
    }
}
