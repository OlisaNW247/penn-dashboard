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
/// Cookie-touching tests here (`.canvas` service) share
/// `SessionCookieStoreTests`' Keychain item for the same reason that suite's
/// own doc comment describes; `.serialized` keeps this suite's own tests
/// from racing each other, though not the other suite — an accepted,
/// pre-existing-shape risk, not one this file is positioned to close without
/// undoing the two-separate-files split this task was given.
@Suite("Canvas token wiring", .serialized)
struct CanvasTokenWiringTests {
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
        SessionCookieStore.clear()
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            SessionCookieStore.clear()
        }

        // A cookie set that's entirely stale — `SessionCookieStore.isExpired`
        // would read true off this alone (see `SessionCookieStoreTests`).
        let past = Date().addingTimeInterval(-3600)
        let staleCookie = HTTPCookie(properties: [
            .name: "sid",
            .value: "v",
            .domain: "canvas.upenn.edu",
            .path: "/",
            .expires: past,
        ])!
        SessionCookieStore.save([staleCookie], service: .canvas)
        #expect(SessionCookieStore.isExpired(service: .canvas))

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
        SessionCookieStore.clear()
        let state = makeState()
        defer {
            state.forceCanvasAccessTokenForTesting(nil)
            SessionCookieStore.clear()
        }

        let past = Date().addingTimeInterval(-3600)
        let staleCookie = HTTPCookie(properties: [
            .name: "sid",
            .value: "v",
            .domain: "canvas.upenn.edu",
            .path: "/",
            .expires: past,
        ])!
        SessionCookieStore.save([staleCookie], service: .canvas)

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
