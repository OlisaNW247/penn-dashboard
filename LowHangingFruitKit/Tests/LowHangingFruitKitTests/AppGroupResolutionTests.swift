import Foundation
import Testing
@testable import LowHangingFruitKit

/// Which App Group container the process opens. On iOS there has only ever been
/// one answer; the Mac App Store build introduced a second, because a sandboxed
/// macOS app group must carry the team-id prefix.
///
/// Getting this wrong is not a visible failure: `containerURL` returns nil, the
/// ledger falls back to memory, and the app looks perfectly normal until a
/// relaunch loses the student's work.
@Suite("App Group resolution")
struct AppGroupResolutionTests {

    @Test("a sandboxed Mac process takes the team-prefixed container")
    func sandboxedTakesPrefixed() {
        let id = WidgetSharing.resolveAppGroupID(
            isTestRunner: false,
            isSandboxed: true,
            prefixedContainerResolves: { true }
        )
        #expect(id == WidgetSharing.teamPrefixedAppGroupID)
    }

    /// The probe succeeding is the *realistic* unsandboxed case — macOS resolves
    /// a container for practically any group id when there's no sandbox — so
    /// this is the test that keeps the dev build on the ledger it already has.
    @Test("an unsandboxed build stays on the bare id even when the probe succeeds")
    func unsandboxedStaysBare() {
        let id = WidgetSharing.resolveAppGroupID(
            isTestRunner: false,
            isSandboxed: false,
            prefixedContainerResolves: { true }
        )
        #expect(id == WidgetSharing.bareAppGroupID)
    }

    @Test("a test runner never reaches the prefixed container")
    func testRunnerStaysBare() {
        let id = WidgetSharing.resolveAppGroupID(
            isTestRunner: true,
            isSandboxed: true,
            prefixedContainerResolves: { true }
        )
        #expect(id == WidgetSharing.bareAppGroupID)
    }

    @Test("a sandboxed process with no prefixed container falls back rather than inventing one")
    func sandboxedWithoutContainerFallsBack() {
        let id = WidgetSharing.resolveAppGroupID(
            isTestRunner: false,
            isSandboxed: true,
            prefixedContainerResolves: { false }
        )
        #expect(id == WidgetSharing.bareAppGroupID)
    }

    @Test("the ledger and the shared defaults agree on the id this process resolved")
    @MainActor
    func oneAnswerPerProcess() {
        #expect(WidgetSharing.appGroupID == WidgetSharing.bareAppGroupID)
        #expect(AssignmentStore.appGroupID == WidgetSharing.appGroupID)
        #expect(SharedDefaults.appGroupID == WidgetSharing.appGroupID)
    }
}
