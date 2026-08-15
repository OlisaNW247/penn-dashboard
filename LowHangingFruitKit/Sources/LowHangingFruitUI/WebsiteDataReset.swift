import Foundation
import WebKit

/// Centralizes clearing of the shared `WKWebsiteDataStore.default()` — the
/// live WebView cookie/cache jar every login WebView shares
/// (`OnboardingView`'s `CanvasLoginPane`/`GradescopeLoginPane`, both built by
/// `makeWebView`). Before this file existed, nothing in the app ever called
/// `removeData`/`deleteCookie` (see docs/CANVAS_LOGIN_DIAGNOSIS.md) — every
/// login attempt silently reused whatever cookies/cache an earlier attempt
/// (successful, abandoned, or since-expired) had left in this store, with no
/// way for a user to clear it short of deleting the app — which, as it turns
/// out, doesn't even touch the Keychain-persisted cookie copy in
/// `SessionCookieStore`, and doesn't run before the onboarding screen anyway
/// (see `AppState.resetAllLoginData` doc comment for the full story).
@MainActor
enum WebsiteDataReset {
    /// Wipes WebView data (cookies, cache, local storage, etc.) for domains
    /// matching any of `needles` (case-insensitive substring match on each
    /// record's `displayName`, which WebKit derives from the domain — e.g.
    /// "upenn.edu"). Called right before every fresh "Connect Canvas" /
    /// "Connect Gradescope" attempt (`makeWebView`) so each login starts a
    /// clean SP/IdP handshake regardless of what an earlier attempt in the
    /// same app process left behind, and from `AppState.disconnectCanvas` /
    /// `disconnectGradescope` so a Settings-driven disconnect doesn't leave a
    /// resumable session sitting in the live store either.
    static func purgeWebsiteData(matchingDomainContains needles: [String]) async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { (continuation: CheckedContinuation<[WKWebsiteDataRecord], Never>) in
            store.fetchDataRecords(ofTypes: types) { continuation.resume(returning: $0) }
        }
        let matching = records.filter { record in
            needles.contains { record.displayName.localizedCaseInsensitiveContains($0) }
        }
        guard !matching.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, for: matching) { continuation.resume() }
        }
    }

    /// Full reset for the onboarding "Trouble connecting? Reset login data"
    /// escape hatch: every domain's cookies/cache/local storage in the live
    /// WebView data store, unfiltered. This is the one fix guaranteed to
    /// unblock a stuck user regardless of which theory about the underlying
    /// login bug turns out to be correct — it doesn't depend on knowing which
    /// domain or cookie is actually poisoned.
    static func purgeAllWebsiteData() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
        }
    }
}
