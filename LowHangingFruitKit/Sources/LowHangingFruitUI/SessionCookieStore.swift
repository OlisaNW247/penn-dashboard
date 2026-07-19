import Foundation
import Security

/// Persists the login cookies captured from the in-app WebView so the session
/// survives app launches. `WKWebsiteDataStore` drops *session* cookies (no
/// expiry) when the app quits — which is exactly what Gradescope and Penn SSO
/// use — so without this the user is silently logged out on every relaunch.
///
/// Stored in the **Keychain** (not UserDefaults): these are live authentication
/// tokens, so they must be encrypted at rest and kept out of unencrypted device
/// backups. We only need name/value/domain/path to replay the session via
/// `HTTPCookie.requestHeaderFields(with:)`, so that's all we store.
enum SessionCookieStore {
    private static let service = "com.lhf.lowhangingfruit.session"
    private static let account = "sessionCookies"

    /// Merge the given cookies into the persisted set (replacing any with the
    /// same name+domain+path).
    static func save(_ cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else { return }
        var stored = loadDicts()
        for cookie in cookies {
            let d = dict(from: cookie)
            stored.removeAll { $0["name"] == d["name"] && $0["domain"] == d["domain"] && $0["path"] == d["path"] }
            stored.append(d)
        }
        write(stored)
    }

    static func load() -> [HTTPCookie] {
        loadDicts().compactMap(cookie(from:))
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// Removes only the persisted cookies whose domain contains `needle`
    /// (case-insensitive) — e.g. purging a lapsed Canvas session without
    /// touching Gradescope's cookies in the same blob, or vice versa.
    static func remove(domainContains needle: String) {
        var stored = loadDicts()
        stored.removeAll { ($0["domain"] ?? "").localizedCaseInsensitiveContains(needle) }
        write(stored)
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func loadDicts() -> [[String: String]] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return dicts
    }

    private static func write(_ dicts: [[String: String]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dicts) else { return }
        // Keychain has no upsert — delete any existing item, then add.
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        // Readable after first unlock so the launch-time auto-sync can replay the
        // session; never migrated off this device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Serialization

    private static func dict(from cookie: HTTPCookie) -> [String: String] {
        [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure ? "1" : "0",
        ]
    }

    private static func cookie(from d: [String: String]) -> HTTPCookie? {
        guard let name = d["name"], let value = d["value"], let domain = d["domain"] else { return nil }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: d["path"] ?? "/",
        ]
        if d["secure"] == "1" { props[.secure] = "TRUE" }
        return HTTPCookie(properties: props)
    }
}
