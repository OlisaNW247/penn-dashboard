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

    /// The gap persisted pairings close. The similar-title tier requires both
    /// due dates within ~26h; when a professor pushes the deadline on Canvas
    /// only, that test starts failing and a pair the student has been treating
    /// as one assignment splits into two cards — with their completion tick
    /// stranded on one half.
    @Test("a confirmed pair stays merged after a due date moves on one platform")
    func confirmedPairSurvivesDateMove() throws {
        let store = try AssignmentStore(inMemory: true)
        let course = "SCEN-G 100"
        let due = Date().addingTimeInterval(4 * 86_400)

        // Titles are similar but NOT identical, so this pair lives entirely on
        // the date-gated tier.
        let canvasItem = canvas("g1", course: course, title: "Homework 3 (Written)", due: due)
        let gradescopeItem = Assignment(source: .gradescope, sourceID: "g9", kind: .assignment,
                                        course: course, title: "Written Homework 3",
                                        dueAt: due, url: nil)
        _ = store.reconcile([canvasItem], source: .canvas)
        _ = store.reconcile([gradescopeItem], source: .gradescope)

        let state = AppState(assignmentStore: store)
        state.markActive(canvasItem)   // clean slate
        #expect(state.assignments.filter { $0.course == course }.count == 1)

        // The professor pushes the Canvas deadline a week; Gradescope keeps the
        // original. The live heuristic can no longer see these as a pair.
        let moved = canvas("g1", course: course, title: "Homework 3 (Written)",
                           due: due.addingTimeInterval(7 * 86_400))
        #expect(!AssignmentDeduplicator.isLikelyDuplicate(
            titleA: moved.title, dueA: moved.dueAt,
            titleB: gradescopeItem.title, dueB: gradescopeItem.dueAt
        ), "precondition: the heuristic alone would now split this pair")

        _ = store.reconcile([moved], source: .canvas)
        let after = AppState(assignmentStore: store)
        // `mergedCoursework`, not `assignments`: pushing the date a week moves
        // the item out of the dashboard's "this week" bucket, which is a
        // separate concern from whether the pair is still merged.
        let matches = after.mergedCoursework.filter { $0.course == course }
        #expect(matches.count == 1, "the stored pairing should hold the merge together")
        #expect(matches.first?.linkedID == "gradescope:g9")

        after.markActive(moved)   // cleanup
    }

    // MARK: The real-world case — a term's finished coursework, months later

    /// The scenario this branch exists for, end to end: a completed homework and
    /// a graded midterm from earlier in the term, long past due and long gone
    /// from the rolling Canvas feed, on a launch where the Canvas session has
    /// lapsed so no grade refresh can run.
    ///
    /// Before the ledger this lost everything: the pools started empty, the
    /// feed no longer carried the items, and submission state was recomputed
    /// per-launch from a fetch that couldn't happen. All three had to be fixed
    /// for this to hold.
    @Test("a term's completed coursework survives aging, a rolling feed, and a dead session")
    func completedTermCourseworkSurvivesEverything() throws {
        let (store1, url) = try tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let course = "SCEN-F 3200"

        // Earlier in the term: a homework and a midterm, both now 45 days past
        // due — well beyond the 14-day gone-grace window.
        let longAgo = Date().addingTimeInterval(-45 * 86_400)
        let hw = canvas("43001", course: course, title: "Homework 4", due: longAgo)
        let midterm = canvas("43002", course: course, title: "Midterm", due: longAgo)
        let current = canvas("43003", course: course, title: "Homework 9",
                             due: Date().addingTimeInterval(3 * 86_400))
        _ = store1.reconcile([hw, midterm, current], source: .canvas)

        // A grade refresh back when the session was alive: Canvas reported both
        // submitted and scored.
        let live = AppState(assignmentStore: store1)
        live.markActive(hw)          // clean slate in shared UserDefaults
        live.markActive(midterm)
        live.gradeWatcher.loadPreviewSnapshots([
            "1": snapshot(courseID: "1", graded: [("43001", 92, 100), ("43002", 78, 100)])
        ])
        live.updateSubmissionState()
        #expect(live.isCompleted(hw))
        #expect(live.isCompleted(midterm))

        // Weeks pass. Both roll off the rolling Canvas feed; only current work
        // is still published.
        _ = store1.reconcile([current], source: .canvas)

        // Relaunch — and this time the Canvas session is dead, so Grade Watcher
        // never runs and the submission side-channel is empty.
        let store2 = try AssignmentStore(url: url)
        let relaunched = AppState(assignmentStore: store2)

        let ids = Set(relaunched.canvasItems.map(\.id))
        #expect(ids.isSuperset(of: ["canvas:43001", "canvas:43002"]),
                "finished work must not age out of the ledger")

        // Still known-submitted with its scores, from the ledger alone.
        #expect(relaunched.submittedCanvasAssignmentIDs.isSuperset(of: ["43001", "43002"]))
        let storedHW = try #require(relaunched.canvasItems.first { $0.id == "canvas:43001" })
        #expect(storedHW.scoreEarned == 92)
        #expect(storedHW.scoreMax == 100)
        #expect(relaunched.isCompleted(storedHW), "it should still be filed under Done, not back on the active list")

        // And it is genuinely off the active dashboard, not just present.
        #expect(!relaunched.assignments.contains { $0.id == "canvas:43001" })
        #expect(relaunched.mergedCoursework.contains { $0.id == "canvas:43002" })
    }

    /// Builds a Grade Watcher snapshot for `graded` = (canvas assignment id,
    /// earned, possible), with a matching submitted `workflow_state` for each —
    /// the shape a real `CanvasGradesClient.fetchSnapshot` returns.
    private func snapshot(
        courseID: String,
        graded: [(id: String, earned: Double, possible: Double)]
    ) -> CourseGradeSnapshot {
        CourseGradeSnapshot(
            courseID: courseID,
            courseUsesWeights: false,
            categories: [GradeCategory(
                id: "g1",
                name: "Assignments",
                weight: nil,
                dropLowest: 0,
                dropHighest: 0,
                neverDropIDs: [],
                items: graded.map {
                    GradeItem(id: $0.id, name: $0.id, pointsPossible: $0.possible,
                              score: $0.earned, scoreSource: .canvas,
                              isExcused: false, omitFromFinalGrade: false, dueAt: nil)
                }
            )],
            canvasComputedCurrentScore: nil,
            submissions: graded.map {
                AssignmentSubmissionInfo(assignmentID: $0.id, workflowState: .graded,
                                         submittedAt: Date().addingTimeInterval(-46 * 86_400),
                                         isMissing: false, isLate: false)
            },
            fetchedAt: Date()
        )
    }
}
