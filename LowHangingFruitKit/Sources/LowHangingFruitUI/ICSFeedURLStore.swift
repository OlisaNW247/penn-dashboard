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

    /// Stores the feed URL, replacing any earlier one (`KeychainItem.write`:
    /// update in place, add only when nothing is there, so a refused write
    /// leaves the previous URL rather than none). An empty URL clears. False
    /// when the Keychain refused.
    @discardableResult
    static func save(_ url: String) -> Bool {
        guard !url.isEmpty else {
            clear()
            return true
        }
        guard let data = url.data(using: .utf8) else { return false }
        return KeychainItem.write(data, base: baseQuery()) == errSecSuccess
    }

    static func clear() {
        KeychainItem.delete(baseQuery())
    }

    /// The persisted feed URL in three answers (see `KeychainRead`), without
    /// the UserDefaults migration `load()` performs.
    static func read() -> KeychainRead<String> {
        KeychainItem.read(baseQuery()).decoded { String(data: $0, encoding: .utf8) }
    }

    /// Loads the persisted feed URL, migrating a pre-3c UserDefaults value in
    /// (and removing it from UserDefaults) the first time this runs on a
    /// device that has one. Idempotent — a no-op on every call after the
    /// first.
    ///
    /// The migration runs only when the Keychain said the item is not there.
    /// On an unavailable read the old code fell straight into it, and a
    /// leftover UserDefaults value then `save`d over an item that existed and
    /// merely could not be read. An unavailable read answers "" for this
    /// launch and leaves everything alone.
    static func load() -> String {
        switch read() {
        case let .found(value):
            return value
        case .unavailable:
            return ""
        case .notFound:
            break
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
            // Removed only once the Keychain has it: the old code dropped the
            // UserDefaults copy whatever the write returned, so one refused
            // write on the first launch after an upgrade lost the URL.
            if save(legacy) {
                // lhf:allow-standard-defaults — migration source, see above
                UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
            }
            return legacy
        }
        return ""
    }
}
