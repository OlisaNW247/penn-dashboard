import Foundation
import Security

/// Persists a student's PennKey username and password for the "stay signed
/// in" auto-login feature — the owner's decision, made after being told the
/// risks (CLAUDE.md's "stay signed in" entry): since Penn blocks Canvas
/// access tokens for students, the app optionally stores the student's own
/// PennKey credentials and uses them to sign back into Canvas automatically
/// when the session dies.
///
/// **Tier 3 (Keychain), `ThisDeviceOnly`, own service string — never Tier 2
/// (`UserDefaults.lhf`), never iCloud, never the shared App Group.** A
/// PennKey password is the student's master credential for essentially
/// everything at Penn (email, registration, financial aid, Canvas,
/// Gradescope-via-PennKey) — an order of magnitude more sensitive than any
/// other secret this app persists, including the Canvas session cookies and
/// access token next to this file. It is stored here ONLY because the
/// student typed it into Smooth's own credentials sheet
/// (`PennKeyCredentialsSheet`) and explicitly turned the "stay signed in"
/// toggle on; it is off by default, and nothing in the app ever scrapes it
/// out of the login page the student would otherwise type it into by hand
/// (see `PennKeyLoginForm`'s doc comment for why that alternative was
/// rejected outright).
///
/// It is sent to exactly one place: Penn's own login form
/// (`weblogin.pennkey.upenn.edu` / `idp.pennkey.upenn.edu`), over HTTPS,
/// inside the app's own isolated `WKWebView` (`LoginNavigationObserver`'s
/// visible-pane auto-fill, `CanvasSessionRenewer`'s silent renewal) — never
/// to Smooth's own backend, never anywhere else. It is never logged (not by
/// `Logger`, not by `print`, not by `LoginDiagnosticsLog`, not by
/// `DiagnosticsReport` — those surfaces report only whether the feature is
/// on/off and, when disabled, the reason, never the credential itself), and
/// it is deleted from the Keychain the moment the toggle goes off
/// (`AppState.disableStayLoggedIn()`) or the student disconnects Canvas
/// entirely (`AppState.disconnectCanvas()` calls that same method — see its
/// own doc comment for why disconnecting has to take the password with it).
///
/// Stored as one JSON blob (`{"username":..., "password":...}`) under a
/// single Keychain item, the same "one item per credential" isolation
/// `CanvasAccessTokenStore`'s doc comment argues for — a rotate/clear here
/// can never touch the Canvas session cookies or access token, and vice
/// versa. Two separate Keychain items (one per field) were considered and
/// rejected: the two values are only ever read or written together (there is
/// no operation that wants the username without the password or vice versa),
/// so a single atomic write is simpler and removes any window where one half
/// could be updated without the other.
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

    /// Persists `username`/`password`, replacing whatever was stored before
    /// — Keychain has no upsert, so this is delete-then-add like every other
    /// store in this codebase (`SessionCookieStore.write`,
    /// `ICSFeedURLStore.save`, `CanvasAccessTokenStore.save`).
    static func save(username: String, password: String) {
        guard let data = try? JSONEncoder().encode(Payload(username: username, password: password)) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        // Readable after first unlock only, this-device-only — never
        // migrated to a new device via an encrypted backup restore, same
        // accessibility class every other credential in this file's
        // neighborhood uses.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
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
