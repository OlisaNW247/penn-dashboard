import Foundation
import Security
import LowHangingFruitKit

/// Keeps the student's Ed Discussion session token in the Keychain.
///
/// **What it holds.** Ed's web client does not keep its session in a cookie.
/// After the Canvas LTI launch lands on `edstem.org`, the signed-in state is
/// a token in the page's `localStorage` (`authToken`), `document.cookie` is
/// empty, and a cookie-only `GET /api/user` answers 401 (the 2026-10-09 probe
/// on a real phone; `docs/ED_DISCUSSION.md`). `EdSessionLauncher` reads that
/// token out of the page after landing and `EdDiscussionCoordinator` sends it
/// as `EdAuth.token`'s `x-token` header. This is that token: the student's
/// own Ed session, obtained through their own Canvas login.
///
/// **Why it lives here (Tier 3, the Keychain).** CLAUDE.md's three-tier rule:
/// a bearer credential never goes in `UserDefaults` (Tier 2) or the ledger
/// (Tier 1). Whoever holds this string is the student on Ed, exactly as with
/// the Canvas session cookies, so it gets the same treatment as
/// `SessionCookieStore`: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// never synchronizable (no iCloud Keychain, no backup restore onto another
/// device), its own Keychain item so removing it can never touch a Canvas or
/// Gradescope session, never logged or printed anywhere, and deleted when
/// Canvas is disconnected (`EdDiscussionCoordinator.clearCaches`, which
/// `AppState.disconnectCanvas` already calls) because it exists only as a
/// child of the Canvas login.
///
/// **Under `swift test`.** Every operation is inert when
/// `SharedDefaults.isTestRunner` is true: `save` and `remove` do nothing and
/// `load` answers nil. An unsandboxed macOS test run would otherwise read and
/// delete the developer's real token (the same trap `SessionCookieStore.merge`
/// and `SharedDefaults.isTestRunner` document). The Keychain round trip is
/// therefore not exercised by the suite; it is the same SecItem pattern as
/// `PennKeyCredentialStore`, and has been checked on a device only through the
/// DEBUG probe.
enum EdSessionTokenStore {
    private static let service = "com.lhf.lowhangingfruit.session.ed.token"
    private static let account = "edAuthToken"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit, so the item can never be picked up by iCloud Keychain.
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    /// Stores `token`, replacing any earlier one. An empty string is ignored
    /// rather than stored, so a failed page read can never overwrite a good
    /// token with nothing.
    static func save(_ token: String) {
        guard !SharedDefaults.isTestRunner else { return }
        guard !token.isEmpty, let data = token.data(using: .utf8) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    /// The stored token, if any.
    static func load() -> String? {
        guard !SharedDefaults.isTestRunner else { return nil }
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Deletes the stored token. Safe to call when there is none.
    static func remove() {
        guard !SharedDefaults.isTestRunner else { return }
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// Whether a token is on file, without exposing it.
    static var hasToken: Bool {
        load() != nil
    }
}
