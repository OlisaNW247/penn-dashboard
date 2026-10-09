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

    @Test("a seeded attempt blocks the hour cooldown but not the shorter post-timeout one")
    func seededAttemptAndPerCallCooldown() {
        let now = t0.addingTimeInterval(15 * 60)
        func gate(cooldown: TimeInterval) -> CanvasSessionRenewer.Outcome? {
            CanvasSessionRenewer.gate(
                now: now, lastAttempt: t0, inFlight: false,
                paneActive: false, isTestRunner: false, cooldown: cooldown
            )
        }
        #expect(gate(cooldown: CanvasSessionRenewer.cooldown) != nil)
        #expect(gate(cooldown: AppState.timedOutRetryInterval) == nil)
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

    private func makeState() -> AppState {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
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
        #expect(state.lastSilentRenewalAttemptOutcome == .landedOnLoginPage)
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
