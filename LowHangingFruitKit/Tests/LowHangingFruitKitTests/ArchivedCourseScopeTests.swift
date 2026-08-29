import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The archive's promise is that a semester the student filed away stays filed.
///
/// `withinTermCap` enforces it, and it did so by reading either the item's term
/// or its due date. A Gradescope item can carry neither — the scraper stamped no
/// term at all, and Gradescope assignments are routinely posted with no
/// deadline — and that combination hit the "undated items always pass" clause
/// and walked straight through. The per-row stamp (`archivedAssignmentIDs`)
/// covers rows that were on the ledger when the student confirmed; an item
/// re-ingested afterwards, or one that never got a row, was not covered by
/// anything.
@MainActor
@Suite("Archived classes stay archived, whichever source they came from")
struct ArchivedCourseScopeTests {

    private let spring = Term(year: 2026, season: .spring)

    private func gradescopeItem(
        course: String = "CIS 1200",
        due: Date? = nil,
        term: Term? = nil
    ) -> Assignment {
        Assignment(source: .gradescope, sourceID: "g1", kind: .assignment,
                   course: course, title: "Homework 4", dueAt: due, url: nil, term: term)
    }

    @Test("an undated, termless item from an archived class is gone")
    func undatedItemFromAnArchivedClassIsGone() {
        let item = gradescopeItem()

        // Nothing archived: unchanged from before — undated items pass.
        #expect(AppState.withinTermCap(item))
        #expect(!AppState.withinTermCap(item, archivedCourseTerms: ["CIS 1200": spring]))
    }

    @Test("another class's archive doesn't touch it")
    func anotherClassesArchiveIsIrrelevant() {
        #expect(AppState.withinTermCap(
            gradescopeItem(),
            archivedCourseTerms: ["FNAR 0010": spring]
        ))
    }

    /// The rollover deliberately leaves a class that is *also* running this term
    /// unstamped (a retaken CIS 1200), so its undated work keeps showing.
    @Test("a class still running this term has no stamp, so its work stays")
    func retakenClassKeepsItsWork() {
        #expect(AppState.withinTermCap(gradescopeItem(), archivedCourseTerms: [:]))
    }

    /// What the Gradescope term stamp buys: with a term, an item is archivable
    /// by term like any Canvas item, rather than depending on the course stamp.
    @Test("a stamped term lets the archive reach a Gradescope item directly")
    func stampedTermIsArchivable() {
        let item = gradescopeItem(term: spring)

        #expect(!AppState.withinTermCap(item, archivedTerms: [spring]))
        #expect(AppState.withinTermCap(item, archivedTerms: [Term(year: 2025, season: .fall)]))
    }

    @Test("a dated item is still judged by its due date, not the course stamp")
    func datedItemsAreUnaffected() {
        let soon = Date().addingTimeInterval(3 * 86_400)

        // The dated path is unchanged: this is near-term work, and it stays even
        // while the class carries a stamp from a term it was previously taken in.
        #expect(AppState.withinTermCap(
            gradescopeItem(due: soon),
            archivedCourseTerms: ["CIS 1200": Term(year: 2020, season: .fall)]
        ))
    }
}
