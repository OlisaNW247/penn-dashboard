import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `SubmissionMatcher`: the title/due-date fallback that recovers
/// a Canvas assignment id for a `.canvasModules` row whose module item
/// carried no `/assignments/<id>` URL, so it can still join Grade Watcher's
/// submission side-channel (`AssignmentStore.applySubmissionState`).
@Suite("Submission matcher")
struct SubmissionMatcherTests {

    private func moduleRow(
        id: String = "module-item-1",
        course: String = "CIS 1200",
        title: String,
        due: Date? = nil,
        url: URL? = nil
    ) -> Assignment {
        Assignment(source: .canvasModules, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due, url: url)
    }

    private func gradeItem(id: String, name: String, due: Date? = nil) -> GradeItem {
        GradeItem(id: id, name: name, pointsPossible: 100, dueAt: due)
    }

    private let day1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let day30 = Date(timeIntervalSince1970: 1_700_000_000 + 30 * 86_400)

    // MARK: - matchCanvasAssignmentID

    @Test("a unique title match resolves")
    func uniqueTitleMatchResolves() {
        let row = moduleRow(title: "Homework 3", due: day1)
        let items = [
            gradeItem(id: "111", name: "HW 3", due: day1),
            gradeItem(id: "222", name: "Lab 1", due: day1),
        ]
        #expect(SubmissionMatcher.matchCanvasAssignmentID(for: row, gradeItems: items) == "111")
    }

    @Test("identical titles resolve when a far-apart due date rules the other candidate out")
    func identicalTitlesResolveByDueDate() {
        // Both "Reading Response" grade items normalize identically, so this
        // is only resolvable because the module row's own due date sits near
        // exactly one of them — the other fails `isLikelyDuplicate`'s
        // same-title-max-due-gap rule outright and is never a candidate.
        let row = moduleRow(title: "Reading Response", due: day1)
        let items = [
            gradeItem(id: "111", name: "Reading Response", due: day1),
            gradeItem(id: "222", name: "Reading Response", due: day30),
        ]
        #expect(SubmissionMatcher.matchCanvasAssignmentID(for: row, gradeItems: items) == "111")
    }

    @Test("ambiguous with both candidates equally plausible resolves via exact-title tie-break")
    func exactTitleTieBreaksAmongPlausibleCandidates() {
        // "Midterm 1" and "Midterm 1 Review" are both close enough in due
        // date to be plausible (rule 3 of `isLikelyDuplicate`), so both are
        // candidates — but only "Midterm 1" normalizes to exactly the row's
        // own title, so the tie-break picks it over the fuzzy sibling.
        let due = day1
        let row = moduleRow(title: "Midterm 1", due: due)
        let items = [
            gradeItem(id: "111", name: "Midterm 1", due: due.addingTimeInterval(3600)),
            gradeItem(id: "222", name: "Midterm 1 Review", due: due.addingTimeInterval(3600)),
        ]
        #expect(SubmissionMatcher.matchCanvasAssignmentID(for: row, gradeItems: items) == "111")
    }

    @Test("ambiguous identical titles with identical due dates never guess")
    func ambiguousIdenticalDueDatesReturnNil() {
        let row = moduleRow(title: "Reading Response", due: day1)
        let items = [
            gradeItem(id: "111", name: "Reading Response", due: day1),
            gradeItem(id: "222", name: "Reading Response", due: day1),
        ]
        #expect(SubmissionMatcher.matchCanvasAssignmentID(for: row, gradeItems: items) == nil)
    }

    @Test("a row with its own canvasAssignmentID is never matched")
    func rowWithOwnIDIsSkipped() {
        let row = moduleRow(
            title: "Homework 3", due: day1,
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/999")
        )
        #expect(row.canvasAssignmentID == "999")
        let items = [gradeItem(id: "111", name: "HW 3", due: day1)]
        #expect(SubmissionMatcher.matchCanvasAssignmentID(for: row, gradeItems: items) == nil)
    }

    @Test("a non-Canvas source is never matched")
    func nonCanvasSourceIgnored() {
        let row = Assignment(source: .gradescope, sourceID: "g1", kind: .assignment,
                              course: "CIS 1200", title: "Homework 3", dueAt: day1, url: nil)
        let items = [gradeItem(id: "111", name: "HW 3", due: day1)]
        #expect(SubmissionMatcher.matchCanvasAssignmentID(for: row, gradeItems: items) == nil)
    }

    @Test("an empty title is never matched")
    func emptyTitleReturnsNil() {
        let row = moduleRow(title: "   ", due: day1)
        let items = [gradeItem(id: "111", name: "HW 3", due: day1)]
        #expect(SubmissionMatcher.matchCanvasAssignmentID(for: row, gradeItems: items) == nil)
    }

    // MARK: - fallbackCanvasAssignmentIDs (batch)

    @Test("the batch map excludes rows that already have their own canvasAssignmentID")
    func batchExcludesRowsWithOwnID() {
        let resolvable = moduleRow(id: "module-item-1", title: "Homework 3", due: day1)
        let alreadyResolved = moduleRow(
            id: "module-item-2", title: "Homework 4", due: day1,
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/321")
        )
        let items = [
            gradeItem(id: "111", name: "HW 3", due: day1),
            gradeItem(id: "321", name: "HW 4", due: day1),
        ]
        let result = SubmissionMatcher.fallbackCanvasAssignmentIDs(
            rows: [resolvable, alreadyResolved],
            gradeItemsByCourse: ["CIS 1200": items]
        )
        #expect(result[resolvable.id] == "111")
        #expect(result[alreadyResolved.id] == nil)
    }

    @Test("the batch map is keyed by course")
    func batchKeyedByCourse() {
        let row = moduleRow(course: "CIS 1200", title: "Homework 3", due: day1)
        let result = SubmissionMatcher.fallbackCanvasAssignmentIDs(
            rows: [row],
            gradeItemsByCourse: ["MATH 1400": [gradeItem(id: "111", name: "HW 3", due: day1)]]
        )
        #expect(result.isEmpty)
    }
}
