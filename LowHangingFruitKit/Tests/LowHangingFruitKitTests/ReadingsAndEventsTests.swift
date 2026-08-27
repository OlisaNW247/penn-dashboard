import XCTest
@testable import LowHangingFruitUI
import LowHangingFruitKit

/// Tests the pure predicate behind the Settings "Readings & events" list —
/// the bucket that replaced the old "Other" tab (non-coursework Canvas items).
@MainActor
final class ReadingsAndEventsTests: XCTestCase {

    private func item(_ id: String, kind: Assignment.Kind, title: String = "Item",
                      due: Date?) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: kind,
                   course: "CIS 2400", title: title, dueAt: due, url: nil)
    }

    func testIncludesUpcomingEventsReadingsAndDiscussions() {
        let now = Date()
        let soon = now.addingTimeInterval(3 * 86_400)
        XCTAssertTrue(AppState.isReadingOrEvent(item("1", kind: .event, due: soon), now: now))
        XCTAssertTrue(AppState.isReadingOrEvent(item("2", kind: .other, title: "Reading: Ch. 5", due: soon), now: now))
        XCTAssertTrue(AppState.isReadingOrEvent(item("3", kind: .discussion, due: soon), now: now))
    }

    func testExcludesCourseworkAndAssessments() {
        let now = Date()
        let soon = now.addingTimeInterval(3 * 86_400)
        // Assignments and quizzes already live in the dashboard/assessments lists.
        XCTAssertFalse(AppState.isReadingOrEvent(item("1", kind: .assignment, due: soon), now: now))
        XCTAssertFalse(AppState.isReadingOrEvent(item("2", kind: .quiz, due: soon), now: now))
        // Title-detected assessments are excluded even when classified as events.
        XCTAssertFalse(AppState.isReadingOrEvent(item("3", kind: .event, title: "Midterm exam", due: soon), now: now))
    }

    func testWindowsToRecentPastThroughTwoWeeks() {
        let now = Date()
        XCTAssertTrue(AppState.isReadingOrEvent(item("1", kind: .event, due: now.addingTimeInterval(-3_600)), now: now),
                      "earlier today stays visible")
        XCTAssertFalse(AppState.isReadingOrEvent(item("2", kind: .event, due: now.addingTimeInterval(-2 * 86_400)), now: now),
                       "older past events drop out")
        XCTAssertTrue(AppState.isReadingOrEvent(item("3", kind: .event, due: now.addingTimeInterval(13 * 86_400)), now: now))
        XCTAssertFalse(AppState.isReadingOrEvent(item("4", kind: .event, due: now.addingTimeInterval(20 * 86_400)), now: now),
                       "beyond the two-week window is hidden so a whole semester doesn't flood the list")
        XCTAssertFalse(AppState.isReadingOrEvent(item("5", kind: .event, due: nil), now: now),
                       "undated items can't be windowed")
    }
}
