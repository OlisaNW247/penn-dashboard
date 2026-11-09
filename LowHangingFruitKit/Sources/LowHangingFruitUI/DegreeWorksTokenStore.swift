import Foundation
import Security
import LowHangingFruitKit

/// Keeps the student's Degree Works session tokens (`X-AUTH-TOKEN` and
/// `REFRESH_TOKEN`) in the Keychain.
///
/// **What they are.** After Penn's SSO lands the hidden WebView on the Degree
/// Works host, the audit API is authorised by two cookies. Whoever holds the
/// auth token is the student on Degree Works, exactly as with the Canvas
/// session cookies, so it gets the same Tier 3 treatment as
/// `EdSessionTokenStore`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// never synchronizable (no iCloud Keychain, no restore onto another device),
/// its own item so removing it can never touch a Canvas or Gradescope
/// session, never logged, and deleted when Canvas is disconnected
/// (`AppState.clearDegreeData`) because it exists only as a child of the
/// Canvas login.
///
/// **One item, two tokens.** They are stored together as JSON
/// (`{"auth":..., "refresh":...}`) because they are only ever useful as a
/// pair and a half-written pair would be worse than none. A save is a single
/// `KeychainItem.write`: update in place, add only when nothing is there.
///
/// **Under `swift test`.** Every operation is inert when
/// `SharedDefaults.isTestRunner` is true, for the reason
/// `EdSessionTokenStore` gives: an unsandboxed macOS run would otherwise touch
/// the developer's real item.
enum DegreeWorksTokenStore {
    private static let service = "com.lhf.lowhangingfruit.degreeworks.tokens"
    private static let account = "degreeWorksTokensV1"

    private struct Payload: Codable {
        let auth: String
        let refresh: String?
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit, so the item can never be picked up by iCloud Keychain.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// Stores `tokens`, replacing any earlier pair. An empty auth token is
    /// ignored so a failed read can never overwrite a good pair with nothing.
    /// False when the Keychain refused (the previous pair is then still there).
    @discardableResult
    static func save(_ tokens: DegreeWorksTokens) -> Bool {
        guard !SharedDefaults.isTestRunner else { return false }
        guard !tokens.authToken.isEmpty,
              let data = try? JSONEncoder().encode(Payload(auth: tokens.authToken, refresh: tokens.refreshToken))
        else { return false }
        return KeychainItem.write(data, base: baseQuery()) == errSecSuccess
    }

    /// The stored pair, if any.
    static func load() -> DegreeWorksTokens? {
        guard !SharedDefaults.isTestRunner else { return nil }
        return KeychainItem.read(baseQuery()).decoded { data -> DegreeWorksTokens? in
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  !payload.auth.isEmpty
            else { return nil }
            return DegreeWorksTokens(authToken: payload.auth, refreshToken: payload.refresh)
        }.value
    }

    /// Deletes the stored pair. Safe to call when there is none.
    static func remove() {
        guard !SharedDefaults.isTestRunner else { return }
        KeychainItem.delete(baseQuery())
    }

    /// Whether a pair is on file, without exposing it.
    static var hasTokens: Bool {
        load() != nil
    }
}
