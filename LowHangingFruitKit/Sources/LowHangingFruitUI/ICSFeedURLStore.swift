import Foundation
import Security

/// Persists the Canvas calendar feed URL in the Keychain, not UserDefaults
/// (docs/CANVAS_LOGIN_HARDENING.md item 3c).
///
/// The feed URL is a bearer credential: Canvas's `/feeds/calendars/user_<token>.ics`
/// embeds a per-user token in the URL itself — anyone who has the link can
/// fetch that student's assignments and due dates with no further
/// authentication. UserDefaults is unencrypted, included in unencrypted
/// device backups, and readable by anything with app-container access;
/// Keychain (like `SessionCookieStore`, which already treats login cookies
/// this way) is the appropriate place for a value that grants access on its
/// own.
enum ICSFeedURLStore {
    private static let service = "com.lhf.lowhangingfruit.icsFeedURL"
    private static let account = "canvasICSURL"
    /// The UserDefaults key this replaces — read once for a one-time,
    /// transparent migration so existing users aren't silently signed out by
    /// this change landing in an update.
    private static let legacyUserDefaultsKey = "canvasICSURL"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ url: String) {
        guard !url.isEmpty else {
            clear()
            return
        }
        guard let data = url.data(using: .utf8) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// Loads the persisted feed URL, migrating a pre-3c UserDefaults value in
    /// (and removing it from UserDefaults) the first time this runs on a
    /// device that has one. Idempotent — a no-op on every call after the
    /// first.
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

        // One-time migration from the old UserDefaults-backed storage.
        //
        // Deliberately `.standard` and not `UserDefaults.lhf`, which is why both
        // lines carry the opt-out marker the source scan in
        // `SharedDefaultsMigrationTests` looks for. The app's private domain is
        // where this value physically is: `SharedDefaults` excludes
        // `canvasICSURL` from its key list precisely so a bearer credential is
        // never copied into the shared container, so reading through the shared
        // accessor would look somewhere it was never written and quietly sign
        // the user out on upgrade. Removing it here is what makes that
        // exclusion complete rather than merely partial.
        // lhf:allow-standard-defaults — migration source, see above
        if let legacy = UserDefaults.standard.string(forKey: legacyUserDefaultsKey), !legacy.isEmpty {
            save(legacy)
            // lhf:allow-standard-defaults — migration source, see above
            UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
            return legacy
        }
        return ""
    }
}
