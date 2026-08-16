import Foundation
import WebKit

/// Centralizes clearing of WebView cookie/cache jars — the live data stores
/// every login WebView reads from (`OnboardingView`'s `CanvasLoginPane`/
/// `GradescopeLoginPane`, both built by `makeWebView`). Before this file
/// existed, nothing in the app ever called `removeData`/`deleteCookie` (see
/// docs/CANVAS_LOGIN_DIAGNOSIS.md) — every login attempt silently reused
/// whatever cookies/cache an earlier attempt (successful, abandoned, or
/// since-expired) had left behind, with no way for a user to clear it short
/// of deleting the app — which, as it turns out, doesn't even touch the
/// Keychain-persisted cookie copy in `SessionCookieStore`, and doesn't run
/// before the onboarding screen anyway (see `AppState.resetAllLoginData`
/// doc comment for the full story).
///
/// Since docs/CANVAS_LOGIN_HARDENING.md (group 2a), Canvas and Gradescope
/// login panes each get their own persistent, isolated `WKWebsiteDataStore`
/// (`LoginDataStores.canvas` / `.gradescope`) instead of sharing
/// `WKWebsiteDataStore.default()`. Every function here now takes the store to
/// act on, defaulting to `.default()` for callers that still mean "the
/// shared/legacy store" (e.g. the onboarding "Reset everything" escape hatch,
/// which sweeps all of them).
@MainActor
enum WebsiteDataReset {
    /// Wipes WebView data (cookies, cache, local storage, etc.) in `store` for
    /// domains matching any of `needles` (case-insensitive substring match on
    /// each record's `displayName`, which WebKit derives from the domain's
    /// eTLD+1 — e.g. `"canvas.upenn.edu"` and `"idp.pennkey.upenn.edu"` both
    /// report `displayName == "upenn.edu"`; see `AppState.canvasLoginDomainHints`'s
    /// doc comment for why needles must be chosen with that in mind). Called
    /// right before every fresh "Connect Canvas" / "Connect Gradescope"
    /// attempt (from the owning login pane's `.task`) so each login starts a
    /// clean SP/IdP handshake regardless of what an earlier attempt in the
    /// same app process left behind, and from `AppState.disconnectCanvas` /
    /// `disconnectGradescope` so a Settings-driven disconnect doesn't leave a
    /// resumable session sitting in the live store either.
    static func purgeWebsiteData(
        matchingDomainContains needles: [String],
        in store: WKWebsiteDataStore = .default()
    ) async {
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
    /// escape hatch: every domain's cookies/cache/local storage in `store`,
    /// unfiltered. This is the one fix guaranteed to unblock a stuck user
    /// regardless of which theory about the underlying login bug turns out to
    /// be correct — it doesn't depend on knowing which domain or cookie is
    /// actually poisoned.
    static func purgeAllWebsiteData(in store: WKWebsiteDataStore = .default()) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
        }
    }

    /// Sweeps every cookie jar the app can write into: the legacy shared
    /// `.default()` store (still relevant for installs that logged in before
    /// group 2a's per-service isolated stores existed), the isolated Canvas
    /// and Gradescope stores, and `HTTPCookieStorage.shared` — a fourth jar
    /// (docs/CANVAS_LOGIN_HARDENING.md item 2d) that none of the WKWebsiteDataStore
    /// calls above ever touch, since it's a separate, non-WebKit cookie
    /// storage `URLSession` can also read from. Used by the onboarding
    /// "Reset login data" button, which is meant to be a genuine "start
    /// completely over" regardless of which store ended up holding the stale
    /// session.
    static func purgeAllLoginStores() async {
        await purgeAllWebsiteData(in: .default())
        await purgeAllWebsiteData(in: LoginDataStores.canvas)
        await purgeAllWebsiteData(in: LoginDataStores.gradescope)
        for cookie in HTTPCookieStorage.shared.cookies ?? [] {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}
