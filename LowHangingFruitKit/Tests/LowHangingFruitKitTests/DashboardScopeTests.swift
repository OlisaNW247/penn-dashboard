import XCTest
@testable import LowHangingFruitUI
import LowHangingFruitKit

/// Guards the rule a user reported us breaking: work from a class that is over
/// must not appear on the dashboard. Everything is asserted against
/// `AppState.buckets`, the single place scope is decided, so a list added later
/// can't quietly reintroduce the leak.
@MainActor
final class DashboardScopeTests: XCTestCase {

    private let calendar = Calendar.current

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private func item(_ title: String,
                      course: String = "CIS 3200",
                      due: Date?,
                      kind: Assignment.Kind = .assignment,
                      source: Assignment.Source = .canvas) -> Assignment {
        Assignment(source: source, sourceID: "\(course)-\(title)", kind: kind,
                   course: course, title: title, dueAt: due, url: nil)
    }

    private func buckets(_ pool: [Assignment], now: Date) -> AppState.DashboardBuckets {
        AppState.buckets(from: pool, now: now, isCompleted: { _ in false })
    }

    private func everythingShown(_ b: AppState.DashboardBuckets) -> [Assignment] {
        b.assignments + b.later + b.assessments
    }

    /// The reported bug, exactly: on Aug 28 the dashboard showed "CIS 3200
    /// Homework 4 — 27 days late". Canvas classifies plenty of homework as a
    /// quiz, and the assessments list had no date floor at all, so a summer
    /// course's leftovers rode into "this week" as overdue.
    func testLastTermsQuizClassifiedHomeworkIsGone() {
        let now = date(2025, 8, 28)
        let stale = item("Homework 4", due: date(2025, 8, 1), kind: .quiz)

        let result = buckets([stale], now: now)

        XCTAssertTrue(everythingShown(result).isEmpty, "a finished course's work must not show anywhere")
        XCTAssertTrue(result.inScope.isEmpty, "and it must not even be in scope")
    }

    /// Same symptom, different cause: an item that really is this term's, but is
    /// a month past due, used to sit in the assessments list forever.
    func testThisTermsAssessmentStopsLingeringAfterAWeek() {
        let now = date(2025, 10, 1)
        let old = item("Midterm 1", due: date(2025, 9, 3), kind: .quiz)
        let recent = item("Quiz 6", due: date(2025, 9, 29), kind: .quiz)

        let result = buckets([old, recent], now: now)

        XCTAssertEqual(result.assessments.map(\.title), ["Quiz 6"])
    }

    func testEveryListIsScopedToTheCurrentTerm() {
        let now = date(2025, 9, 15)
        let pool = [
            item("Spring final", course: "CIS 1200", due: date(2025, 5, 5)),
            item("Summer lab", course: "PHYS 0151", due: date(2025, 7, 20)),
            item("Summer exam", course: "PHYS 0151", due: date(2025, 7, 22), kind: .quiz),
            item("This week's pset", due: date(2025, 9, 17)),
        ]

        let result = buckets(pool, now: now)

        XCTAssertEqual(everythingShown(result).map(\.title), ["This week's pset"])
    }

    /// Undated items carry no date to judge, so they follow their course: it
    /// counts as live only while it still has current-term work.
    func testUndatedItemsFollowTheirCourse() {
        let now = date(2025, 9, 15)
        let pool = [
            item("Final project", course: "FNAR 0010", due: nil),
            item("Week 3 crit", course: "FNAR 0010", due: date(2025, 9, 19)),
            item("Portfolio", course: "FNAR 2200", due: nil),          // finished course
            item("Spring crit", course: "FNAR 2200", due: date(2025, 4, 2)),
        ]

        let titles = everythingShown(buckets(pool, now: now)).map(\.title)

        XCTAssertTrue(titles.contains("Final project"), "live course keeps its undated work")
        XCTAssertFalse(titles.contains("Portfolio"), "a finished course's undated work must not survive")
    }

    /// The student typed these in themselves; never drop one for lacking a date.
    func testUserCreatedUndatedItemsAreKept() {
        let now = date(2025, 9, 15)
        let mine = item("Email the TA", course: "", due: nil, source: .manual)

        XCTAssertEqual(everythingShown(buckets([mine], now: now)).map(\.title), ["Email the TA"])
    }

    /// Scope has no upper bound: next term's work is worth looking ahead to.
    func testNextTermsWorkIsStillVisible() {
        let now = date(2025, 12, 1)
        let spring = item("Spring reading", due: date(2026, 1, 20))

        XCTAssertEqual(buckets([spring], now: now).later.map(\.title), ["Spring reading"])
    }

    /// The tightening must not hide the work the dashboard exists to show.
    func testCurrentWorkStillShows() {
        let now = date(2025, 9, 15)
        let pool = [
            item("Overdue pset", due: date(2025, 9, 12)),
            item("Due today", due: date(2025, 9, 15, 23)),
            item("Later this week", due: date(2025, 9, 19)),
            item("Next month", due: date(2025, 10, 20)),
            item("Final exam", due: date(2025, 12, 15), kind: .quiz),
        ]

        let result = buckets(pool, now: now)

        XCTAssertEqual(result.assignments.map(\.title), ["Overdue pset", "Due today", "Later this week"])
        XCTAssertEqual(result.later.map(\.title), ["Next month"])
        XCTAssertEqual(result.assessments.map(\.title), ["Final exam"])
    }
}
