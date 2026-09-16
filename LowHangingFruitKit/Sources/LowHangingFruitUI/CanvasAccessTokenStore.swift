import Foundation
import LowHangingFruitKit
import Security

/// Persists the Canvas personal access token `CanvasAccessTokenMinter` mints
/// from inside the student's own logged-in login WebView (docs: see that
/// type, and `CanvasAccessToken`/`CanvasAccessTokenPolicy` in the Kit).
///
/// **Tier 3 (Keychain), never Tier 2 (`UserDefaults.lhf`), by the same rule
/// `SessionCookieStore` and `ICSFeedURLStore` already follow**: the token is
/// a bearer credential exactly as powerful as the student's own Canvas
/// login — `Authorization: Bearer <token>` on any Canvas host is
/// indistinguishable, server-side, from the student typing their PennKey and
/// Duo in themselves, for up to `CanvasAccessTokenPolicy.lifetime` (Canvas's
/// 120-day ceiling for a student account). It must never be synced (no
/// iCloud, no App Group — a second device silently gaining another device's
/// Canvas access is not a feature), never uploaded anywhere (it never
/// leaves this device at all: every Canvas client this Kit builds sends it
/// only to `canvas.upenn.edu`), and never logged — not even at debug level.
/// Anything that wants to say something about the token in a log line or the
/// diagnostics report says "present" / "absent" and a day count
/// (`DiagnosticsReport`), the same discipline `SessionCookieStore`'s own
/// diagnostics line already applies to cookies.
///
/// Own Keychain service string, not reused from `SessionCookieStore` or
/// `ICSFeedURLStore` — a token clear/rotate must never risk touching either
/// of those items, and giving every credential its own item is exactly the
/// isolation `SessionCookieStore`'s per-service split already argues for
/// (its doc comment: a purge keyed by domain substring can cross-contaminate
/// two different credentials that happen to share a domain; a purge keyed by
/// a dedicated service string cannot).
///
/// Unlike `SessionCookieStore`, there is no `merge()` here and therefore no
/// analogous `SharedDefaults.isTestRunner` write guard: that guard exists on
/// `SessionCookieStore.merge()` specifically because it is invoked
/// automatically, off the back of a live network response
/// (`refreshedCookieHandler`), by code a test could end up exercising by
/// accident — the guard keeps a stray real request from clobbering a
/// developer's own signed-in Mac session. `save()`/`clear()` here, like
/// `SessionCookieStore.save()`/`.clear()` and `ICSFeedURLStore.save()`/
/// `.clear()` before them, are only ever reached by an explicit caller (the
/// login pane after a real mint, or a test exercising this type directly) —
/// never by anything that runs unattended — so there is nothing for a guard
/// to protect against, and adding one here would only block the very tests
/// this file's round-trip depends on from calling `save()` at all.
enum CanvasAccessTokenStore {
    private static let service = "com.lhf.lowhangingfruit.canvasAccessToken"
    private static let account = "canvasAccessTokenV1"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Persists `token`, replacing whatever was stored before — Keychain has
    /// no upsert, so this is delete-then-add like every other store in this
    /// codebase (`SessionCookieStore.write`, `ICSFeedURLStore.save`).
    static func save(_ token: CanvasAccessToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = data
        // Readable after first unlock only, same as every other credential
        // this app persists — a locked device (or one restored from an
        // unencrypted backup, which this accessibility class refuses to
        // migrate into at all) must not be able to read this out.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    /// The raw persisted token, if any — with no usability check. Most
    /// callers want `usable(now:)` or `bearer(now:)` instead; this exists for
    /// callers that need to reason about a token Canvas may since have
    /// expired (e.g. deciding whether a mint is due, or what to hand
    /// `CanvasAccessTokenMinter.revoke` for the outgoing token when a new one
    /// replaces it).
    static func load() -> CanvasAccessToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(CanvasAccessToken.self, from: data)
    }

    /// Removes the persisted token outright — called on Canvas disconnect
    /// (after a best-effort revoke, see `AppState.disconnectCanvas`) and
    /// when Canvas itself has rejected the token (`AppState
    /// .noteCanvasAccessTokenRejected`).
    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    /// The persisted token, but only if `CanvasAccessTokenPolicy.isUsable`
    /// says so as of `now` — never expired, never empty. Every real caller
    /// wants this, not the raw `load()`, so a stale or hollowed-out entry
    /// reads exactly like "no token" rather than like a secret worth trying.
    static func usable(now: Date = Date()) -> CanvasAccessToken? {
        let token = load()
        return CanvasAccessTokenPolicy.isUsable(token, now: now) ? token : nil
    }

    /// The bare secret string a Canvas client should send as
    /// `Authorization: Bearer <token>` — `nil` when there's nothing usable,
    /// so a caller can pass this straight into a client's `accessToken:`
    /// parameter (`CanvasAuth.apply` falls back to cookies whenever this is
    /// `nil`) without a second usability check of its own.
    static func bearer(now: Date = Date()) -> String? {
        usable(now: now)?.token
    }
}
