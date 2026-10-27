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
    ///
    /// The model for every Keychain store in the app, now shared as
    /// `KeychainItem.write` (update first, add only on `errSecItemNotFound`,
    /// every status counted). The signature and the outcomes are unchanged,
    /// including the injectable `update` and `add` that
    /// `PennKeyCredentialWriteTests` drive.
    @discardableResult
    static func save(
        username: String,
        password: String,
        update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
        add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(Payload(username: username, password: password)) else { return false }
        return KeychainItem.write(data, base: baseQuery(), update: update, add: add) == errSecSuccess
    }

    /// The persisted PennKey username/password in three answers (see
    /// `KeychainRead`). `load()` below is the old "a pair or nil" view.
    static func read() -> KeychainRead<(username: String, password: String)> {
        KeychainItem.read(baseQuery()).decoded { data in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            return (payload.username, payload.password)
        }
    }

    /// The persisted PennKey username/password, if any.
    static func load() -> (username: String, password: String)? {
        read().value
    }

    /// Removes the persisted credentials outright — called when the "stay
    /// signed in" toggle goes off (`AppState.disableStayLoggedIn()`) and,
    /// transitively, on Canvas disconnect.
    static func clear() {
        KeychainItem.delete(baseQuery())
    }

    /// Whether a credential pair is currently on file, without exposing
    /// either value — the only question most callers (`AppState.canAutoLogin`,
    /// tests asserting a clear actually happened) need answered.
    static var hasCredentials: Bool {
        load() != nil
    }
}
