import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for `AssignmentDeduplicator`: the pure title/due-date matching
/// heuristic, the course-scoped 1:1 pairing, and end-to-end merge/submission
/// propagation through `AppState`.
@Suite("Assignment deduplication")
struct AssignmentDeduplicatorTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func canvas(
        id: String = "c1",
        course: String = "CIS 1200",
        title: String,
        due: Date? = now,
        submitted: Bool = false
    ) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment, course: course,
                   title: title, dueAt: due, url: nil, submitted: submitted)
    }

    private static func gradescope(
        id: String = "g1",
        course: String = "CIS 1200",
        title: String,
        due: Date? = now,
        submitted: Bool = false
    ) -> Assignment {
        Assignment(source: .gradescope, sourceID: id, kind: .assignment, course: course,
                   title: title, dueAt: due, url: nil, submitted: submitted)
    }

    // MARK: - isLikelyDuplicate: positive cases

    @Test("HW 3 vs Homework 3 — exact normalized title match")
    func hwVsHomework() {
        #expect(AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "HW 3", dueA: Self.now,
            titleB: "Homework 3", dueB: Self.now
        ))
    }

    @Test("HW 3 vs Homework 3 still matches with no due dates at all")
    func hwVsHomeworkNoDates() {
        #expect(AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "HW 3", dueA: nil,
            titleB: "Homework 3", dueB: nil
        ))
    }

    @Test("PS1 vs Problem Set 1 (autograded) — similar title, due dates within 24h")
    func psVsProblemSetAutograded() {
        #expect(AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "PS1", dueA: Self.now,
            titleB: "Problem Set 1 (autograded)", dueB: Self.now.addingTimeInterval(3600)
        ))
    }

    @Test("Lab 2 vs Labs 02 — number equivalence, punctuation/case insensitive")
    func labNumberEquivalence() {
        #expect(AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "Lab 2", dueA: Self.now,
            titleB: "labs, 02!", dueB: Self.now
        ))
    }

    @Test("Project 1 vs Proj. 1 — project prefix collapse")
    func projectPrefixCollapse() {
        #expect(AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "Project 1", dueA: Self.now,
            titleB: "Proj. 1", dueB: Self.now
        ))
    }

    // MARK: - isLikelyDuplicate: negative cases

    @Test("HW 3 vs HW 4 — different assignment numbers never match")
    func differentNumbersNeverMatch() {
        #expect(!AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "HW 3", dueA: Self.now,
            titleB: "HW 4", dueB: Self.now
        ))
    }

    @Test("Midterm vs Final — unrelated assessment titles never match")
    func midtermVsFinal() {
        #expect(!AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "Midterm", dueA: Self.now,
            titleB: "Final", dueB: Self.now
        ))
    }

    @Test("similar-but-not-identical title with no due date on either side does not match")
    func similarTitleNoDueDateDoesNotMatch() {
        // "Midterm Review" vs "Midterm" is a tempting fuzzy match, but with no
        // due date to corroborate it, staying conservative wins.
        #expect(!AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "Midterm Review", dueA: nil,
            titleB: "Midterm", dueB: nil
        ))
    }

    @Test("similar-but-not-identical title with due dates far apart does not match")
    func similarTitleFarDueDatesDoesNotMatch() {
        #expect(!AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "PS1", dueA: Self.now,
            titleB: "Problem Set 1 (autograded)", dueB: Self.now.addingTimeInterval(10 * 86_400)
        ))
    }

    @Test("identical title but due dates weeks apart does not match (recurring generic title)")
    func identicalTitleFarDueDatesDoesNotMatch() {
        #expect(!AssignmentDeduplicator.isLikelyDuplicate(
            titleA: "Reading Response", dueA: Self.now,
            titleB: "Reading Response", dueB: Self.now.addingTimeInterval(30 * 86_400)
        ))
    }

    // MARK: - matchPairs: course scoping + 1:1 assignment

    @Test("same-titled items in different courses never match")
    func differentCoursesNeverMatch() {
        let matches = AssignmentDeduplicator.matchPairs(
            canvasItems: [Self.canvas(id: "c1", course: "CIS 1200", title: "HW 3")],
            gradescopeItems: [Self.gradescope(id: "g1", course: "MATH 1400", title: "HW 3")]
        )
        #expect(matches.isEmpty)
    }

    @Test("matches within the same course and leaves unrelated items alone")
    func matchesWithinCourse() {
        let matches = AssignmentDeduplicator.matchPairs(
            canvasItems: [
                Self.canvas(id: "c1", title: "Homework 3"),
                Self.canvas(id: "c2", title: "Homework 4"),
            ],
            gradescopeItems: [
                Self.gradescope(id: "g1", title: "HW3"),
                Self.gradescope(id: "g2", title: "Lab 1"),
            ]
        )
        #expect(matches == [AssignmentDeduplicator.Match(canvasID: "canvas:c1", gradescopeID: "gradescope:g1")])
    }

    @Test("1:1 assignment: a Gradescope item is never claimed by two Canvas items")
    func oneToOneAssignment() {
        let matches = AssignmentDeduplicator.matchPairs(
            canvasItems: [
                Self.canvas(id: "c1", title: "Homework 3"),
                Self.canvas(id: "c2", title: "Homework 3"), // duplicate Canvas title (unusual, but shouldn't double-claim)
            ],
            gradescopeItems: [
                Self.gradescope(id: "g1", title: "HW3"),
            ]
        )
        #expect(matches.count == 1)
        #expect(matches.first?.gradescopeID == "gradescope:g1")
    }

    // MARK: - merge

    @Test("merge collapses a matched pair into one Canvas-anchored item carrying linkedID")
    func mergeCollapsesMatchedPair() {
        let canvasItem = Self.canvas(id: "c1", title: "Homework 3", due: Self.now)
        let gradescopeItem = Self.gradescope(id: "g1", title: "HW3", due: Self.now)
        let merged = AssignmentDeduplicator.merge(canvasItems: [canvasItem], gradescopeItems: [gradescopeItem])

        #expect(merged.count == 1)
        let item = merged[0]
        #expect(item.id == canvasItem.id)          // Canvas-anchored (richer metadata)
        #expect(item.source == .canvas)
        #expect(item.linkedID == gradescopeItem.id) // tracks the Gradescope identity too
    }

    @Test("merge leaves unmatched items from both sources untouched")
    func mergeLeavesUnmatchedItemsAlone() {
        let canvasItem = Self.canvas(id: "c1", title: "Homework 3")
        let gradescopeItem = Self.gradescope(id: "g1", title: "Lab 1")
        let merged = AssignmentDeduplicator.merge(canvasItems: [canvasItem], gradescopeItems: [gradescopeItem])

        #expect(merged.count == 2)
        #expect(merged.contains { $0.id == canvasItem.id && $0.linkedID == nil })
        #expect(merged.contains { $0.id == gradescopeItem.id })
    }

    @Test("merge marks the merged item submitted if EITHER side reports it")
    func mergeSubmittedIsEitherSide() {
        let canvasItem = Self.canvas(id: "c1", title: "Homework 3", submitted: false)
        let gradescopeItem = Self.gradescope(id: "g1", title: "HW3", submitted: true)
        let merged = AssignmentDeduplicator.merge(canvasItems: [canvasItem], gradescopeItems: [gradescopeItem])

        #expect(merged.first?.submitted == true)
    }

    // MARK: - End-to-end through AppState: submission propagation

    @MainActor
    @Test("completing a merged dashboard item marks both underlying IDs complete")
    func completingMergedItemMarksBothIDs() {
        let state = AppState()

        // `AppState.assignments` filters by term/age relative to the real
        // `Date()` (it's not injectable), so this due date has to be "now",
        // not the fixed `Self.now` the pure matcher tests use. A dedicated,
        // unlikely-to-collide course code sidesteps other tests in this
        // package that toggle "CIS 1200"'s class-picker selection on the
        // same shared `SharedDefaults.store`.
        let due = Date()
        let course = "DEDUPE 9999"
        let canvasItem = Self.canvas(id: "dedupe-c1", course: course, title: "Homework 3", due: due)
        let gradescopeItem = Self.gradescope(id: "dedupe-g1", course: course, title: "HW3", due: due)

        state.canvasItems = [canvasItem]
        state.gradescopeItems = [gradescopeItem]
        // `canvasItems`/`gradescopeItems` aren't observed, so poke a rebuild
        // via a public mutator; this also gives a clean slate in case a
        // previous test run left these IDs completed (`completedAssignmentIDs`
        // persists across runs in `UserDefaults`).
        state.markActive(canvasItem)
        state.markActive(gradescopeItem)

        // The dashboard shows exactly one item for the pair.
        let dashboardItem = state.assignments.first { $0.id == canvasItem.id }
        #expect(dashboardItem != nil)
        #expect(dashboardItem?.linkedID == gradescopeItem.id)
        #expect(!state.assignments.contains { $0.id == gradescopeItem.id })

        guard let dashboardItem else { return }
        state.markCompleted(dashboardItem)

        // Both identities are independently recorded as complete.
        #expect(state.isCompleted(canvasItem))
        #expect(state.isCompleted(gradescopeItem))

        // Un-matching later (e.g. titles drift apart) still leaves both
        // identities correctly marked done, since each was recorded directly.
        let driftedGradescope = Self.gradescope(id: "dedupe-g1", title: "Completely Different Assignment", due: due)
        state.gradescopeItems = [driftedGradescope]
        #expect(state.isCompleted(canvasItem))
        #expect(state.isCompleted(driftedGradescope))

        state.markActive(dashboardItem)
        #expect(!state.isCompleted(canvasItem))
        #expect(!state.isCompleted(driftedGradescope))
    }

    @MainActor
    @Test("a manual completion recorded against the Gradescope identity before matching is honored after merge")
    func priorGradescopeCompletionHonoredAfterMerge() {
        let state = AppState()

        let gradescopeItem = Self.gradescope(id: "prior-g1", title: "HW3", due: Self.now)
        let canvasItem = Self.canvas(id: "prior-c1", title: "Homework 3", due: Self.now)
        // Clean slate — see the note in `completingMergedItemMarksBothIDs`.
        state.markActive(canvasItem)
        state.markActive(gradescopeItem)

        state.gradescopeItems = [gradescopeItem]
        state.canvasItems = []
        state.markCompleted(gradescopeItem) // completed while still standalone

        // Now Canvas posts the same assignment and the pair merges.
        state.canvasItems = [canvasItem]

        let dashboardCompleted = state.isCompleted(
            AssignmentDeduplicator.mergedAssignment(canvas: canvasItem, gradescope: gradescopeItem)
        )
        #expect(dashboardCompleted)

        // Cleanup so this test's persisted completion doesn't leak.
        state.markActive(canvasItem)
        state.markActive(gradescopeItem)
    }
}
