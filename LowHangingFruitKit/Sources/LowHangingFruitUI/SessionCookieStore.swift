import Foundation

/// Persists the login cookies captured from the in-app WebView so the session
/// survives app launches. `WKWebsiteDataStore` drops *session* cookies (no
/// expiry) when the app quits — which is exactly what Gradescope and Penn SSO
/// use — so without this the user is silently logged out on every relaunch.
///
/// We only need name/value/domain/path to replay the session via
/// `HTTPCookie.requestHeaderFields(with:)`, so that's all we store.
enum SessionCookieStore {
    private static let key = "persistedSessionCookies"

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
        UserDefaults.standard.set(stored, forKey: key)
    }

    static func load() -> [HTTPCookie] {
        loadDicts().compactMap(cookie(from:))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Serialization

    private static func loadDicts() -> [[String: String]] {
        UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []
    }

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
