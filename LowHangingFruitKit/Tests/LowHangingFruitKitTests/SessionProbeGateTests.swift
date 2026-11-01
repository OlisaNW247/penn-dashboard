import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The 2026-11-01 sign-out fix, parts 1 and 4 (docs/SIGNOUT_2026-11-01.md):
/// a clock-only expiry asks Canvas before it raises `canvasSessionExpired`,
/// and the banner needs a verdict from somewhere other than the clock.
///
/// Every state drives the probe through `setSessionProbeForTesting` and the
/// cookie clock through `forceCanvasCookieSessionExpiredForTesting`, both
/// per-instance, so nothing here writes the shared Keychain item or reads
/// the network (CLAUDE.md: the shared-state traps).
@MainActor
@Suite("Session probe gate")
struct SessionProbeGateTests {

    /// Counts how many times the injected probe ran.
    private final class Counter: @unchecked Sendable { var n = 0 }

    private func makeState(
        verdict: CanvasSessionProbe.Verdict,
        counter: Counter,
        clockExpired: Bool = true
    ) -> AppState {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        state.forceFixtureDataForTesting(false)
        state.forceCanvasCookieSessionExpiredForTesting(clockExpired)
        state.setSessionProbeForTesting { _ in
            counter.n += 1
            return CanvasSessionProbe.Result(verdict: verdict)
        }
        return state
    }

    // MARK: - The gate

    @Test("clock-only expiry plus alive: flag stays false, no renewal, proven-alive effects applied")
    func clockOnlyAlive() async {
        let counter = Counter()
        let state = makeState(verdict: .alive, counter: counter)
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.lastSilentRenewalAttemptOutcome == .landedOnLoginPage)

        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == false)
        await state.awaitPendingSessionProbe()

        #expect(counter.n == 1)
        #expect(state.canvasSessionExpired == false)
        #expect(state.isSilentRenewalInFlight == false)
        // `noteCanvasSessionProvenAlive` forgets the stale landing.
        #expect(state.lastSilentRenewalAttemptOutcome == nil)
    }

    @Test("clock-only expiry plus dead: the flag rises and the renewal edge fires")
    func clockOnlyDead() async {
        let counter = Counter()
        let state = makeState(verdict: .dead, counter: counter)
        // Fixture data makes the renewal itself a no-op (no WebKit), flipped
        // from inside the probe so the probe still runs.
        state.setSessionProbeForTesting { _ in
            counter.n += 1
            state.forceFixtureDataForTesting(true)
            return CanvasSessionProbe.Result(verdict: .dead)
        }
        let generationBefore = state.silentRenewalGeneration
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == false)
        await state.awaitPendingSessionProbe()

        #expect(counter.n == 1)
        #expect(state.canvasSessionExpired == true)
        // The renewal task is queued ahead of the probe's awaiter, so it has
        // already finished here; the generation counter is what proves one
        // was started.
        #expect(state.silentRenewalGeneration == generationBefore + 1)
        await state.awaitPendingSilentRenewal()
    }

    @Test("clock-only expiry plus unknown leaves the flag as it was, from either prior value")
    func clockOnlyUnknown() async {
        let counter = Counter()
        let state = makeState(verdict: .unknown, counter: counter)
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(counter.n == 1)
        #expect(state.canvasSessionExpired == false)
        #expect(state.isSilentRenewalInFlight == false)

        // Prior value true: first a dead answer raises it, then unknown keeps it.
        let counter2 = Counter()
        let state2 = makeState(verdict: .dead, counter: counter2)
        state2.setSessionProbeForTesting { _ in
            state2.forceFixtureDataForTesting(true)
            return CanvasSessionProbe.Result(verdict: .dead)
        }
        state2.refreshCanvasSessionExpiredState()
        await state2.awaitPendingSessionProbe()
        await state2.awaitPendingSilentRenewal()
        #expect(state2.canvasSessionExpired == true)
        state2.forceFixtureDataForTesting(false)
        state2.setSessionProbeForTesting { _ in CanvasSessionProbe.Result(verdict: .unknown) }
        state2.refreshCanvasSessionExpiredState()
        await state2.awaitPendingSessionProbe()
        #expect(state2.canvasSessionExpired == true)
    }

    @Test("confirmed dead raises the flag at once without asking Canvas")
    func confirmedDeadSkipsProbe() async {
        let counter = Counter()
        let state = makeState(verdict: .alive, counter: counter)
        state.forceFixtureDataForTesting(true) // keeps the renewal it starts off WebKit
        state.forceCanvasSessionConfirmedDeadForTesting()
        state.forceFixtureDataForTesting(false)
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == true)
        #expect(state.pendingSessionProbe == nil)
        #expect(counter.n == 0)
        state.forceFixtureDataForTesting(true)
        await state.awaitPendingSilentRenewal()
    }

    @Test("a missing login raises the flag at once without asking Canvas")
    func loginMissingSkipsProbe() async {
        let counter = Counter()
        let state = makeState(verdict: .alive, counter: counter, clockExpired: false)
        state.forceCanvasLoginHistoryForTesting(stored: true, legacyEvidence: true)
        state.forceCanvasLoginMissingInputsForTesting(isCanvasConnected: true, hasSavedCookies: false)
        state.forceFixtureDataForTesting(false)
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == true)
        #expect(counter.n == 0)
        state.forceFixtureDataForTesting(true)
        await state.awaitPendingSilentRenewal()
    }

    @Test("the probe is sent the stale saved canvas_session, and alive re-stamps it")
    func probeReceivesStaleSavedSession() async throws {
        let host = CanvasInstallation.penn.host
        let saved = try #require(HTTPCookie(properties: [
            .name: "canvas_session", .value: "saved", .domain: host, .path: "/",
        ]))
        let counter = Counter()
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        state.forceFixtureDataForTesting(false)
        state.forceCanvasCookieSessionExpiredForTesting(true)
        final class Box: @unchecked Sendable { var sent: [HTTPCookie] = [] }
        let box = Box()
        state.setSessionProbeForTesting(savedCookies: { [saved] }) { jar in
            counter.n += 1
            box.sent = jar
            return CanvasSessionProbe.Result(verdict: .alive)
        }
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(box.sent.map(\.name) == ["canvas_session"])
        #expect(box.sent.first?.value == "saved")
        #expect(state.canvasSessionExpired == false)
    }

    private final class Gate: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func open() { continuation?.resume(); continuation = nil }
    }

    @Test("a probe that outlives a disconnect-style invalidation changes nothing when it finishes")
    func staleProbeIsDiscarded() async {
        let gate = Gate()
        let state = makeState(verdict: .dead, counter: Counter())
        state.setSessionProbeForTesting { _ in
            await gate.wait()
            return CanvasSessionProbe.Result(verdict: .dead)
        }
        let generationBefore = state.silentRenewalGeneration
        state.refreshCanvasSessionExpiredState()
        while gate.continuation == nil { await Task.yield() }
        // The seam runs the same code disconnect, school switch and a fresh
        // login run (their own bodies touch the Keychain and shared defaults).
        state.invalidateSessionProbeForTesting()
        gate.open()
        await Task.yield()
        for _ in 0..<5 { await Task.yield() }
        #expect(state.canvasSessionExpired == false)
        #expect(state.sessionProbeSaidDead == false)
        #expect(state.silentRenewalGeneration == generationBefore)
    }

    @Test("a non-alive answer throttles the next probe for a minute")
    func unknownIsThrottled() async {
        let counter = Counter()
        let state = makeState(verdict: .unknown, counter: counter)
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(counter.n == 1)
    }

    @Test("a dead probe sets the banner verdict input")
    func deadProbeSetsBannerInput() async {
        let state = makeState(verdict: .dead, counter: Counter())
        state.setSessionProbeForTesting { _ in
            state.forceFixtureDataForTesting(true)
            return CanvasSessionProbe.Result(verdict: .dead)
        }
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(state.sessionProbeSaidDead)
        #expect(state.canvasSessionBannerHasVerdict)
        await state.awaitPendingSilentRenewal()
    }

    @Test("the 3.4.0 shared slot migrates only when the summary names a background run")
    func sharedSlotMigration() {
        let t = Date()
        let phone = "landedOnLoginPage \u{00B7} 2026-11-01 12:25 \u{00B7} background"
        #expect(AppState.shouldMigrateSharedRenewalSlot(foregroundAt: t, summary: phone, backgroundAt: nil))
        #expect(!AppState.shouldMigrateSharedRenewalSlot(foregroundAt: t, summary: phone, backgroundAt: t))
        #expect(!AppState.shouldMigrateSharedRenewalSlot(foregroundAt: nil, summary: phone, backgroundAt: nil))
        #expect(!AppState.shouldMigrateSharedRenewalSlot(foregroundAt: t, summary: "renewed \u{00B7} 2026-11-01 12:25 \u{00B7} foreground", backgroundAt: nil))
        #expect(!AppState.shouldMigrateSharedRenewalSlot(foregroundAt: t, summary: nil, backgroundAt: nil))
    }

    @Test("two recomputes while a probe is in flight make one probe")
    func oneProbeInFlight() async {
        let counter = Counter()
        let state = makeState(verdict: .alive, counter: counter)
        state.refreshCanvasSessionExpiredState()
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(counter.n == 1)
    }

    @Test("without an injected probe the test runner never probes")
    func noProbeUnderTestRunner() {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        state.forceCanvasCookieSessionExpiredForTesting(true)
        state.forceFixtureDataForTesting(true)
        state.refreshCanvasSessionExpiredState()
        #expect(state.pendingSessionProbe == nil)
    }

    // MARK: - Pure rules

    @Test("shouldProbeBeforeExpiring only for a clock-only expiry that may probe")
    func probeRule() {
        let probe = AppState.shouldProbeBeforeExpiring
        #expect(probe(true, false, false, true))
        #expect(!probe(false, false, false, true))
        #expect(!probe(true, true, false, true))
        #expect(!probe(true, false, true, true))
        #expect(!probe(true, false, false, false))
    }

    @Test("cookiesToRestamp keeps session cookies only, rotated winning, nothing from other hosts")
    func restampSelection() throws {
        func cookie(_ name: String, _ value: String, domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [
                .name: name, .value: value, .domain: domain, .path: "/",
            ]))
        }
        let host = CanvasInstallation.penn.host
        let folded = [
            try cookie("canvas_session", "old", domain: host),
            try cookie("_ga", "analytics", domain: host),
            try cookie("canvas_session", "other", domain: "example.com"),
        ]
        let rotated = [try cookie("canvas_session", "new", domain: host)]
        let out = AppState.cookiesToRestamp(folded: folded, rotated: rotated, canvasHost: host)
        #expect(out.count == 1)
        #expect(out.first?.value == "new")
        let noRotation = AppState.cookiesToRestamp(folded: folded, rotated: [], canvasHost: host)
        #expect(noRotation.map(\.value) == ["old"])
    }

    @Test("banner verdict table")
    func bannerRule() {
        typealias K = AppState.RenewalOutcomeKind
        func v(dead: Bool = false, missing: Bool = false, rejected: Bool = false,
               duo: Bool = false, last: K? = nil) -> Bool {
            AppState.bannerHasVerdict(confirmedDead: dead, loginMissing: missing,
                                      passwordRejected: rejected, awaitingDuo: duo,
                                      lastForegroundOutcome: last)
        }
        #expect(!v())
        #expect(!v(last: .notAttempted))
        #expect(!v(last: .renewed))
        #expect(!v(last: .abortedByLoginPane))
        #expect(v(dead: true))
        #expect(v(missing: true))
        #expect(v(rejected: true))
        #expect(v(duo: true))
        #expect(v(last: .landedOnLoginPage))
        #expect(v(last: .needsDuo))
        #expect(v(last: .passwordRejected))
        #expect(v(last: .timedOut))
        #expect(AppState.bannerHasVerdict(confirmedDead: false, loginMissing: false, passwordRejected: false,
                                          awaitingDuo: false, probeSaidDead: true, lastForegroundOutcome: .notAttempted))
    }
}
