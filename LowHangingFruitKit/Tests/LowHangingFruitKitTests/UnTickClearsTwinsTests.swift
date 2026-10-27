import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A dashboard card is often several ledger ids, and `carryCompletion` copies
/// a tick from a hidden id onto the card on every rebuild. Un-ticking only the
/// card was therefore undone by the rebuild that ends `markActive`: the hidden
/// twin still held the old completion and ticked the card again (hardening
/// plan B4, DAT-03). The fix clears the whole twin set and makes a carry fire
/// once per tick.
@MainActor
@Suite("Un-ticking clears the twins", .serialized)
struct UnTickClearsTwinsTests {
    /// Puts `UserDefaults.lhf` back after each test (see `LHFDefaultsGuard`).
    private let defaultsGuard = LHFDefaultsGuard()

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let course = "TWIN 7001"

    private let canvasRow = Assignment(
        source: .canvas, sourceID: "event-assignment-701", kind: .assignment, course: UnTickClearsTwinsTests.course,
        title: "Problem Set 1", dueAt: UnTickClearsTwinsTests.now.addingTimeInterval(3 * 86_400),
        url: URL(string: "https://canvas.upenn.edu/courses/7001/assignments/701")
    )
    /// The Modules page's copy of the same Canvas assignment: same Canvas
    /// assignment id in the URL, so the dashboard shows one card.
    private let moduleRow = Assignment(
        source: .canvasModules, sourceID: "module-701", kind: .assignment, course: UnTickClearsTwinsTests.course,
        title: "Problem Set 1", dueAt: UnTickClearsTwinsTests.now.addingTimeInterval(3 * 86_400),
        url: URL(string: "https://canvas.upenn.edu/courses/7001/assignments/701")
    )

    private func makeState() throws -> (AppState, AssignmentStore) {
        let store = try AssignmentStore(inMemory: true)
        store.upsert([canvasRow, moduleRow])
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.rebuildDashboardItemsForTesting(now: Self.now)
        return (state, store)
    }

    @Test("the two rows are one card, so the fixtures really are twins")
    func fixturesAreTwins() {
        #expect(canvasRow.canvasAssignmentID == "701")
        #expect(moduleRow.canvasAssignmentID == "701")
        let collapse = AssignmentDeduplicator.collapseCanvasDuplicates(canvasItems: [canvasRow], moduleItems: [moduleRow])
        #expect(collapse.collapses.map(\.moduleID) == [moduleRow.id])
        #expect(collapse.moduleItems.isEmpty)
    }

    @Test("complete, un-tick, rebuild: the card stays active and so does its hidden twin")
    func unTickSticks() throws {
        let (state, store) = try makeState()

        // The tick lands on the hidden copy (a Modules page tick, or an auto-file) and follows onto the card.
        state.markCompleted(moduleRow, at: Self.now)
        #expect(state.isCompleted(canvasRow), "the carry put the tick on the card")

        state.markActive(canvasRow)
        #expect(!state.isCompleted(canvasRow))
        #expect(!state.isCompleted(moduleRow), "the hidden twin was cleared with it")

        // The rebuild that used to bring it back, and several more.
        for _ in 0..<3 { state.rebuildDashboardItemsForTesting(now: Self.now) }
        #expect(!state.isCompleted(canvasRow))
        #expect(!state.completedAssignmentIDs.contains(moduleRow.id))
        #expect(store.completionRecord()?.ids.isEmpty == true)
    }

    @Test("ticking the card itself and un-ticking it round-trips, with the twin untouched")
    func plainRoundTrip() throws {
        let (state, store) = try makeState()
        state.markCompleted(canvasRow, at: Self.now)
        #expect(state.isCompleted(canvasRow))
        state.markActive(canvasRow)
        state.rebuildDashboardItemsForTesting(now: Self.now)
        #expect(!state.isCompleted(canvasRow))
        #expect(store.completionRecord()?.ids.isEmpty == true)
    }

    @Test("a carry fires once per tick: an un-tick that left the twin ticked is not undone by later rebuilds")
    func carryFiresOnce() throws {
        let (state, store) = try makeState()
        state.markCompleted(moduleRow, at: Self.now)
        #expect(state.isCompleted(canvasRow))

        // An un-tick that did not reach the hidden twin (a path that clears
        // one id), straight into the ledger.
        store.setCompleted(ids: [], at: nil, clearing: [canvasRow.id])
        state.reloadCompletionFromLedger()
        #expect(store.completionRecord()?.ids.contains(moduleRow.id) == true)
        for _ in 0..<3 { state.rebuildDashboardItemsForTesting(now: Self.now) }
        #expect(!state.completedAssignmentIDs.contains(canvasRow.id), "the same tick is not carried a second time")
    }

    @Test("a fresh tick on the hidden twin, with a new time, does follow onto the card")
    func freshTickCarriesAgain() throws {
        let (state, store) = try makeState()
        state.markCompleted(moduleRow, at: Self.now)
        state.markActive(canvasRow)
        #expect(!state.isCompleted(canvasRow))

        // The student ticks the Modules copy again, later.
        store.setCompleted(ids: [moduleRow.id], at: Self.now.addingTimeInterval(3_600), prototypes: [moduleRow])
        state.reloadCompletionFromLedger()
        state.rebuildDashboardItemsForTesting(now: Self.now)
        #expect(state.isCompleted(canvasRow))
    }

    // MARK: The pure rules

    @Test("the closure follows twins through more than one hop and survives a cycle")
    func closureRules() {
        #expect(CompletionTwins.closure(of: ["a"], twins: [:]) == ["a"])
        #expect(CompletionTwins.closure(of: ["a"], twins: ["a": ["b"]]) == ["a", "b"])
        #expect(CompletionTwins.closure(of: ["a"], twins: ["a": ["b"], "b": ["c"]]) == ["a", "b", "c"])
        #expect(CompletionTwins.closure(of: ["a"], twins: ["a": ["b"], "b": ["a"]]) == ["a", "b"])
        // A card's twins are not each other's: an unrelated pair stays out.
        #expect(CompletionTwins.closure(of: ["a"], twins: ["a": ["b"], "x": ["y"]]) == ["a", "b"])
        #expect(CompletionTwins.closure(of: ["a", "x"], twins: ["a": ["b"], "x": ["y"]]) == ["a", "b", "x", "y"])
    }

    @Test("a carry's key changes with the completion time, and is stable without one")
    func carryKeyRules() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CompletionTwins.carryKey(hiddenID: "h", survivorID: "s", completedAt: t)
            == CompletionTwins.carryKey(hiddenID: "h", survivorID: "s", completedAt: t))
        #expect(CompletionTwins.carryKey(hiddenID: "h", survivorID: "s", completedAt: t)
            != CompletionTwins.carryKey(hiddenID: "h", survivorID: "s", completedAt: t.addingTimeInterval(1)))
        #expect(CompletionTwins.carryKey(hiddenID: "h", survivorID: "s", completedAt: nil)
            == CompletionTwins.carryKey(hiddenID: "h", survivorID: "s", completedAt: nil))
        #expect(CompletionTwins.carryKey(hiddenID: "h", survivorID: "s", completedAt: t)
            != CompletionTwins.carryKey(hiddenID: "s", survivorID: "h", completedAt: t))
    }
}
