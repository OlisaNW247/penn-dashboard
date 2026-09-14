import Foundation
import Testing
@testable import LowHangingFruitKit

/// Covers the fix for a real phone transcript (2026-09-13): ask's "when's
/// my next exam?" answered "Your next exam is Yom Kippur (no
/// exams/assignments) for (unknown course): Sun, Sep 20 … After that: Yom
/// Kippur (no exams/assignments) ((unknown course)), Mon Sep 21". Two
/// defects fed that answer: `WorkKindFilter.exam` matched "exams" inside a
/// title that says there are NO exams, and a course-less, twice-listed
/// calendar entry was eligible to be "the next exam" at all. See
/// `ExamDetector`'s header and `ClassQuestionAnswerer.nextItem` for the
/// fix itself.
@Suite("Exam detection")
struct ExamDetectorTests {
    @Test("classifies exam-ish titles, honoring negation and governing words")
    func classifiesTitles() {
        let cases: [(title: String, isExam: Bool)] = [
            ("Midterm 1", true),
            ("Final Exam", true),
            // Quizzes belong to `WorkKindFilter.quiz`, not the exam filter.
            ("Quiz 3", false),
            // The exact holiday title from the phone transcript: the word
            // "exams" is present, but negated by "no" two words earlier.
            ("Yom Kippur (no exams/assignments)", false),
            ("No class, no quiz this week", false),
            // "final" here modifies "project", not standing in for an exam.
            ("Final project proposal", false),
            // The exam word is present, but the title is ABOUT an exam
            // (a review session), not the exam itself.
            ("Midterm review session", false),
            // Negation word after the exam word, not just before.
            ("Exam 2 cancelled", false),
            ("Test", true),
            // "final" modifies "Frontier" (a reading title), not an exam.
            ("Reading: The Final Frontier", false),
        ]
        for testCase in cases {
            #expect(
                ExamDetector.isExam(title: testCase.title) == testCase.isExam,
                "expected isExam(\"\(testCase.title)\") == \(testCase.isExam)"
            )
        }
    }
}

@Suite("Next-exam answer")
struct NextExamAnswerTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    private static let now = date(2026, 9, 13, hour: 9)

    /// The exact shape that leaked onto a real device: the same course-less
    /// holiday listed twice for the same day, once all-day and once timed.
    private static let holidayAllDay = WorkItem(
        id: "holiday-allday", course: "(unknown course)", title: "Yom Kippur (no exams/assignments)",
        kind: .event, dueAt: date(2026, 9, 20), url: nil, isCompleted: false
    )
    private static let holidayTimed = WorkItem(
        id: "holiday-timed", course: "(unknown course)", title: "Yom Kippur (no exams/assignments)",
        kind: .event, dueAt: date(2026, 9, 20, hour: 18), url: nil, isCompleted: false
    )
    private static let midterm = WorkItem(
        id: "midterm-1", course: "CIS 2400", title: "Midterm 1",
        kind: .quiz, dueAt: date(2026, 9, 25, hour: 12), url: nil, isCompleted: false
    )

    private static func context(items: [WorkItem]) -> AskKnowledgeContext {
        AskKnowledgeContext(now: now, calendar: calendar, items: items, knowledge: CourseKnowledgeBase())
    }

    @Test("names the real midterm, never the course-less holiday, when both are in the feed")
    func namesRealExamNotHoliday() {
        let context = Self.context(items: [Self.holidayAllDay, Self.holidayTimed, Self.midterm])
        let answer = ClassQuestionAnswerer(context: context).answer("When is my next exam?")
        #expect(answer.text.contains("Midterm 1"))
        #expect(answer.text.contains("CIS 2400"))
        #expect(!answer.text.contains("Yom Kippur"))
        #expect(!answer.text.contains("unknown course"))
    }

    @Test("reports no upcoming exams when only the course-less holiday is in the feed")
    func noUpcomingExamsWithOnlyHoliday() {
        let context = Self.context(items: [Self.holidayAllDay, Self.holidayTimed])
        let answer = ClassQuestionAnswerer(context: context).answer("When is my next exam?")
        #expect(answer.text.lowercased().contains("no upcoming exams"))
        #expect(!answer.text.contains("Yom Kippur"))
    }
}
