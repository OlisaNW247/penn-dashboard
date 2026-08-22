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

    // Tested on device 2026-08-22 (Stale Request investigation): swapping
    // this for `.default()` did NOT change the failure rate (0/6, same
    // failure signature — Stale Request straight after the PennKey form
    // POST), so the identifier store is not what breaks the IdP handshake.
    static let canvas = WKWebsiteDataStore(forIdentifier: canvasStoreID)
    static let gradescope = WKWebsiteDataStore(forIdentifier: gradescopeStoreID)
}
