import Testing
import Foundation
import Combine
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The swipe saves first and animates after (hardening plan 2026-10-25, B10:
/// UCR-14, and the review that found the first version unwired).
///
/// The card's swipe used to reach the ledger only through `onComplete`, 0.38
/// seconds after the finger lifted. It now also calls `onCommit` the instant
/// the swipe is accepted, and the dashboard wires that to
/// `DashboardViewModel.commitCompletion` and `AppState.commitCompletion`: a
/// write that stops at the ledger, so the card is still on the list for its
/// exit animation, and the existing path that follows (`complete`, then
/// `markCompleted`) must find the write done.
///
/// SwiftUI gestures cannot run under the package test runner, so these drive
/// the two closures the card is handed, in the order the card calls them:
/// `vm.commitCompletion(card)` at once, `vm.complete(card)` after the delay.
/// What is asserted is what the swipe has done to the store at each point.
struct SwipeCommitTests {

    private static let course = "SWIPE 100"

    private struct Fixture {
        let store: AssignmentStore
        let state: AppState
        let vm: DashboardViewModel
        let card: DashItem
        let log: SyncChangeLog
        let logSuite: String
    }

    @MainActor
    private func fixture(linkedID: String? = nil) throws -> Fixture {
        let store = try AssignmentStore(inMemory: true)
        let due = Date().addingTimeInterval(2 * 86_400)
        let item = Assignment(source: .canvas, sourceID: "swipe-1", kind: .assignment,
                              course: Self.course, title: "Problem set", dueAt: due,
                              url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/1"),
                              linkedID: linkedID)
        _ = store.reconcile([item], source: .canvas)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        let logSuite = "lhf.swipe-commit.\(UUID().uuidString)"
        let log = SyncChangeLog(defaults: UserDefaults(suiteName: logSuite)!)
        state.syncChangeLog = log
        state.canvasItems = store.currentAssignments()
        state.rebuildDashboardItemsForTesting(now: Date())
        let vm = DashboardViewModel()
        vm.bind(to: state)
        let card = try #require(vm.items.first { $0.id == "canvas:swipe-1" },
                                "the fixture's card is not on the dashboard")
        return Fixture(store: store, state: state, vm: vm, card: card, log: log, logSuite: logSuite)
    }

    private func tearDown(_ f: Fixture) {
        UserDefaults(suiteName: f.logSuite)?.removePersistentDomain(forName: f.logSuite)
    }

    @MainActor
    @Test("the instant a swipe is accepted the completion is in the store, and the card is still on the list")
    func commitWritesAtOnceAndLeavesTheCard() throws {
        let f = try fixture()
        defer { tearDown(f) }
        var published = 0
        let subscription = f.state.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        f.vm.commitCompletion(f.card)

        #expect(f.store.completionRecordOrFail().ids == ["canvas:swipe-1"], "recorded before any delay")
        #expect(f.log.time(kind: .completion, id: "canvas:swipe-1") != nil, "and in the sync log")
        // Nothing on screen has changed: a publish would reload the dashboard
        // and take the card, with its exit animation, off the list.
        #expect(published == 0)
        #expect(f.vm.items.first { $0.id == f.card.id }?.isCompleted == false)
        #expect(!f.state.completedAssignmentIDs.contains(f.card.id))
    }

    @MainActor
    @Test("the completion that follows the animation finds the write done: no second write, no second change record")
    func completeAfterwardsDoesNotWriteAgain() throws {
        let f = try fixture()
        defer { tearDown(f) }

        f.vm.commitCompletion(f.card)
        let writtenAt = try #require(f.store.completionRecordOrFail().dates[f.card.id])
        let loggedAt = try #require(f.log.time(kind: .completion, id: f.card.id))

        // After the exit animation: what the card's `onComplete` runs.
        f.vm.complete(f.card)

        #expect(f.vm.items.first { $0.id == f.card.id }?.isCompleted == true, "the card leaves")
        #expect(f.state.completedAssignmentIDs.contains(f.card.id), "and the dashboard knows")
        #expect(f.store.completionRecordOrFail().dates[f.card.id] == writtenAt,
                "the timestamp is the swipe's, not the moment the animation ended")
        #expect(f.log.time(kind: .completion, id: f.card.id) == loggedAt, "recorded once")
    }

    @MainActor
    @Test("without the commit the completion still works exactly as before")
    func completeAloneStillWrites() throws {
        let f = try fixture()
        defer { tearDown(f) }

        f.vm.complete(f.card)

        #expect(f.store.completionRecordOrFail().ids == ["canvas:swipe-1"])
        #expect(f.log.time(kind: .completion, id: f.card.id) != nil)
        #expect(f.state.completedAssignmentIDs.contains(f.card.id))
    }

    @MainActor
    @Test("a commit whose save failed leaves the full write to the completion that follows")
    func failedCommitFallsBackToTheFullPath() throws {
        let f = try fixture()
        defer { tearDown(f) }

        f.store.saveFailureForTesting = NSError(domain: "test", code: 1)
        f.vm.commitCompletion(f.card)
        #expect(f.log.time(kind: .completion, id: f.card.id) == nil, "nothing is claimed that was not written")

        f.store.saveFailureForTesting = nil
        f.vm.complete(f.card)
        #expect(f.store.completionRecordOrFail().ids.contains(f.card.id))
        #expect(f.log.time(kind: .completion, id: f.card.id) != nil)
    }

    @MainActor
    @Test("a commit the ledger no longer confirms is written in full by the completion that follows")
    func staleCommitIsNotTrusted() throws {
        let f = try fixture()
        defer { tearDown(f) }

        f.vm.commitCompletion(f.card)
        // Cleared by some other path before the animation ended.
        f.store.setCompleted(ids: [], at: nil, clearing: [f.card.id])
        #expect(f.store.completionRecordOrFail().ids.isEmpty)

        f.vm.complete(f.card)
        #expect(f.store.completionRecordOrFail().ids == [f.card.id], "the tick is not lost to a stale mark")
    }

    @MainActor
    @Test("an un-tick forgets a pending commit")
    func uncompleteForgetsTheCommit() throws {
        let f = try fixture()
        defer { tearDown(f) }

        f.vm.commitCompletion(f.card)
        f.vm.uncomplete(f.card)
        #expect(f.store.completionRecordOrFail().ids.isEmpty)

        f.vm.complete(f.card)
        #expect(f.store.completionRecordOrFail().ids == [f.card.id], "a later swipe writes normally")
    }

    @MainActor
    @Test("a merged Canvas and Gradescope item commits both identities")
    func mergedItemCommitsBothIDs() throws {
        let f = try fixture(linkedID: "gradescope:swipe-gs")
        defer { tearDown(f) }

        f.vm.commitCompletion(f.card)
        #expect(f.store.completionRecordOrFail().ids == ["canvas:swipe-1", "gradescope:swipe-gs"])
    }

    @MainActor
    @Test("preview and sample data write nothing")
    func sampleDataWritesNothing() throws {
        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        let vm = DashboardViewModel()
        vm.bind(to: state)
        vm.loadSampleData()
        let card = try #require(vm.items.first)

        vm.commitCompletion(card)
        #expect(store.completionRecordOrFail().ids.isEmpty)
        #expect(store.rowCount() == 0)
    }

    // MARK: The wiring that cannot run here

    /// The card's gesture and the SwiftUI closures that connect it cannot run
    /// under the package test runner, so this is the one source scan left, and
    /// it is a complement to the tests above, not a substitute: it only checks
    /// the hand-offs are still there, which is where the first version of this
    /// fix was wrong (an `onCommit` nothing passed).
    @Test("the dashboard passes the commit from the view model to the card")
    func dashboardWiringIsPresent() throws {
        let root = URL(fileURLWithPath: #filePath)   // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func flat(_ name: String) throws -> String {
            let url = root.appendingPathComponent("Sources/LowHangingFruitUI/\(name)")
            try #require(FileManager.default.fileExists(atPath: url.path),
                         "\(url.path) is not there, so nothing could be checked")
            return try String(contentsOf: url, encoding: .utf8)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        #expect(try flat("ContentView.swift").contains("onCommit: { item in vm.commitCompletion(item) }"))
        #expect(try flat("TimelineSectionView.swift").contains("onCommit: { onCommit(item) },"))
        #expect(try flat("DashboardViewModel.swift").contains("appState?.commitCompletion(item.assignment)"))

        // And the card calls it first, ahead of the animation.
        let card = try flat("AssignmentCardView.swift")
        let guardAt = try #require(card.range(of: "guard !isCompleting else { return } isCompleting = true"))
        let commitAt = try #require(card.range(of: "onCommit()", range: guardAt.upperBound..<card.endIndex))
        let animateAt = try #require(card.range(of: "withAnimation(", range: guardAt.upperBound..<card.endIndex))
        #expect(commitAt.lowerBound < animateAt.lowerBound)
    }
}
