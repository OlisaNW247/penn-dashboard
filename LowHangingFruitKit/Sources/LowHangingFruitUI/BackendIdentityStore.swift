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

    /// Stores `identity`, replacing any earlier one: update in place, add only
    /// when nothing is there (`KeychainItem.write`). It used to be
    /// delete-then-add with neither status checked, and the window between the
    /// two is the dangerous part here: this is the only copy of the refresh
    /// token, a refresh rotates it, and an add that failed after the delete
    /// left the device with no identity at all, so the next launch minted a
    /// new anonymous account and orphaned the old one's quota and rows. False
    /// when the Keychain refused, in which case the previous identity is still
    /// in place.
    @discardableResult
    static func save(_ identity: BackendIdentity) -> Bool {
        guard let data = try? JSONEncoder().encode(identity) else { return false }
        return KeychainItem.write(data, base: baseQuery()) == errSecSuccess
    }

    /// The persisted identity in three answers (see `KeychainRead`).
    ///
    /// `BackendSession` must read this form, not `load()`: "no identity" means
    /// sign up for a new anonymous account, and "the Keychain would not say"
    /// must never mean that. A locked or refusing Keychain answers
    /// `unavailable`, and the backend is skipped for that call instead.
    static func read() -> KeychainRead<BackendIdentity> {
        KeychainItem.read(baseQuery()).decoded { try? JSONDecoder().decode(BackendIdentity.self, from: $0) }
    }

    static func load() -> BackendIdentity? {
        read().value
    }

    static func clear() {
        KeychainItem.delete(baseQuery())
    }
}
