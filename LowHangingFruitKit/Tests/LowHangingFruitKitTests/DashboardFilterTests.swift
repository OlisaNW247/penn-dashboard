import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@MainActor
@Suite("Dashboard filtering")
struct DashboardFilterTests {
    private func item(kind: Assignment.Kind, course: String, title: String) -> Assignment {
        Assignment(source: .canvas, sourceID: "\(course)-\(title)", kind: kind,
                   course: course, title: title, dueAt: Date(), url: nil)
    }

    @Test("course-less holidays are never treated as assessments")
    func holidaysAreNotAssessments() {
        // The exact shape that leaked onto the dashboard before the fix.
        #expect(!AppState.isAssessment(item(kind: .event, course: "(unknown course)",
                                            title: "Rosh Hashanah no exams")))
        #expect(!AppState.isAssessment(item(kind: .other, course: "(unknown course)",
                                            title: "Fall Break — no classes")))
        #expect(!AppState.isAssessment(item(kind: .event, course: "(unknown course)",
                                            title: "Reading Days (no final exams)")))
    }

    @Test("real course assessments still surface")
    func realAssessmentsSurface() {
        #expect(AppState.isAssessment(item(kind: .quiz, course: "CIS 1200", title: "Quiz 2")))
        // An exam professors upload as a calendar event, but that belongs to a course.
        #expect(AppState.isAssessment(item(kind: .event, course: "CIS 1200", title: "Midterm 1")))
        // Plain coursework is not an assessment (it's shown as a regular assignment).
        #expect(!AppState.isAssessment(item(kind: .assignment, course: "CIS 1200", title: "Homework 3")))
    }

    @Test("overdue by more than a week still surfaces (no near/later gap)")
    func farOverdueStillSurfaces() {
        let now = Date()
        let farOverdue = Assignment(source: .canvas, sourceID: "old", kind: .assignment,
                                    course: "CIS 1200", title: "PSet 1",
                                    dueAt: now.addingTimeInterval(-14 * 86_400), url: nil)
        // Near/later must partition the pool completely: an item overdue by two
        // weeks belongs to "near", not to a gap between the two buckets.
        #expect(AppState.isNearOrOverdue(farOverdue, now: now))
        #expect(!AppState.isTooOld(farOverdue, now: now))
    }

    @Test("term cap hides next-term work but never near-term or undated work")
    func termCapBounds() {
        let now = Date()
        func due(_ d: Double) -> Assignment {
            Assignment(source: .canvas, sourceID: "\(d)", kind: .assignment, course: "CIS 1200",
                       title: "HW", dueAt: now.addingTimeInterval(d * 86_400), url: nil)
        }
        let undated = Assignment(source: .canvas, sourceID: "u", kind: .assignment,
                                 course: "CIS 1200", title: "HW", dueAt: nil, url: nil)

        #expect(AppState.withinTermCap(due(3), now: now))       // this week — always safe
        #expect(AppState.withinTermCap(undated, now: now))      // undated — always passes
        #expect(AppState.withinTermCap(due(-5), now: now))      // overdue — always passes
        // A year out is definitively beyond the current term.
        #expect(!AppState.withinTermCap(due(365), now: now))
    }

    @Test("term-tagged items: a future term is capped out, current/past kept")
    func termMembershipCap() {
        func item(term: Term) -> Assignment {
            Assignment(source: .canvas, sourceID: "t\(term.year)", kind: .assignment, course: "CIS 1200",
                       title: "HW", dueAt: Date().addingTimeInterval(3 * 86_400), url: nil, term: term)
        }
        // A far-future term is definitely after the current one → excluded.
        #expect(!AppState.withinTermCap(item(term: Term(year: 2099, season: .fall))))
        // A past term passes the cap (its age is handled by isTooOld / the picker).
        #expect(AppState.withinTermCap(item(term: Term(year: 2000, season: .spring))))
    }

    @Test("expired events: a dated .event expires the moment its due time passes, not at end of day")
    func expiredEventBoundaries() {
        let calendar = Calendar.current
        let now = Date()
        // A class that started minutes ago, same calendar day. Under the old
        // day-granularity rule this stayed OVERDUE until midnight — exactly
        // the "1h late" the owner's device pass caught. It must expire
        // immediately now.
        let minutesAgoSameDay = now.addingTimeInterval(-90 * 60)
        // Symmetric case a moment in the future, same day: still not expired.
        let minutesFromNowSameDay = now.addingTimeInterval(90 * 60)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!

        func dated(kind: Assignment.Kind, dueAt: Date?) -> Assignment {
            Assignment(source: .canvas, sourceID: "x", kind: kind, course: "CIS 1200",
                       title: "Reading", dueAt: dueAt, url: nil)
        }

        #expect(AppState.isExpiredEvent(dated(kind: .event, dueAt: minutesAgoSameDay), now: now))
        #expect(AppState.isExpiredEvent(dated(kind: .event, dueAt: yesterday), now: now))
        #expect(!AppState.isExpiredEvent(dated(kind: .event, dueAt: minutesFromNowSameDay), now: now))
        #expect(!AppState.isExpiredEvent(dated(kind: .event, dueAt: tomorrow), now: now))
        #expect(!AppState.isExpiredEvent(dated(kind: .event, dueAt: nil), now: now))
        // A last-week assignment has something to submit, so it's overdue, not expired.
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: now)!
        #expect(!AppState.isExpiredEvent(dated(kind: .assignment, dueAt: lastWeek), now: now))
    }

    @Test("deselecting a course hides it; everything is selected by default")
    func courseSelection() {
        let state = AppState()
        state.hiddenCourseKeys.forEach { state.setCourse($0, selected: true) }  // clean slate

        #expect(state.isCourseSelected("CIS 1200"))    // default: on
        state.setCourse("CIS 1200", selected: false)
        #expect(!state.isCourseSelected("CIS 1200"))
        #expect(state.isCourseSelected("MATH 1400"))   // unrelated course unaffected
        state.setCourse("CIS 1200", selected: true)
        #expect(state.isCourseSelected("CIS 1200"))
    }

    @Test("deleting a course drops it from the classes list and hides it like a toggle-off; restore undoes both")
    func courseDeletionAndRestore() {
        let state = AppState()
        // Clean slate: undo any deletions/hides a prior run left behind.
        state.deletedCourseCodes().forEach { state.restoreCourse($0) }
        state.hiddenCourseKeys.forEach { state.setCourse($0, selected: true) }

        state.canvasItems = [
            Assignment(source: .canvas, sourceID: "1", kind: .assignment,
                       course: "CIS 1200", title: "HW1", dueAt: Date(), url: nil),
            Assignment(source: .canvas, sourceID: "2", kind: .assignment,
                       course: "MATH 1400", title: "HW1", dueAt: Date(), url: nil),
        ]

        #expect(!state.isCourseDeleted("CIS 1200"))
        #expect(state.visibleCourseCodes().contains("CIS 1200"))

        state.deleteCourse("CIS 1200")

        // Deleted: gone from the classes list, excluded like a hidden course,
        // and listed for restore.
        #expect(state.isCourseDeleted("CIS 1200"))
        #expect(!state.visibleCourseCodes().contains("CIS 1200"))
        #expect(!state.isCourseSelected("CIS 1200"))
        #expect(state.deletedCourseCodes() == ["CIS 1200"])
        // Unrelated course is untouched.
        #expect(state.visibleCourseCodes().contains("MATH 1400"))
        #expect(state.isCourseSelected("MATH 1400"))

        // Persisted: a fresh AppState instance (reading the same UserDefaults)
        // still sees it deleted.
        let reloaded = AppState()
        #expect(reloaded.isCourseDeleted("CIS 1200"))

        state.restoreCourse("CIS 1200")

        #expect(!state.isCourseDeleted("CIS 1200"))
        #expect(state.visibleCourseCodes().contains("CIS 1200"))
        #expect(state.isCourseSelected("CIS 1200"))
        #expect(state.deletedCourseCodes().isEmpty)
    }
}
