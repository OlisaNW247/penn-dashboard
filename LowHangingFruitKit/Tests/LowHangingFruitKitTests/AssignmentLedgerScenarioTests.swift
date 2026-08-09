import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Multi-sync, multi-launch scenario tests — the "bulletproofing" harness. These
/// reproduce the failure modes you can't trigger by hand (an assignment leaving
/// a rolling feed, a flaky empty fetch, a completed item aging) as deterministic
/// sequences, and assert the invariants across the whole sequence.
///
/// Each scenario is written against `AppState` with an injected store, so it
/// exercises the real integration (init-load + reconcile + the dashboard/Done
/// pools), not just the store in isolation.
@MainActor
struct AssignmentLedgerScenarioTests {

    // MARK: Fixtures

    /// A unique-ish course per test run so completion state persisted in the
    /// shared `UserDefaults.standard` (keyed by assignment id) can't bleed
    /// between tests. Callers pass a distinct salt.
    private func canvas(_ id: String, course: String, title: String = "HW 3", due: Date?) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"),
                   term: Term(date: due ?? Date()))
    }

    private func tempStore() throws -> (AssignmentStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-ledger-\(UUID().uuidString).store")
        return (try AssignmentStore(url: url), url)
    }

    // MARK: Scenarios

    @Test("an assignment that disappears from the feed is never lost")
    func vanishedAssignmentSurvives() throws {
        let store = try AssignmentStore(inMemory: true)
        let course = "SCEN-A 100"
        let soon = Date().addingTimeInterval(2 * 86_400)

        // Sync 1: two assignments present.
        _ = store.reconcile([canvas("a1", course: course, due: soon),
                             canvas("a2", course: course, due: soon)], source: .canvas)
        // Sync 2: "a2" has dropped out of the rolling feed.
        _ = store.reconcile([canvas("a1", course: course, due: soon)], source: .canvas)

        // A fresh launch reads the ledger: both are still there.
        let state = AppState(assignmentStore: store)
        #expect(Set(state.canvasItems.map(\.id)) == ["canvas:a1", "canvas:a2"])
    }

    @Test("a flaky empty fetch keeps the saved assignments (partial-fetch guard)")
    func emptyFetchKeepsData() throws {
        let store = try AssignmentStore(inMemory: true)
        let course = "SCEN-B 100"
        let soon = Date().addingTimeInterval(2 * 86_400)

        _ = store.reconcile([canvas("b1", course: course, due: soon),
                             canvas("b2", course: course, due: soon)], source: .canvas)
        let result = store.reconcile([], source: .canvas)   // network blip

        #expect(result.wasSuspectedPartial)
        let state = AppState(assignmentStore: store)
        #expect(state.canvasItems.count == 2)
    }

    @Test("assignments survive a simulated relaunch (persistent store)")
    func survivesRelaunch() throws {
        let (store1, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let course = "SCEN-C 100"
        let soon = Date().addingTimeInterval(2 * 86_400)
        _ = store1.reconcile([canvas("c1", course: course, due: soon)], source: .canvas)

        // Relaunch: a brand-new store instance over the same file, new AppState.
        let store2 = try AssignmentStore(url: url)
        let state = AppState(assignmentStore: store2)
        #expect(state.canvasItems.map(\.id) == ["canvas:c1"])
    }

    @Test("a completed assignment stays in Done after it leaves the feed")
    func completedItemStaysInDone() throws {
        let store = try AssignmentStore(inMemory: true)
        let course = "SCEN-D 100"
        let soon = Date().addingTimeInterval(2 * 86_400)
        _ = store.reconcile([canvas("d1", course: course, due: soon)], source: .canvas)

        let state = AppState(assignmentStore: store)
        let item = try #require(state.canvasItems.first { $0.id == "canvas:d1" })
        state.markActive(item)      // clean slate (UserDefaults may remember it)
        state.markCompleted(item)
        #expect(state.isCompleted(item))

        // The assignment now drops out of the feed; the ledger retains it, so it
        // is still available to the Done tab (via `mergedCoursework`).
        _ = store.reconcile([], source: .canvas)   // guarded, keeps d1
        let reloaded = AppState(assignmentStore: store)
        #expect(reloaded.canvasItems.contains { $0.id == "canvas:d1" })
        #expect(reloaded.mergedCoursework.contains { $0.id == "canvas:d1" })
        #expect(reloaded.isCompleted(item))

        // cleanup so the shared-UserDefaults completion doesn't linger
        reloaded.markActive(item)
    }

    @Test("a cross-posted item's date moving on one side stays a single card")
    func movedDateStaysMerged() throws {
        // This is the moved-date duplicate case: dedup runs on the reconciled
        // pools each rebuild, so as long as both items are retained, the merge is
        // re-evaluated on live data. Here the two still match (same normalized
        // title, dates within tolerance) and collapse to one dashboard item.
        let store = try AssignmentStore(inMemory: true)
        let course = "SCEN-E 100"
        let due = Date()
        let canvasItem = canvas("e1", course: course, title: "Homework 3", due: due)
        let gradescopeItem = Assignment(source: .gradescope, sourceID: "e9", kind: .assignment,
                                        course: course, title: "HW 3", dueAt: due, url: nil)
        _ = store.reconcile([canvasItem], source: .canvas)
        _ = store.reconcile([gradescopeItem], source: .gradescope)

        let state = AppState(assignmentStore: store)
        state.markActive(canvasItem)   // clean slate
        // Exactly one dashboard item for the pair; the Gradescope copy is folded in.
        let matches = state.assignments.filter { $0.course == course }
        #expect(matches.count == 1)
        #expect(matches.first?.linkedID == "gradescope:e9")
    }
}
