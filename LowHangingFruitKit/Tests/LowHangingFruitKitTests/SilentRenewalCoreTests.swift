import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The silent-renewal core after the background-wake review: the failed
/// navigation rule, the renewer's seeded clocks, the persisted Duo stand-down,
/// "consecutive" landings, and the awaitable renewal task behind the banner.
///
/// `@MainActor` because `CanvasSessionRenewer` and `AppState` are. Nothing here
/// touches WebKit or the network: `noteRenewalOutcomeForTesting` and
/// `noteCanvasSessionProvenAliveForTesting` are memory-only seams, and every
/// state below pins `forceCanvasCookieSessionExpiredForTesting(false)` first so
/// a recompute can never start a real renewal task whose `.notAttempted`
/// outcome would persist the dead flag into the shared defaults domain.
/// Background-context outcomes are used wherever the foreground path would
/// persist a latch (`autoLoginAwaitingDuo`).
@MainActor
@Suite("Silent renewal core")
struct SilentRenewalCoreTests {
    // MARK: - failedNavigationOutcome

    private func failed(_ urlString: String?, host: String = CanvasInstallation.penn.host) -> CanvasSessionRenewer.Outcome {
        CanvasSessionRenewer.failedNavigationOutcome(
            finalURL: urlString.flatMap { URL(string: $0) },
            canvasHost: host
        )
    }

    @Test("a failed navigation with no URL is unknown, never a login landing")
    func failedWithNoURL() {
        #expect(failed(nil) == .timedOut)
    }

    @Test("a failed navigation on a Canvas URL is unknown")
    func failedOnCanvas() {
        #expect(failed("https://canvas.upenn.edu/") == .timedOut)
    }

    @Test("a failed navigation on an unrecognised host is unknown")
    func failedOnUnknownHost() {
        #expect(failed("https://example.com/portal") == .timedOut)
    }

    @Test("a failed navigation parked on the IdP login host is a landing")
    func failedOnIdP() {
        #expect(failed("https://idp.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO") == .landedOnLoginPage)
        #expect(failed("https://weblogin.pennkey.upenn.edu/idp/x") == .landedOnLoginPage)
    }

    @Test("a failed navigation parked on Duo is needsDuo, like a timeout there")
    func failedOnDuo() {
        #expect(failed("https://api-abc123.duosecurity.com/frame/web/v1/auth") == .needsDuo)
    }

    @Test("non-Penn installations: Canvas failure is unknown, a recognised login host is a landing")
    func failedOnNonPenn() {
        let host = "courseworks.columbia.edu"
        #expect(failed("https://courseworks.columbia.edu/", host: host) == .timedOut)
        #expect(failed("https://sso.columbia.edu/login", host: host) == .landedOnLoginPage)
    }

    // MARK: - Renewer clocks

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the renewer's attempt cooldown and credential clock are seeded from persistence")
    func renewerSeeds() {
        let renewer = CanvasSessionRenewer(
            isLoginPaneActive: { false },
            lastCredentialSubmissionAt: t0,
            lastAttemptAt: t0.addingTimeInterval(60)
        )
        #expect(renewer.lastCredentialSubmissionAt == t0)
        #expect(renewer.lastAttemptAt == t0.addingTimeInterval(60))
        #expect(CanvasSessionRenewer(isLoginPaneActive: { false }).lastAttemptAt == nil)
    }

    @Test("a seeded attempt blocks the hour cooldown but not the foreground spacing")
    func seededAttemptAndPerCallCooldown() {
        let now = t0.addingTimeInterval(15 * 60)
        func gate(cooldown: TimeInterval) -> CanvasSessionRenewer.Outcome? {
            CanvasSessionRenewer.gate(
                now: now, lastAttempt: t0, inFlight: false,
                paneActive: false, isTestRunner: false, cooldown: cooldown
            )
        }
        #expect(gate(cooldown: CanvasSessionRenewer.cooldown) != nil)
        #expect(gate(cooldown: CanvasSessionRenewer.foregroundSpacing) == nil)
    }

    @Test("refreshCredentialSubmissionClock takes the later clock and never rewinds")
    func refreshCredentialClock() {
        let renewer = CanvasSessionRenewer(isLoginPaneActive: { false })
        renewer.refreshCredentialSubmissionClock(nil)
        #expect(renewer.lastCredentialSubmissionAt == nil)

        renewer.refreshCredentialSubmissionClock(t0)
        #expect(renewer.lastCredentialSubmissionAt == t0)

        let later = t0.addingTimeInterval(3600)
        renewer.refreshCredentialSubmissionClock(later)
        #expect(renewer.lastCredentialSubmissionAt == later)

        renewer.refreshCredentialSubmissionClock(t0)
        #expect(renewer.lastCredentialSubmissionAt == later)
        renewer.refreshCredentialSubmissionClock(nil)
        #expect(renewer.lastCredentialSubmissionAt == later)
    }

    @Test("the renewer keeps separate foreground and background cooldown clocks")
    func renewerSeparateSlots() {
        let fg = t0
        let bg = t0.addingTimeInterval(600)
        let renewer = CanvasSessionRenewer(
            isLoginPaneActive: { false }, lastAttemptAt: fg, lastBackgroundAttemptAt: bg
        )
        #expect(renewer.attemptClock(isBackground: false) == fg)
        #expect(renewer.attemptClock(isBackground: true) == bg)

        // A background timestamp alone never gates a foreground attempt.
        let bgOnly = CanvasSessionRenewer(isLoginPaneActive: { false }, lastBackgroundAttemptAt: bg)
        let now = bg.addingTimeInterval(60)
        func gate(_ r: CanvasSessionRenewer, background: Bool) -> CanvasSessionRenewer.Outcome? {
            CanvasSessionRenewer.gate(
                now: now, lastAttempt: r.attemptClock(isBackground: background), inFlight: false,
                paneActive: false, isTestRunner: false, cooldown: CanvasSessionRenewer.cooldown
            )
        }
        #expect(gate(bgOnly, background: false) == nil)
        #expect(gate(bgOnly, background: true) != nil)

        // A foreground timestamp still gates foreground, and not background.
        let fgOnly = CanvasSessionRenewer(isLoginPaneActive: { false }, lastAttemptAt: bg)
        #expect(gate(fgOnly, background: false) != nil)
        #expect(gate(fgOnly, background: true) == nil)
    }

    @Test("a background attempt records only the background slot; the foreground inputs stay untouched")
    func backgroundRecordLeavesForegroundSlot() {
        let state = makeState()
        state.renewalContext = .background
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        state.noteRenewalOutcomeForTesting(.timedOut)
        #expect(state.lastBackgroundSilentRenewalAttemptAt != nil)
        #expect(state.lastSilentRenewalAttemptAt == nil)
        #expect(state.lastSilentRenewalAttemptOutcome == nil)

        state.renewalContext = .foreground
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.lastSilentRenewalAttemptAt != nil)
        #expect(state.lastSilentRenewalAttemptOutcome == .landedOnLoginPage)
    }

    @Test("a background .timedOut never latches")
    func backgroundTimedOutIsUnknown() {
        #expect(AppState.confirmedDeadAfterRenewal(
            current: false, outcome: .timedOut, context: .background, priorConsecutiveLandings: 5
        ) == false)
    }

    @Test("abort with nothing in flight is a no-op, on the renewer and on AppState")
    func abortWithNothingInFlight() {
        let renewer = CanvasSessionRenewer(isLoginPaneActive: { false }, lastAttemptAt: t0)
        renewer.abort()
        renewer.abortForLoginPane()
        #expect(renewer.lastAttemptAt == t0)

        let state = makeState()
        state.abortSilentRenewal()
    }

    // MARK: - Duo stand-down, consecutive landings, background abort

    /// The renewal bookkeeping keys `AppState.init` reads back. Cleared before
    /// the state is built so a domain poisoned by a killed run, or by another
    /// suite, cannot seed a foreground stamp into a test about the background
    /// slot (the shared-`UserDefaults` trap in CLAUDE.md). The fix is on the
    /// polluting side: the state then runs with persistence off, so nothing
    /// here writes the shared domain.
    private static let renewalKeys = [
        "lastSilentRenewalAttemptAtV1", "lastSilentRenewalAttemptOutcomeV1",
        "lastBackgroundSilentRenewalAttemptAtV1", "lastSilentRenewalSummaryV1",
        "silentRenewalConsecutiveLandingsV1", "backgroundDuoStandDownV1",
        "autoLoginAwaitingDuoV1", "autoLoginAwaitingDuoSinceV1",
        "lastCredentialSubmissionAtV1", "lastFailedCredentialSubmissionAtV1",
    ]

    private func makeState() -> AppState {
        for key in Self.renewalKeys { UserDefaults.lhf.removeObject(forKey: key) }
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        state.forceCanvasCookieSessionExpiredForTesting(false)
        return state
    }

    @Test("Duo stand-down: set by needsDuo in the background, NOT lifted by a landing, lifted by a renewal")
    func standDownSetLandingKeepsRenewedLifts() {
        let state = makeState()
        state.renewalContext = .background
        state.noteRenewalOutcomeForTesting(.renewed)
        #expect(state.backgroundDuoStandDown == false)

        state.noteRenewalOutcomeForTesting(.needsDuo)
        #expect(state.backgroundDuoStandDown == true)

        // The GET-only landing overwrites the last outcome but not the flag.
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        // A background outcome no longer feeds the foreground retry policy.
        #expect(state.lastSilentRenewalAttemptOutcome == nil)
        #expect(state.backgroundDuoStandDown == true)
        state.noteRenewalOutcomeForTesting(.timedOut)
        #expect(state.backgroundDuoStandDown == true)

        state.noteRenewalOutcomeForTesting(.renewed)
        #expect(state.backgroundDuoStandDown == false)
    }

    @Test("Duo stand-down is lifted by a captured interactive login")
    func standDownLiftedByLogin() {
        let state = makeState()
        state.renewalContext = .background
        state.noteRenewalOutcomeForTesting(.needsDuo)
        #expect(state.backgroundDuoStandDown == true)

        state.noteCanvasLoginSessionCaptured()
        #expect(state.backgroundDuoStandDown == false)
    }

    @Test("a proven-alive event breaks the landing streak, so the next landing does not latch")
    func provenAliveBreaksLandingStreak() {
        let state = makeState()
        state.noteRenewalOutcomeForTesting(.renewed)
        #expect(state.silentRenewalConsecutiveLandings == 0)

        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.silentRenewalConsecutiveLandings == 1)
        #expect(state.canvasSessionExpired == false)

        // A token mint or a Grade Watcher fetch, days later.
        state.noteCanvasSessionProvenAliveForTesting()
        #expect(state.silentRenewalConsecutiveLandings == 0)
        #expect(state.lastSilentRenewalAttemptOutcome == nil)

        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.silentRenewalConsecutiveLandings == 1)
        #expect(state.canvasSessionExpired == false)
        // And the policy the count feeds: one prior landing latches, zero does not.
        #expect(AppState.confirmedDeadAfterRenewal(
            current: false, outcome: .landedOnLoginPage, context: .foreground,
            priorConsecutiveLandings: 0
        ) == false)
    }

    @Test("a proven-alive event does not lift the Duo stand-down")
    func provenAliveLeavesStandDown() {
        let state = makeState()
        state.renewalContext = .background
        state.noteRenewalOutcomeForTesting(.needsDuo)
        state.noteCanvasSessionProvenAliveForTesting()
        #expect(state.backgroundDuoStandDown == true)
        // Leave nothing set in memory: should an init-queued renewal ever
        // run on this instance afterwards, `recordSilentRenewal` would
        // persist the flag into the shared domain.
        state.noteCanvasLoginSessionCaptured()
        #expect(state.backgroundDuoStandDown == false)
    }

    @Test("a background abort (iOS cutting the wake off) does not overwrite the last real summary")
    func backgroundAbortKeepsSummary() {
        let state = makeState()
        state.renewalContext = .background
        state.noteRenewalOutcomeForTesting(.renewed)
        let before = state.lastSilentRenewalSummary
        #expect(before != nil)

        state.noteRenewalOutcomeForTesting(.abortedByLoginPane)
        #expect(state.lastSilentRenewalSummary == before)
        #expect(state.backgroundDuoStandDown == false)

        // A foreground abort (the login pane opening) still records itself.
        state.renewalContext = .foreground
        state.noteRenewalOutcomeForTesting(.abortedByLoginPane)
        #expect(state.lastSilentRenewalSummary?.hasPrefix("abortedByLoginPane") == true)
    }

    // MARK: - startSilentCanvasRenewal

    @Test("startSilentCanvasRenewal raises the in-flight flag and always lowers it, even when nothing runs")
    func inFlightFlagLifecycle() async {
        // Fixture data makes `performSilentCanvasRenewal` return `.notAttempted`
        // before touching the renewer, so this drives the real task plumbing
        // without WebKit. Forced per instance, never via `enterPreviewMode()`:
        // that persists `isPreviewMode` through the shared defaults every other
        // suite's `AppState.init` reads (the shared-defaults trap in CLAUDE.md).
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.forceFixtureDataForTesting(true)
        #expect(state.isUsingFixtureData)

        // `init` may itself have queued a renewal (a real expired cookie on
        // the machine running the tests); drain it so the next assertions
        // describe only the one started here.
        await state.awaitPendingSilentRenewal()
        #expect(state.isSilentRenewalInFlight == false)
        #expect(state.pendingSilentRenewal == nil)

        state.startSilentCanvasRenewal()
        #expect(state.isSilentRenewalInFlight == true)
        #expect(state.pendingSilentRenewal != nil)

        // A second start while one is pending is a no-op, not a second task.
        state.startSilentCanvasRenewal()
        #expect(state.isSilentRenewalInFlight == true)

        await state.awaitPendingSilentRenewal()
        #expect(state.isSilentRenewalInFlight == false)
        #expect(state.pendingSilentRenewal == nil)
    }
}


/// The 2026-11-05 review of the silent re-login path, items 12-15 and 17
/// (items 11 and 16 live in `CanvasSessionRenewerTests`). Every state here
/// calls `disablePersistenceForTesting()`, and the seams it reaches
/// (`seedFailedSubmissionClockForTesting`, `credentialSaveForTesting`,
/// `landingWasPositiveForTesting`) are per instance: nothing in this suite
/// writes or deletes a key in the shared `UserDefaults.lhf` domain, which
/// is the trap CLAUDE.md records (a concurrent suite's `AppState.init`
/// would read it).
@MainActor
@Suite("Silent re-login review fixes")
struct SilentReloginReviewTests {
    private func makeState() -> AppState {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.disablePersistenceForTesting()
        state.forceFixtureDataForTesting(false)
        return state
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Item 12

    @Test("a corrected password clears the failed-submission wait")
    func correctedPasswordClearsFailedWait() {
        let state = makeState()
        state.seedFailedSubmissionClockForTesting(t0)
        state.credentialSaveForTesting = { _, _ in true }
        #expect(state.enableStayLoggedIn(username: "student", password: "corrected"))
        #expect(state.failedCredentialSubmissionAt == nil)
    }

    @Test("a successful renewal clears the failed-submission wait, in the state and in the renewer")
    func renewedClearsFailedWait() {
        let state = makeState()
        state.seedFailedSubmissionClockForTesting(t0)
        let renewer = CanvasSessionRenewer(isLoginPaneActive: { false }, lastFailedCredentialSubmissionAt: t0)
        state.installSessionRenewerForTesting(renewer)
        state.noteRenewalOutcomeForTesting(.renewed)
        #expect(state.failedCredentialSubmissionAt == nil)
        #expect(renewer.lastFailedCredentialSubmissionAt == nil)
    }

    @Test("a failed outcome does not clear the wait")
    func failedOutcomeKeepsWait() {
        let state = makeState()
        state.seedFailedSubmissionClockForTesting(t0)
        state.noteRenewalOutcomeForTesting(.timedOut)
        #expect(state.failedCredentialSubmissionAt == t0)
    }

    @Test("disconnect's history reset clears the failed-submission wait")
    func disconnectClearsFailedWait() {
        let state = makeState()
        state.seedFailedSubmissionClockForTesting(t0)
        state.resetSilentRenewalHistoryForTesting()
        #expect(state.failedCredentialSubmissionAt == nil)
    }

    // MARK: - Item 13

    @Test("a dead probe keeps the flag up through recomputes while the cookies are fresh, until a renewal")
    func deadProbeSurvivesRecompute() async {
        let state = makeState()
        state.forceCanvasCookieSessionExpiredForTesting(true)
        state.setSessionProbeForTesting { _ in
            // Keeps the renewal the dead verdict starts from touching WebKit.
            state.forceFixtureDataForTesting(true)
            return CanvasSessionProbe.Result(verdict: .dead)
        }
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        await state.awaitPendingSilentRenewal()
        #expect(state.canvasSessionExpired)
        #expect(state.sessionProbeSaidDead)

        // The clock now reads fresh cookies (under 24 hours). Before the fix
        // the recompute set the flag straight back to false here.
        state.forceCanvasCookieSessionExpiredForTesting(false)
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired)
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired)

        // A retry is therefore due: the policy reads the expired flag.
        #expect(AppState.shouldRetrySilentRenewal(
            expired: state.canvasSessionExpired, awaitingDuo: false, disabledReason: nil,
            lastAttemptAt: nil, now: Date()))

        state.noteRenewalOutcomeForTesting(.renewed)
        #expect(!state.sessionProbeSaidDead)
        #expect(!state.canvasSessionExpired)
    }

    @Test("a new interactive login clears the dead verdict")
    func loginClearsDeadVerdict() async {
        let state = makeState()
        state.forceCanvasCookieSessionExpiredForTesting(true)
        state.setSessionProbeForTesting { _ in
            state.forceFixtureDataForTesting(true)
            return CanvasSessionProbe.Result(verdict: .dead)
        }
        state.refreshCanvasSessionExpiredState()
        await state.awaitPendingSessionProbe()
        await state.awaitPendingSilentRenewal()
        #expect(state.sessionProbeSaidDead)
        state.invalidateSessionProbeForTesting()
        #expect(!state.sessionProbeSaidDead)
    }

    // MARK: - Item 14

    @Test("retiring the renewer aborts its running attempt and moves to a new generation")
    func retireAbortsAndBumpsGeneration() {
        let state = makeState()
        let renewer = CanvasSessionRenewer(isLoginPaneActive: { false })
        state.installSessionRenewerForTesting(renewer)
        let serial = renewer.beginAttemptForTesting()
        #expect(renewer.attemptIsNotAborted(serial))
        let generation = state.canvasAccountGeneration

        state.retireCanvasSessionRenewerForTesting()

        // The attempt's continuations (cookie merge) now refuse to run.
        #expect(!renewer.attemptIsNotAborted(serial))
        #expect(!renewer.attemptIsLive(serial))
        #expect(state.canvasAccountGeneration == generation + 1)
        renewer.endAttemptForTesting()
    }

    @Test("a result from an earlier account generation is stale")
    func staleGeneration() {
        #expect(AppState.renewalResultIsStale(startedGeneration: 3, currentGeneration: 4))
        #expect(!AppState.renewalResultIsStale(startedGeneration: 4, currentGeneration: 4))
    }

    // MARK: - Item 15

    private func credentiallessState() -> AppState {
        let state = makeState()
        state.silentRenewalHasCredentialForTesting = false
        state.forceCanvasCookieSessionExpiredForTesting(true)
        state.refreshCanvasSessionExpiredState()
        return state
    }

    @Test("one or two positive credential-less landings do not latch; the third does and shows the sign-in row")
    func threePositiveLandingsLatch() {
        let state = credentiallessState()
        #expect(state.canvasSessionExpired)
        state.landingWasPositiveForTesting = true

        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(!state.silentRenewalCannotProceed)
        #expect(state.canvasSessionStatusLine() == .none)
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(!state.silentRenewalCannotProceed)

        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.silentRenewalCannotProceed)
        #expect(state.canvasSessionStatusLine() == .signInNeeded)

        // No further silent attempt starts, from any trigger.
        let generation = state.silentRenewalGeneration
        state.startSilentCanvasRenewal()
        state.retrySilentRenewalIfDue(now: Date().addingTimeInterval(3600))
        #expect(state.silentRenewalGeneration == generation)

        // A successful renewal lifts it and restarts the count.
        state.noteRenewalOutcomeForTesting(.renewed)
        #expect(!state.silentRenewalCannotProceed)
        #expect(state.credentiallessLandings == 0)
    }

    @Test("a network-failure landing in between neither counts nor resets the streak")
    func networkFailureDoesNotCount() {
        let state = credentiallessState()
        state.landingWasPositiveForTesting = true
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.credentiallessLandings == 2)

        // A landing that came from a failed navigation.
        state.landingWasPositiveForTesting = false
        for _ in 0..<5 { state.noteRenewalOutcomeForTesting(.landedOnLoginPage) }
        #expect(state.credentiallessLandings == 2)
        #expect(!state.silentRenewalCannotProceed)

        // The next positive one is the third, not the first.
        state.landingWasPositiveForTesting = true
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.silentRenewalCannotProceed)
    }

    @Test("with a credential a landing keeps retrying and shows nothing")
    func credentialLandingKeepsTrying() {
        let state = makeState()
        state.silentRenewalHasCredentialForTesting = true
        state.landingWasPositiveForTesting = true
        state.forceCanvasCookieSessionExpiredForTesting(true)
        state.refreshCanvasSessionExpiredState()
        for _ in 0..<4 { state.noteRenewalOutcomeForTesting(.landedOnLoginPage) }
        #expect(!state.silentRenewalCannotProceed)
        #expect(state.canvasSessionStatusLine() == .none)
    }

    @Test("a background landing never counts")
    func backgroundLandingDoesNotLatch() {
        let state = makeState()
        state.silentRenewalHasCredentialForTesting = false
        state.landingWasPositiveForTesting = true
        state.renewalContext = .background
        for _ in 0..<4 { state.noteRenewalOutcomeForTesting(.landedOnLoginPage) }
        #expect(!state.silentRenewalCannotProceed)
    }

    @Test("a renewer's landing from a failed navigation is not positive")
    func renewerLandingFlagDefaultsFalse() {
        #expect(CanvasSessionRenewer(isLoginPaneActive: { false }).lastLandingWasPositive == false)
    }

    // MARK: - Item 17

    @Test("a Keychain save failure has its own status and does not reject the password or stop renewal")
    func saveFailureIsNotRejection() {
        let state = makeState()
        state.credentialSaveForTesting = { _, _ in false }
        #expect(state.enableStayLoggedIn(username: "student", password: "pw") == false)
        #expect(state.autoLoginDisabledReason == nil)
        #expect(state.credentialSaveFailed)
        #expect(state.canvasSessionStatusLine() == .couldntSavePassword)

        // A later successful save clears it.
        state.credentialSaveForTesting = { _, _ in true }
        #expect(state.enableStayLoggedIn(username: "student", password: "pw"))
        #expect(!state.credentialSaveFailed)
        #expect(state.canvasSessionStatusLine() == .none)
    }

    @Test("status line priority: a rejected password outranks a failed save")
    func saveFailedPriority() {
        typealias L = AppState.CanvasSessionStatusLine
        func line(rejected: Bool, saveFailed: Bool) -> L {
            AppState.canvasSessionStatusLine(
                renewalInFlight: false, inFlightFor: 0, duoPushSent: false, awaitingDuo: false,
                passwordRejected: rejected, loginMissing: false, hasSavedCredentials: true,
                saveFailed: saveFailed)
        }
        #expect(line(rejected: false, saveFailed: true) == .couldntSavePassword)
        #expect(line(rejected: true, saveFailed: true) == .passwordChanged)
        #expect(line(rejected: false, saveFailed: false) == .none)
    }
}
