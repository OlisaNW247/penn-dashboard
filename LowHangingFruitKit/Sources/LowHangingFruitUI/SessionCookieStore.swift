import Foundation
import LowHangingFruitKit
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
///
/// **Keyed by service, not by domain substring** (docs/CANVAS_LOGIN_HARDENING.md
/// item 2e). Canvas and Gradescope both flow through Penn SSO, so both can
/// leave cookies on `upenn.edu`/`pennkey.upenn.edu` — a domain-substring
/// purge like the old `remove(domainContains: "upenn")` would delete
/// Gradescope's PennKey session while "only" disconnecting Canvas, and vice
/// versa. Each service now gets its own Keychain item, so a Canvas
/// disconnect/purge can only ever touch cookies captured from the Canvas
/// login pane, regardless of which domain they happen to live on.
enum SessionCookieStore {
    enum Service: String, CaseIterable {
        case canvas
        case gradescope
    }

    private static func service(for s: Service) -> String {
        "com.lhf.lowhangingfruit.session.\(s.rawValue)"
    }
    private static let account = "sessionCookies"

    /// Merge the given cookies into `service`'s persisted set (replacing any
    /// with the same name+domain+path).
    static func save(_ cookies: [HTTPCookie], service: Service) {
        guard !cookies.isEmpty else { return }
        var stored = loadDicts(service: service)
        for cookie in cookies {
            let d = dict(from: cookie)
            stored.removeAll { $0["name"] == d["name"] && $0["domain"] == d["domain"] && $0["path"] == d["path"] }
            stored.append(d)
        }
        write(stored, service: service)
    }

    /// Merges freshly re-issued cookies into the persisted set for `service`:
    /// an incoming cookie replaces any stored cookie with the same
    /// (name, domain, path); everything else is kept. Cookies whose
    /// expiresDate is already past are dropped rather than stored — a
    /// Set-Cookie with a past expiry is the server deleting that cookie.
    /// Canvas's sliding sessions re-mint the session cookie on authenticated
    /// responses
    /// (`CanvasGradesClient.refreshedCookieHandler`), so a caller that wires
    /// that handler up to this merge keeps the most recent server-issued
    /// value available across relaunches.
    static func merge(_ fresh: [HTTPCookie], service: Service) {
        guard !fresh.isEmpty else { return }
        // Never touch the developer's real Keychain item under `swift
        // test` — the same trap `SharedDefaults.isTestRunner` guards
        // everywhere else in this codebase (CLAUDE.md: an unsandboxed
        // macOS test run resolves real on-device state without the
        // entitlement that would otherwise gate it).
        guard !SharedDefaults.isTestRunner else { return }
        persistMerged(fresh, service: service)
    }

    /// Store-level seam for the serialized Keychain suite. Production calls
    /// remain guarded from touching a developer's real Keychain under
    /// `swift test`; this explicit entry point lets one integration test prove
    /// the persisted blob is actually removed when the server deletes its
    /// final cookie, rather than merely proving the pure array merge.
    static func mergeForTesting(_ fresh: [HTTPCookie], service: Service) {
        precondition(SharedDefaults.isTestRunner)
        guard !fresh.isEmpty else { return }
        persistMerged(fresh, service: service)
    }

    private static func persistMerged(_ fresh: [HTTPCookie], service: Service) {
        let existing = load(service: service)
        let combined = merged(existing: existing, fresh: fresh)
        guard !combined.isEmpty else {
            // The server expired/deleted the last cookie. Leaving the old
            // Keychain blob in place resurrects the exact no-expiry cookie it
            // just invalidated on the next load.
            remove(service: service)
            return
        }
        save(combined, service: service)
    }

    /// Pure merge logic behind `merge(_:service:)`: an incoming cookie
    /// replaces any existing cookie with the same (name, domain, path);
    /// everything else in `existing` is kept as-is. An incoming cookie whose
    /// `expiresDate` is already past is dropped rather than carried forward
    /// — a `Set-Cookie` with a past expiry is the server's own way of
    /// deleting that cookie, so re-adding it would resurrect something the
    /// server just killed. No Keychain I/O, so this is the seam the test
    /// suite exercises directly instead of going through the real Keychain.
    static func merged(existing: [HTTPCookie], fresh: [HTTPCookie]) -> [HTTPCookie] {
        guard !fresh.isEmpty else { return existing }
        let now = Date()
        var result = existing
        for cookie in fresh {
            result.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if let expires = cookie.expiresDate, expires <= now { continue }
            result.append(cookie)
        }
        return result
    }

    /// Loads `service`'s persisted cookies, dropping only cookies whose
    /// server-supplied expiry is in the past. A true session cookie has no
    /// client-visible expiry; imposing our own 24-hour deadline used to throw
    /// away sessions that Canvas or Gradescope still accepted, guaranteeing
    /// avoidable reconnects after a day away from the app. Keep those cookies
    /// until the service rejects them. The authenticated clients already turn
    /// that rejection into the existing reconnect/silent-renewal path, so the
    /// server — not an invented local clock — remains the authority.
    static func load(service: Service) -> [HTTPCookie] {
        let now = Date()
        return loadDicts(service: service).compactMap { entry -> HTTPCookie? in
            guard let cookie = cookie(from: entry) else { return nil }
            let expiresAt = entry["expiresDate"].flatMap(isoFormatter.date(from:))
            return shouldRetain(expiresAt: expiresAt, now: now) ? cookie : nil
        }
    }

    /// Pure retention rule behind `load(service:)`, exposed internally so
    /// tests can pin the important distinction without modifying the shared
    /// Keychain: an explicit server expiry is authoritative; absence of one
    /// is not evidence that the session died.
    static func shouldRetain(expiresAt: Date?, now: Date) -> Bool {
        expiresAt.map { $0 > now } ?? true
    }

    /// Every service's persisted cookies, folded together. Only for read
    /// paths that genuinely don't care which service a cookie came from (e.g.
    /// diagnostics); prefer `load(service:)` everywhere a specific service's
    /// session is what's actually needed.
    static func loadAll() -> [HTTPCookie] {
        Service.allCases.flatMap { load(service: $0) }
    }

    /// True when `service` once had a captured login session that's now
    /// entirely expired/stale (every persisted entry was dropped by
    /// `load(service:)`'s staleness check) — as opposed to never having had
    /// one at all. Lets a caller distinguish "reconnect, your session died"
    /// from "you never logged in via this path" (e.g. a feed-only/paste-link
    /// Canvas user, who never captured a cookie session and shouldn't be
    /// nagged to reconnect one). See `AppState.canvasSessionExpired`.
    static func isExpired(service: Service) -> Bool {
        !loadDicts(service: service).isEmpty && load(service: service).isEmpty
    }

    // `ISO8601DateFormatter` isn't `Sendable`, but every use here is a simple
    // stateless format/parse call (no shared mutable configuration is ever
    // written after init), so a single shared instance is safe in practice.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    /// Removes every service's persisted cookies.
    static func clear() {
        for s in Service.allCases { SecItemDelete(baseQuery(service: s) as CFDictionary) }
    }

    /// Removes only `service`'s persisted cookies, leaving every other
    /// service's session untouched — including one that happens to share a
    /// domain (e.g. both flowing through `upenn.edu` Penn SSO).
    static func remove(service: Service) {
        SecItemDelete(baseQuery(service: service) as CFDictionary)
    }

    // MARK: - Keychain

    private static func baseQuery(service: Service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service(for: service),
            kSecAttrAccount as String: account,
        ]
    }

    private static func loadDicts(service: Service) -> [[String: String]] {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dicts = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return dicts
    }

    private static func write(_ dicts: [[String: String]], service: Service) {
        guard let data = try? JSONSerialization.data(withJSONObject: dicts) else { return }
        // Keychain has no upsert — delete any existing item, then add.
        SecItemDelete(baseQuery(service: service) as CFDictionary)
        var query = baseQuery(service: service)
        query[kSecValueData as String] = data
        // Readable after first unlock so the launch-time auto-sync can replay the
        // session; never migrated off this device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Serialization

    /// `HTTPCookiePropertyKey` has no built-in case for `HttpOnly` — Foundation
    /// only exposes it as a read-only computed property (`cookie.isHTTPOnly`)
    /// backed by this undocumented-but-stable raw key, same as WebKit/curl
    /// use on the wire.
    private static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")

    private static func dict(from cookie: HTTPCookie) -> [String: String] {
        var d: [String: String] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure ? "1" : "0",
            "httpOnly": cookie.isHTTPOnly ? "1" : "0",
            "capturedAt": isoFormatter.string(from: Date()),
        ]
        if let expires = cookie.expiresDate {
            d["expiresDate"] = isoFormatter.string(from: expires)
        }
        if let sameSite = cookie.sameSitePolicy {
            d["sameSite"] = sameSite.rawValue
        }
        return d
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
        if d["httpOnly"] == "1" { props[httpOnlyKey] = "TRUE" }
        if let expiresString = d["expiresDate"], let expires = isoFormatter.date(from: expiresString) {
            props[.expires] = expires
        }
        if let sameSite = d["sameSite"] {
            props[.sameSitePolicy] = sameSite
        }
        return HTTPCookie(properties: props)
    }
}
