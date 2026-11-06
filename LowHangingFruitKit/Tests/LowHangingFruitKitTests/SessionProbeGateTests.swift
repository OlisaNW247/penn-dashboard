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

    @Test("a dead probe records the verdict and shows no status line by itself")
    func deadProbeSetsBannerInput() async {
        let state = makeState(verdict: .dead, counter: Counter())
        state.setSessionProbeForTesting { _ in
            state.forceFixtureDataForTesting(true)
            return CanvasSessionProbe.Result(verdict: .dead)
        }
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(state.sessionProbeSaidDead)
        #expect(state.canvasSessionStatusLine() == .none)
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

    @Test("status line: every case, in priority order")
    func statusLineRule() {
        typealias L = AppState.CanvasSessionStatusLine
        func line(flight: Bool = false, for secs: TimeInterval = 0, push: Bool = false, duo: Bool = false,
                  rejected: Bool = false, missing: Bool = false, saved: Bool = true) -> L {
            AppState.canvasSessionStatusLine(
                renewalInFlight: flight, inFlightFor: secs, duoPushSent: push, awaitingDuo: duo,
                passwordRejected: rejected, loginMissing: missing, hasSavedCredentials: saved)
        }
        #expect(line() == .none)
        #expect(line(rejected: true) == .passwordChanged)
        #expect(line(flight: true, for: 10, push: true, duo: true, rejected: true, missing: true, saved: false) == .passwordChanged)
        #expect(line(duo: true) == .duoNeedsYou)
        #expect(line(flight: true, for: 10, duo: true) == .reconnecting)
        #expect(line(duo: true, missing: true, saved: false) == .duoNeedsYou)
        #expect(line(missing: true, saved: false) == .signInNeeded)
        #expect(line(missing: true, saved: true) == .none)
        #expect(line(flight: true, for: 1, push: true) == .duoPush)
        #expect(line(flight: true, for: 120, push: true) == .duoPush)
        #expect(line(flight: true, for: 3) == .reconnecting)
        #expect(line(flight: true, for: 2.9) == .none)
        #expect(line(flight: true, for: 0) == .none)
        // A Duo latch over a session the app believes live says nothing.
        #expect(AppState.canvasSessionStatusLine(
            renewalInFlight: false, inFlightFor: 0, duoPushSent: false, awaitingDuo: true,
            passwordRejected: false, loginMissing: false, hasSavedCredentials: true,
            sessionExpired: false) == .none)
        #expect(AppState.canvasSessionStatusLine(
            renewalInFlight: false, inFlightFor: 0, duoPushSent: false, awaitingDuo: true,
            passwordRejected: false, loginMissing: false, hasSavedCredentials: true,
            sessionExpired: true) == .duoNeedsYou)
        // A push flag left over without an attempt in flight says nothing.
        #expect(line(push: true) == .none)
    }

    @Test("the clock alone, a confirmed-dead latch or a dead probe show nothing")
    func clockAloneShowsNothing() {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        // A saved password is what makes silence correct: with something to
        // fill the login form with, the app fixes a dead session itself and
        // shows nothing. (Without one, two landings now stop silent renewal
        // and show the "sign in to canvas" row; see SilentRenewalCoreTests,
        // item 15. This test pinned the owner's no-banner rule for a student
        // who has a password saved, so it keeps that state.)
        state.silentRenewalHasCredentialForTesting = true
        state.forceCanvasCookieSessionExpiredForTesting(true)
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired)
        #expect(state.canvasSessionStatusLine() == .none)
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.canvasSessionStatusLine() == .none)
    }

    @Test("a failed, timed-out or refused attempt shows nothing")
    func failedAttemptShowsNothing() {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        for outcome in [CanvasSessionRenewer.Outcome.timedOut, .landedOnLoginPage, .notAttempted(reason: "x")] {
            state.noteRenewalOutcomeForTesting(outcome)
            #expect(state.canvasSessionStatusLine() == .none)
        }
    }

    @Test("an installation in preview mode never shows a line")
    func fixtureShowsNothing() {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        state.forceFixtureDataForTesting(true)
        #expect(state.canvasSessionStatusLine() == .none)
    }

    @Test("keepalive rule: stale capture probes, fresh, absent, future or just-alive do not")
    func keepAliveRule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func rule(captured: TimeInterval?, alive: TimeInterval? = nil, min: TimeInterval = AppState.keepAliveForegroundAge) -> Bool {
            AppState.shouldKeepAliveProbe(
                newestCaptureAt: captured.map { now.addingTimeInterval(-$0) },
                now: now,
                lastAliveAt: alive.map { now.addingTimeInterval(-$0) },
                minimumAge: min)
        }
        let hour: TimeInterval = 3600
        #expect(rule(captured: 12 * hour))
        #expect(rule(captured: 20 * hour))
        #expect(!rule(captured: 12 * hour - 1))
        #expect(!rule(captured: nil))
        #expect(!rule(captured: -hour))
        #expect(!rule(captured: 13 * hour, alive: 5 * 60))
        #expect(rule(captured: 13 * hour, alive: 11 * 60))
        #expect(rule(captured: 6 * hour, min: AppState.keepAliveBackgroundAge))
        #expect(!rule(captured: 6 * hour - 1, min: AppState.keepAliveBackgroundAge))
        #expect(AppState.keepAliveForegroundAge == 43_200)
        #expect(AppState.keepAliveBackgroundAge == 21_600)
    }

    @Test("a foreground recompute on a clock-live but 13-hour-old session probes once")
    func keepAliveProbesForeground() async {
        let counter = Counter()
        let state = makeState(verdict: .alive, counter: counter)
        state.forceCanvasCookieSessionExpiredForTesting(false)
        state.setKeepAliveNewestCaptureForTesting { Date().addingTimeInterval(-13 * 3600) }
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(counter.n == 1)
        #expect(!state.canvasSessionExpired)
        // The alive answer is reused, so an immediate recompute does not ask again.
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(counter.n == 1)
    }

    @Test("a fresh capture makes no keepalive probe")
    func keepAliveSkippedWhenFresh() async {
        let counter = Counter()
        let state = makeState(verdict: .alive, counter: counter)
        state.forceCanvasCookieSessionExpiredForTesting(false)
        state.setKeepAliveNewestCaptureForTesting { Date().addingTimeInterval(-3600) }
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        #expect(counter.n == 0)
    }

    @Test("a background wake probes at 6 hours and a dead answer starts no renewal")
    func backgroundKeepAlive() async {
        let counter = Counter()
        let state = makeState(verdict: .dead, counter: counter)
        state.forceCanvasCookieSessionExpiredForTesting(false)
        state.setKeepAliveNewestCaptureForTesting { Date().addingTimeInterval(-7 * 3600) }
        state.renewalContext = .background
        await state.runBackgroundKeepAliveProbe()
        #expect(counter.n == 1)
        #expect(state.sessionProbeSaidDead)
        #expect(state.pendingSilentRenewal == nil)
    }
}
