import Foundation
import WebKit

/// Per-service, PERSISTENT, isolated `WKWebsiteDataStore`s for the Canvas and
/// Gradescope login WebViews (docs/CANVAS_LOGIN_DIAGNOSIS.md / group 2a).
///
/// Before this existed, both login panes shared `WKWebsiteDataStore.default()`
/// — the same jar the rest of the app's (nonexistent, since all real fetches
/// use explicit `Cookie` headers) WebKit browsing would use, if it ever did
/// any. Splitting Canvas and Gradescope into their own stores means:
/// - A Canvas purge can never touch a live Gradescope session and vice versa,
///   even when both flow through Penn SSO and would otherwise both leave
///   cookies on `upenn.edu` in the same shared jar.
/// - One `purgeAllWebsiteData(in:)` call clears exactly one service's login
///   state, with no domain-substring guessing required.
///
/// Deliberately NOT `.nonPersistent()` — an ephemeral store is the worst
/// possible input to WebKit's Intelligent Tracking Prevention classifier
/// (every load looks like a first-ever visit with no history), which is
/// itself a plausible contributor to the embedded-login friction this file
/// exists to reduce, and it would force a full Duo re-prompt on every single
/// "Connect" tap even for a user who just connected. `forIdentifier:` gives a
/// real, persistent, on-disk store — same durability as `.default()` — just
/// scoped to one identifier instead of shared app-wide.
///
/// **Single source of truth:** both the WebView's `WKWebViewConfiguration`
/// and the pane's post-login cookie capture (`CanvasLoginPane.connect()`,
/// `GradescopeLoginPane.connect()`) MUST read from the exact same store
/// instance, or capture reads an empty/different jar than the one the
/// WebView actually wrote into and every login reports "No session was found
/// yet" — see docs/CANVAS_LOGIN_DIAGNOSIS.md item 2a. Vending each store as a
/// single `static let` here (rather than constructing one per call site) is
/// what guarantees that.
@MainActor
enum LoginDataStores {
    /// Fixed, arbitrary UUIDs — not secrets, just stable identifiers so the
    /// same on-disk store is found again on every launch. Never reuse these
    /// for anything else; changing either would orphan whatever's currently
    /// persisted under it (equivalent to signing everyone out of that one
    /// service).
    private static let canvasStoreID = UUID(uuidString: "8F2D6A10-8B0A-4E9E-9C3A-6C1E9B2F0A01")!
    private static let gradescopeStoreID = UUID(uuidString: "8F2D6A10-8B0A-4E9E-9C3A-6C1E9B2F0A02")!

    // EXPERIMENT (2026-08-22, Stale Request investigation): temporarily the
    // shared default store instead of the isolated identifier store. The
    // on-device redirect chain shows the IdP losing its conversation cookie
    // between serving the PennKey form and receiving the POST (~1/6 success
    // in the app vs 3/4 in Private Safari, same minutes, both cold) — and
    // `WKWebsiteDataStore(forIdentifier:)` is the one remaining difference
    // from Safari's setup. If login rates jump to Safari levels on this
    // build, the identifier store's cookie handling is the culprit and we
    // need a permanent replacement for it; if rates stay bad, revert to the
    // line below and the store is exonerated.
    // static let canvas = WKWebsiteDataStore(forIdentifier: canvasStoreID)
    static let canvas = WKWebsiteDataStore.default()
    static let gradescope = WKWebsiteDataStore(forIdentifier: gradescopeStoreID)
}
