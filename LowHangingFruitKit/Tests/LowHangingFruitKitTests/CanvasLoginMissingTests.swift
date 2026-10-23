import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The "Canvas login is gone" rule: when the saved Canvas cookies are removed
/// entirely after a login (Grade Watcher's rejected fetch does it, so does the
/// DEBUG "simulate canvas logout"), `canvasSessionExpired` must still go true
/// so the refresh banner shows and the renew-on-open path uses the saved
/// PennKey password. `SessionCookieStore.isExpired` cannot do it: it reads
/// `false` for a deleted item, the same as for a pasted-calendar-link install
/// that never had a session.
///
/// Every instance test drives the rule through per-instance seams
/// (`forceCanvasLoginHistoryForTesting`, `forceCanvasLoginMissingInputsForTesting`,
/// `forceCanvasCookieSessionExpiredForTesting`, `forceFixtureDataForTesting`)
/// and never writes the shared Keychain or `UserDefaults.lhf`, for the reason
/// `forceCanvasSessionConfirmedDeadForTesting()` records: a flag written to a
/// process-wide domain is read by every `AppState.init` in every suite running
/// alongside. The one exception is the disconnect test, which calls the real
/// `disconnectCanvas()` as four other suites already do; its clearing is of
/// Keychain items, never a write of the new flag (the persisted write is
/// skipped under the test runner).
@MainActor
@Suite("Canvas login missing", .serialized)
struct CanvasLoginMissingTests {

    /// An instance whose aged-cookie half and fixture state are pinned, so the
    /// only thing that can move `canvasSessionExpired` is the rule under test
    /// (and a confirmed-dead record, which these tests never set).
    private func makeState(
        capturedBefore: Bool,
        stored: Bool? = nil,
        legacyEvidence: Bool = false,
        isCanvasConnected: Bool,
        hasSavedCookies: Bool
    ) -> AppState {
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.forceFixtureDataForTesting(false)
        state.forceCanvasCookieSessionExpiredForTesting(false)
        state.forceCanvasLoginHistoryForTesting(
            stored: capturedBefore ? true : stored,
            legacyEvidence: legacyEvidence
        )
        state.forceCanvasLoginMissingInputsForTesting(
            isCanvasConnected: isCanvasConnected,
            hasSavedCookies: hasSavedCookies
        )
        return state
    }

    // MARK: - The pure rule

    @Test("the login is missing only when connected, not preview, logged in before, and nothing is saved")
    func pureRuleTruthTable() {
        #expect(AppState.isCanvasLoginMissing(
            isCanvasConnected: true, isUsingFixtureData: false, everCaptured: true, hasSavedCookies: false
        ) == true)

        // Each condition flipped on its own.
        #expect(AppState.isCanvasLoginMissing(
            isCanvasConnected: false, isUsingFixtureData: false, everCaptured: true, hasSavedCookies: false
        ) == false)
        #expect(AppState.isCanvasLoginMissing(
            isCanvasConnected: true, isUsingFixtureData: true, everCaptured: true, hasSavedCookies: false
        ) == false)
        #expect(AppState.isCanvasLoginMissing(
            isCanvasConnected: true, isUsingFixtureData: false, everCaptured: false, hasSavedCookies: false
        ) == false)
        #expect(AppState.isCanvasLoginMissing(
            isCanvasConnected: true, isUsingFixtureData: false, everCaptured: true, hasSavedCookies: true
        ) == false)
    }

    @Test("a stored value wins over the legacy evidence, in both directions, without asking for it")
    func storedValueWinsAndSkipsEvidence() {
        var asked = false
        #expect(AppState.resolveCanvasLoginEverCaptured(stored: true) { asked = true; return false } == true)
        #expect(AppState.resolveCanvasLoginEverCaptured(stored: false) { asked = true; return true } == false)
        // The explicit false is what stops a disconnected install from being
        // resurrected by `hasOfferedStayLoggedIn`, which is never reset.
        #expect(asked == false)
    }

    @Test("with nothing stored, the legacy evidence decides")
    func legacyEvidenceDecidesWhenNothingStored() {
        #expect(AppState.resolveCanvasLoginEverCaptured(stored: nil) { true } == true)
        #expect(AppState.resolveCanvasLoginEverCaptured(stored: nil) { false } == false)
    }

    // MARK: - Cookies removed after a login

    @Test("cookies removed after a login: expired, the banner's condition holds, and a renewal is requested")
    func removedCookiesRaiseBannerAndRequestRenewal() async {
        let state = makeState(capturedBefore: true, isCanvasConnected: true, hasSavedCookies: true)
        // `init` may have queued a renewal of its own; drain it so what is
        // asserted below describes only the transition made here.
        await state.awaitPendingSilentRenewal()

        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == false)
        #expect(state.pendingSilentRenewal == nil)

        // What `GradeWatcherView.performRefresh` does on a rejected fetch.
        state.forceCanvasLoginMissingInputsForTesting(isCanvasConnected: true, hasSavedCookies: false)
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasSessionExpired == true)
        // The same false-to-true edge an aged cookie takes starts the same
        // renew-on-open task.
        #expect(state.pendingSilentRenewal != nil)
        #expect(state.isSilentRenewalInFlight == true)

        await state.awaitPendingSilentRenewal()
        // `ContentView` shows the banner when `canvasSessionExpired` is true
        // and no renewal is in flight. Under the test runner the renewal
        // itself is a no-op (`.notAttempted`), so the session is still gone
        // and the banner condition holds.
        #expect(state.isSilentRenewalInFlight == false)
        #expect(state.canvasSessionExpired == true)
    }

    @Test("a failed silent renewal leaves the banner up while the cookies stay gone")
    func failedRenewalKeepsBannerWhileCookiesStayGone() async {
        let state = makeState(capturedBefore: true, isCanvasConnected: true, hasSavedCookies: false)
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == true)

        // The two outcomes that do not touch the password or Duo latches
        // (those persist to the shared domain; their policy is covered
        // in `CanvasSessionDeadStateTests`).
        state.noteRenewalOutcomeForTesting(.landedOnLoginPage)
        #expect(state.canvasSessionExpired == true)
        state.noteRenewalOutcomeForTesting(.timedOut)
        #expect(state.canvasSessionExpired == true)
        await state.awaitPendingSilentRenewal()
    }

    // MARK: - Installs that must not be nagged

    @Test("a pasted-link install with no cookies is not expired")
    func pastedLinkInstallIsNotExpired() async {
        let state = makeState(
            capturedBefore: false, stored: nil, legacyEvidence: false,
            isCanvasConnected: true, hasSavedCookies: false
        )
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasLoginEverCaptured == false)
        #expect(state.canvasSessionExpired == false)
        #expect(state.pendingSilentRenewal == nil)
    }

    @Test("a fresh install before any login is not expired")
    func freshInstallIsNotExpired() async {
        let state = makeState(
            capturedBefore: false, stored: nil, legacyEvidence: false,
            isCanvasConnected: false, hasSavedCookies: false
        )
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasSessionExpired == false)
        #expect(state.pendingSilentRenewal == nil)
    }

    @Test("a logged-in-before install whose Canvas is not connected is not expired")
    func notConnectedIsNotExpired() async {
        let state = makeState(capturedBefore: true, isCanvasConnected: false, hasSavedCookies: false)
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasSessionExpired == false)
    }

    @Test("preview and fixture data never show the refresh banner")
    func fixtureDataIsNotExpired() async {
        let state = makeState(capturedBefore: true, isCanvasConnected: true, hasSavedCookies: false)
        state.forceFixtureDataForTesting(true)
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasSessionExpired == false)
        #expect(state.pendingSilentRenewal == nil)
    }

    // MARK: - Installs that predate the flag

    @Test("a legacy install with a saved password and no stored flag is expired when its cookies are gone")
    func legacyInstallWithPasswordIsExpired() async {
        // `stored: nil`: the key was never written by a build that predates it.
        let state = makeState(
            capturedBefore: false, stored: nil, legacyEvidence: true,
            isCanvasConnected: true, hasSavedCookies: false
        )
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasLoginEverCaptured == true)
        #expect(state.canvasSessionExpired == true)
        #expect(state.pendingSilentRenewal != nil)
        await state.awaitPendingSilentRenewal()
    }

    @Test("a legacy install with no evidence stays unflagged, so it is not expired")
    func legacyInstallWithoutEvidenceIsNotExpired() async {
        let state = makeState(
            capturedBefore: false, stored: nil, legacyEvidence: false,
            isCanvasConnected: true, hasSavedCookies: false
        )
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasLoginEverCaptured == false)
        #expect(state.canvasSessionExpired == false)
    }

    // MARK: - Setting and clearing the flag

    @Test("an interactive login captured sets the flag")
    func loginCaptureSetsFlag() async {
        let state = makeState(
            capturedBefore: false, stored: false,
            isCanvasConnected: true, hasSavedCookies: true
        )
        await state.awaitPendingSilentRenewal()
        #expect(state.canvasLoginEverCaptured == false)

        state.noteCanvasLoginSessionCaptured()
        #expect(state.canvasLoginEverCaptured == true)
        await state.awaitPendingSilentRenewal()
    }

    @Test("a renewal that re-saved the cookies sets the flag")
    func renewalSetsFlag() async {
        let state = makeState(
            capturedBefore: false, stored: false,
            isCanvasConnected: true, hasSavedCookies: true
        )
        await state.awaitPendingSilentRenewal()
        #expect(state.canvasLoginEverCaptured == false)

        state.noteRenewalOutcomeForTesting(.renewed)
        #expect(state.canvasLoginEverCaptured == true)
        await state.awaitPendingSilentRenewal()
    }

    @Test("disconnecting Canvas clears the flag, and the install is no longer expired")
    func disconnectClearsFlag() async {
        let state = makeState(capturedBefore: true, isCanvasConnected: true, hasSavedCookies: false)
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == true)
        await state.awaitPendingSilentRenewal()

        state.disconnectCanvas()

        #expect(state.canvasLoginEverCaptured == false)
        // The inputs are still pinned to "connected, nothing saved", so the
        // cleared flag is the only thing that can have taken the install out
        // of the expired state.
        #expect(state.canvasSessionExpired == false)
    }

    // MARK: - Re-saving cookies clears it

    @Test("a successful renewal that re-saves the cookies clears the expired state on its own")
    func renewalClearsExpiredState() async {
        let state = makeState(capturedBefore: true, isCanvasConnected: true, hasSavedCookies: false)
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == true)
        await state.awaitPendingSilentRenewal()

        // The renewer merges fresh cookies, then `applyRenewalOutcome` reports
        // `.renewed` and recomputes.
        state.forceCanvasLoginMissingInputsForTesting(isCanvasConnected: true, hasSavedCookies: true)
        state.noteRenewalOutcomeForTesting(.renewed)

        #expect(state.canvasSessionExpired == false)
        await state.awaitPendingSilentRenewal()
    }

    @Test("a manual login that re-saves the cookies clears the expired state on its own")
    func manualLoginClearsExpiredState() async {
        let state = makeState(capturedBefore: true, isCanvasConnected: true, hasSavedCookies: false)
        await state.awaitPendingSilentRenewal()
        state.refreshCanvasSessionExpiredState()
        #expect(state.canvasSessionExpired == true)
        await state.awaitPendingSilentRenewal()

        state.forceCanvasLoginMissingInputsForTesting(isCanvasConnected: true, hasSavedCookies: true)
        state.noteCanvasLoginSessionCaptured()

        #expect(state.canvasSessionExpired == false)
        await state.awaitPendingSilentRenewal()
    }
}
