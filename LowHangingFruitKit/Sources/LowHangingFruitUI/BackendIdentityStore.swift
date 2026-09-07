import Foundation
import Security

/// The anonymous Supabase identity a device has, once it has one: the auth
/// user id the server uses to scope private rows and enforce quotas
/// (`backend/PROTOCOL.md`'s "Identity is anonymous" principle — no email, no
/// password, nothing that identifies the student), and the refresh token
/// `BackendSession` trades for short-lived access tokens.
struct BackendIdentity: Codable, Sendable, Equatable {
    let userID: String
    let refreshToken: String
}

/// Persists `BackendIdentity` in the Keychain, never `UserDefaults` — the
/// same call `AnthropicKeyStore` and `SessionCookieStore` already make for
/// their own bearer credentials, and for the same reason here: the refresh
/// token is what *mints* new access tokens, on demand, with no further
/// authentication of its own. Anyone holding it can act as this device's
/// anonymous backend identity indefinitely (refresh tokens rotate but never
/// expire on their own), which is a materially different risk than the
/// short-lived access token `BackendSession` keeps in memory only. It never
/// touches disk in cleartext, is excluded from unencrypted device backups,
/// and — like `SessionCookieStore`'s cookies — has no reason to leave this
/// device, so it is never synced.
///
/// One Keychain item, one JSON blob (`userID` + `refreshToken` together)
/// rather than two separate items: `BackendSession` only ever reads or
/// writes the pair as a unit — a refresh response replaces both the token
/// and, in principle, could report a different user id — so there is no
/// case where the two need to be stored, read or cleared independently.
enum BackendIdentityStore {
    private static let service = "com.lhf.lowhangingfruit.backendIdentity"
    private static let account = "identity"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ identity: BackendIdentity) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        // Keychain has no upsert — delete any existing item, then add, the
        // same two-step every store in this Kit uses.
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> BackendIdentity? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let identity = try? JSONDecoder().decode(BackendIdentity.self, from: data)
        else { return nil }
        return identity
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
