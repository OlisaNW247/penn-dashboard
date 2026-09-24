import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Pins down how a Canvas personal access token changes `AppState`'s own
/// Canvas-availability story once one is on file: `hasCanvasCredentials` and
/// `canUseGradeWatcher` should read true off a token alone, with no cookies
/// at all, and `canvasSessionExpired` should stay false while a token has
/// months left on it even if the cookie session backing it has gone stale.
///
/// Every `AppState`-touching test here seeds the token through
/// `forceCanvasAccessTokenForTesting(_:)` — an in-memory, per-instance seam
/// — rather than writing `CanvasAccessTokenStore`'s real, process-wide
/// Keychain item. `AppState.forceCanvasSessionConfirmedDeadForTesting()`'s
/// doc comment (and CLAUDE.md's "Seeding a persisted flag..." trap) explains
/// why: Swift Testing runs suites concurrently by default, so a real write
/// from inside one test would be visible to every OTHER `AppState` instance
/// any concurrently-running suite constructs in the same process. A
/// memory-only seam on one instance cannot leak that way.
///
/// The one exception is `noteCanvasAccessTokenRejected`'s test below, which
/// calls a real method that really does clear the real Keychain item
/// (`CanvasAccessTokenStore.clear()`, mirroring `disconnectCanvas()`
/// clearing real session cookies) — that test races
/// `CanvasAccessTokenStoreTests` the same pre-existing way
/// `SessionCookieStoreTests` already races anything else that touches its
/// Keychain item concurrently (CLAUDE.md, "Two known flakes"); it does not
/// write a value anything could read back wrong, only clears one, so the
/// blast radius is a suite mid-round-trip losing its own fixture, not a
/// false green.
///
/// The two `canvasSessionExpired` tests below used to write a stale cookie
/// into the real `SessionCookieStore` Keychain item (`.canvas` service) to
/// force `SessionCookieStore.isExpired(service: .canvas)` true, then clear
/// it on the way out. That write, however briefly it lived, was visible to
/// `SessionCookieStoreTests`' own `AppState.init` calls running
/// concurrently in the same process — `.serialized` on THIS suite only
/// keeps its own tests from racing each other, it does nothing to stop an
/// unrelated, correctly-`.serialized` suite from racing it right back. That
/// made `SessionCookieStoreTests`' "a calendar-link-only install … cannot
/// use Grade Watcher" test fail deterministically in every full run on a
/// real Mac (2026-09-21), passing alone every time — the tell that gave it
/// away. Both tests now force `AppState.canvasSessionExpired`'s
/// cookie-derived half in memory instead
/// (`forceCanvasCookieSessionExpiredForTesting(_:)` — see its own doc
/// comment for the full incident), so this file no longer writes that
/// Keychain item at all.
///
/// The remaining `SessionCookieStore.clear()` calls elsewhere in this file
/// (the plain `hasCanvasCredentials`/`canUseGradeWatcher`-from-token-alone
/// tests) are a narrower, still-accepted risk: they only ever DELETE the
/// shared item to guarantee "no cookies," never write a specific value a
/// concurrent `SessionCookieStoreTests` assertion could read back wrong —
/// the same shape CLAUDE.md's "Two known flakes" already documents as
/// pre-existing and untouched.
@Suite("Canvas token wiring", .serialized)
struct CanvasTokenWiringTests {

    @Test("disabled access-token feature does not evaluate its Keychain loader")
    func disabledFeatureSkipsTokenLoader() {
        var didRead = false
        let value: CanvasAccessToken? = FeatureFlags.canvasAccessTokenValue {
            didRead = true
            return freshToken()
        }

        #expect(value == nil)
        #expect(!didRead)
    }
    @MainActor
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    private func freshToken(expiresAt: Date? = Date().addingTimeInterval(100 * 86_400)) -> CanvasAccessToken {
        CanvasAccessToken(token: "test-secret", id: "1", tokenHint: "...cret", expiresAt: expiresAt, createdAt: Date())
    }

    // MARK: - hasCanvasCredentials / canUseGradeWatcher

    @MainActor
    @Test("hasCanvasCredentials is true from a usable token alone, with no cookies at all")
    func hasCanvasCredentialsTrueFromTokenAlone() {
        SessionCookieStore.clear()
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            SessionCookieStore.clear()
        }

        state.forceCanvasAccessTokenForTesting(freshToken())

        #expect(state.hasCanvasCredentials)
    }

    @MainActor
    @Test("canUseGradeWatcher is true from a usable token alone, with no cookies at all")
    func canUseGradeWatcherTrueFromTokenAlone() {
        SessionCookieStore.clear()
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            SessionCookieStore.clear()
        }

        state.forceCanvasAccessTokenForTesting(freshToken())

        #expect(state.canUseGradeWatcher)
    }

    @MainActor
    @Test("hasCanvasCredentials is false with neither a token nor cookies")
    func hasCanvasCredentialsFalseWithNeither() {
        SessionCookieStore.clear()
        let state = makeState()
        defer { SessionCookieStore.clear() }

        state.forceCanvasAccessTokenForTesting(nil)

        #expect(!state.hasCanvasCredentials)
    }

    @MainActor
    @Test("hasCanvasCredentials is false once the forced token has expired")
    func hasCanvasCredentialsFalseWhenTokenExpired() {
        SessionCookieStore.clear()
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            SessionCookieStore.clear()
        }

        state.forceCanvasAccessTokenForTesting(freshToken(expiresAt: Date().addingTimeInterval(-3600)))

        #expect(!state.hasCanvasCredentials)
    }

    // MARK: - canvasSessionExpired

    @MainActor
    @Test("canvasSessionExpired is false with a healthy token, even while the cookie session is stale")
    func canvasSessionExpiredFalseWithHealthyToken() {
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            state.forceCanvasCookieSessionExpiredForTesting(nil)
        }

        // Forced in-memory, per-instance, rather than a real
        // `SessionCookieStore.save(...)` write to the shared, process-wide
        // Keychain item: that write (a real cookie with a past `.expires`,
        // exactly the shape below) is what made `SessionCookieStoreTests`
        // fail deterministically in every full run on a real Mac
        // (2026-09-21) — `.serialized` only ever protects a suite from its
        // own tests, never from an unrelated suite (this one) writing the
        // same Keychain item concurrently, `.serialized` or not. See
        // `AppState.forceCanvasCookieSessionExpiredForTesting`'s doc
        // comment for the full incident.
        state.forceCanvasCookieSessionExpiredForTesting(true)

        // A token with 100 days left — comfortably outside
        // `CanvasAccessTokenPolicy.renewalWindow` (7 days) — should short-
        // circuit the stale-cookie read entirely.
        state.forceCanvasAccessTokenForTesting(freshToken())
        state.refreshCanvasSessionExpiredState()

        #expect(!state.canvasSessionExpired)
    }

    @MainActor
    @Test("canvasSessionExpired falls back to the cookie rule once the token is inside its own renewal window")
    func canvasSessionExpiredFallsBackNearTokenExpiry() {
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            state.forceCanvasCookieSessionExpiredForTesting(nil)
        }

        // Forced in-memory — see `canvasSessionExpiredFalseWithHealthyToken`
        // just above for why this is no longer a real Keychain write.
        state.forceCanvasCookieSessionExpiredForTesting(true)

        // 1 day left — inside the 7-day renewal window, so this is NOT
        // "healthy enough to skip the expiry check" and the stale cookie
        // rule should apply as normal.
        state.forceCanvasAccessTokenForTesting(freshToken(expiresAt: Date().addingTimeInterval(86_400)))
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasSessionExpired)
    }

    // MARK: - tokenIsHealthyEnoughToSkipExpiryCheck (pure)

    @Test("tokenIsHealthyEnoughToSkipExpiryCheck is false for nil")
    func healthyCheckFalseForNil() {
        #expect(!AppState.tokenIsHealthyEnoughToSkipExpiryCheck(nil, now: Date()))
    }

    @Test("tokenIsHealthyEnoughToSkipExpiryCheck is true for a token with no expiry at all")
    func healthyCheckTrueForNeverExpires() {
        let now = Date()
        let token = CanvasAccessToken(token: "t", id: nil, tokenHint: nil, expiresAt: nil, createdAt: now)
        #expect(AppState.tokenIsHealthyEnoughToSkipExpiryCheck(token, now: now))
    }

    @Test("tokenIsHealthyEnoughToSkipExpiryCheck is false once inside the renewal window")
    func healthyCheckFalseInsideRenewalWindow() {
        let now = Date()
        let token = CanvasAccessToken(
            token: "t",
            id: nil,
            tokenHint: nil,
            expiresAt: now.addingTimeInterval(CanvasAccessTokenPolicy.renewalWindow - 1),
            createdAt: now
        )
        #expect(!AppState.tokenIsHealthyEnoughToSkipExpiryCheck(token, now: now))
    }

    // MARK: - noteCanvasAccessTokenRejected

    @MainActor
    @Test("noteCanvasAccessTokenRejected clears the token without marking the cookie session confirmed-dead")
    func rejectedTokenDoesNotMarkSessionDead() {
        SessionCookieStore.clear()
        CanvasAccessTokenStore.clear()
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            CanvasAccessTokenStore.clear()
            state.disconnectCanvas()
            SessionCookieStore.clear()
        }

        // The first draft of this test asserted `!canvasSessionExpired`
        // outright, on the reasoning "no cookies on record, so the cookie
        // verdict is false". It failed once in the first few runs on a Mac:
        // the cookie verdict reads the shared Keychain and the sticky
        // confirmed-dead flag in `UserDefaults.lhf`, both of which other
        // suites running alongside can leave non-empty (CLAUDE.md, the two
        // known flakes have exactly this shape). What this test is actually
        // about is narrower: rejecting a token must not CHANGE the cookie
        // verdict. So measure that verdict with no token first, and assert
        // the rejection lands back on the same value, whatever the shared
        // state happens to hold this run.
        state.forceCanvasAccessTokenForTesting(nil)
        state.refreshCanvasSessionExpiredState()
        let cookieVerdictWithoutToken = state.canvasSessionExpired

        state.forceCanvasAccessTokenForTesting(freshToken())
        state.refreshCanvasSessionExpiredState()
        #expect(!state.canvasSessionExpired)

        state.noteCanvasAccessTokenRejected()

        #expect(!state.hasCanvasCredentials)
        #expect(CanvasAccessTokenStore.load() == nil)

        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == cookieVerdictWithoutToken)
    }
}
