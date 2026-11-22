import Foundation
#if os(iOS)
import Security
#endif

/// A copy of the Canvas session cookies in a Keychain item that the app and
/// its own extensions can both read, so the Sweeper's notification extension
/// can ask Canvas's planner while the app is force-quit.
///
/// This is a deliberate second copy of a bearer credential. It stays
/// device-only (`AfterFirstUnlockThisDeviceOnly`, not synchronizable), is read
/// by exactly one consumer (that extension), and is deleted on Canvas
/// disconnect. It lives under the bare App Group id as its access group; the
/// app's existing Keychain items stay in the default group and are untouched.
/// Cookie names and values are never logged.
///
/// Only `encode`/`decode` are pure and tested on macOS. The Keychain calls
/// exist on iOS alone and do nothing under a test runner.
public enum SweepCookieMirror {
    public static let service = "com.lhf.lowhangingfruit.sweeper-cookies"
    public static let accessGroup = "group.com.lhf.lowhangingfruit"

    struct Record: Codable, Equatable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresDate: Date?
        let isSecure: Bool
        let isHTTPOnly: Bool
    }

    /// Keeps only cookies whose domain matches `host`: equal to it, or a
    /// parent domain (leading dot stripped) that `host` ends with.
    static func encode(_ cookies: [HTTPCookie], host: String) -> Data {
        let host = host.lowercased()
        let records: [Record] = cookies.compactMap { c in
            let domain = c.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard !bare.isEmpty, host == bare || host.hasSuffix("." + bare) else { return nil }
            return Record(name: c.name, value: c.value, domain: c.domain, path: c.path,
                          expiresDate: c.expiresDate, isSecure: c.isSecure, isHTTPOnly: c.isHTTPOnly)
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(records)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [HTTPCookie] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        guard let records = try? d.decode([Record].self, from: data) else { return [] }
        return records.compactMap { r in
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: r.name, .value: r.value, .domain: r.domain, .path: r.path,
            ]
            if let exp = r.expiresDate { props[.expires] = exp }
            if r.isSecure { props[.secure] = "TRUE" }
            if r.isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            return HTTPCookie(properties: props)
        }
    }

    #if os(iOS)
    private static func baseQuery(host: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
        if let host { q[kSecAttrAccount as String] = host }
        return q
    }

    /// Upserts the host's cookies. An empty match deletes the item instead.
    public static func save(cookies: [HTTPCookie], host: String) {
        guard !SharedDefaults.isTestRunner else { return }
        let data = encode(cookies, host: host)
        let query = baseQuery(host: host)
        if cookies.isEmpty || decode(data).isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func load(host: String) -> [HTTPCookie] {
        guard !SharedDefaults.isTestRunner else { return [] }
        var query = baseQuery(host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return [] }
        return decode(data)
    }

    public static func deleteAll() {
        guard !SharedDefaults.isTestRunner else { return }
        SecItemDelete(baseQuery(host: nil) as CFDictionary)
    }
    #else
    public static func save(cookies: [HTTPCookie], host: String) {}
    public static func load(host: String) -> [HTTPCookie] { [] }
    public static func deleteAll() {}
    #endif
}
