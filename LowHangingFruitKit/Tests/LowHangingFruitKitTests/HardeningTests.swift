import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// V1 hardening: feed the pure logic hostile / degenerate inputs and assert it
/// degrades gracefully (empty results, sane fallbacks) rather than crashing.
@Suite("V1 hardening — adversarial inputs")
struct HardeningTests {

    // MARK: ICS parser — malformed / partial feeds

    @Test func emptyAndGarbageYieldNoEvents() {
        #expect(ICSParser.parse(Data()).isEmpty)
        #expect(ICSParser.parse("").isEmpty)
        #expect(ICSParser.parse("not a calendar at all\njust text").isEmpty)
        // A BEGIN with no END is never emitted (avoids half-built events).
        #expect(ICSParser.parse("BEGIN:VEVENT\nSUMMARY:x").isEmpty)
    }

    @Test func strayEndDoesNotCrashAndLaterEventStillParses() {
        let text = "END:VEVENT\nBEGIN:VEVENT\nUID:1\nEND:VEVENT"
        let events = ICSParser.parse(text)
        #expect(events.count == 1)
        #expect(events.first?.uid == "1")
    }

    @Test func missingFieldsFallBackInsteadOfCrashing() {
        let events = ICSParser.parse("BEGIN:VEVENT\nEND:VEVENT")
        #expect(events.count == 1)
        let e = events[0]
        #expect(!e.uid.isEmpty)              // UUID fallback
        #expect(e.summary == "(untitled)")   // summary fallback
        #expect(e.dtStart == nil)            // no DTSTART → nil, not a crash
        #expect(e.url == nil)
    }

    @Test func malformedDateAndUrlBecomeNilNotCrash() {
        let text = """
        BEGIN:VEVENT
        UID:2
        SUMMARY:Broken [CIS 1200]
        DTSTART:not-a-real-date
        URL:ht!tp:// not a url
        END:VEVENT
        """
        let e = ICSParser.parse(text).first
        #expect(e != nil)
        #expect(e?.dtStart == nil)
        // A clearly invalid URL string must not become a bogus URL we later hit.
        #expect(e?.url == nil || e?.url?.host == nil)
    }

    @Test func crlfEndingsAndFoldedLinesUnfold() {
        let text = "BEGIN:VEVENT\r\nUID:3\r\nSUMMARY:Long titl\r\n e here [C]\r\nEND:VEVENT\r\n"
        let e = ICSParser.parse(text).first
        #expect(e?.uid == "3")
        #expect(e?.summary.contains("Long title here") == true)  // folded line joined
    }

    @Test func fieldLineWithoutColonIsIgnored() {
        let events = ICSParser.parse("BEGIN:VEVENT\nGARBAGE-NO-COLON\nUID:4\nEND:VEVENT")
        #expect(events.first?.uid == "4")
    }

    // MARK: Course splitting — bracket edge cases

    @Test func splitCourseHandlesDegenerateSummaries() {
        #expect(CanvasICSClient.splitCourse(from: "No brackets here").course == "(unknown course)")
        let only = CanvasICSClient.splitCourse(from: "[JustACourse]")
        #expect(only.course == "JustACourse")
        #expect(only.title.isEmpty)
        // Multiple brackets: the LAST bracketed group is treated as the course.
        let multi = CanvasICSClient.splitCourse(from: "Weird [A] [B]")
        #expect(multi.course == "B")
        #expect(CanvasICSClient.splitCourse(from: "").course == "(unknown course)")
    }

    // MARK: Kind classification — URL then UID heuristics

    @Test func classifyByUrlThenUid() {
        func ev(_ uid: String, _ url: String?) -> ICSParser.Event {
            ICSParser.Event(uid: uid, summary: "s", dtStart: nil, url: url.flatMap(URL.init(string:)))
        }
        #expect(CanvasICSClient.classify(ev("x", "https://canvas.upenn.edu/courses/1/assignments/5")) == .assignment)
        #expect(CanvasICSClient.classify(ev("x", "https://canvas.upenn.edu/courses/1/quizzes/5")) == .quiz)
        #expect(CanvasICSClient.classify(ev("event-quiz-9", nil)) == .quiz)   // uid fallback
        #expect(CanvasICSClient.classify(ev("mystery", nil)) == .other)       // nothing matches
    }

    // MARK: Recurring task generation — bounded, no runaway loops

    @Test func recurringTaskIsBoundedAndFuture() {
        let now = Date()
        let task = RecurringTask(title: "Weekly reading", course: "HIST 1000",
                                 weekday: 3, hour: 9, minute: 0,
                                 startDate: now.addingTimeInterval(-86_400), endDate: nil,
                                 origin: .manual)
        let items = task.upcomingAssignments(from: now, weeksAhead: 10)
        #expect(items.count >= 1)
        #expect(items.count <= 11)                                   // one per week over the horizon
        #expect(items.allSatisfy { ($0.dueAt ?? now) >= now.addingTimeInterval(-3600) })
    }

    @Test func recurringTaskWithPastEndDateProducesNothing() {
        let now = Date()
        let task = RecurringTask(title: "Old lab", course: "BIOL 1000",
                                 weekday: 2, hour: 10, minute: 0,
                                 startDate: now.addingTimeInterval(-30 * 86_400),
                                 endDate: now.addingTimeInterval(-7 * 86_400),
                                 origin: .manual)
        #expect(task.upcomingAssignments(from: now).isEmpty)
    }

    @Test func recurringTaskStartingBeyondHorizonProducesNothing() {
        let now = Date()
        let task = RecurringTask(title: "Future seminar", course: "PHIL 2000",
                                 weekday: 5, hour: 14, minute: 30,
                                 startDate: now.addingTimeInterval(365 * 86_400), endDate: nil,
                                 origin: .manual)
        #expect(task.upcomingAssignments(from: now, weeksAhead: 10).isEmpty)
    }

    // MARK: Dashboard window classification (pure statics)

    @MainActor @Test func activeLaterAndTooOldWindows() {
        let now = Date()
        func a(_ days: Double, kind: Assignment.Kind = .assignment) -> Assignment {
            Assignment(source: .canvas, sourceID: "d\(days)", kind: kind, course: "C",
                       title: "T", dueAt: now.addingTimeInterval(days * 86_400), url: nil)
        }
        let undated = Assignment(source: .canvas, sourceID: "u", kind: .assignment,
                                 course: "C", title: "T", dueAt: nil, url: nil)

        // Near vs later partition the pool with no gap: overdue and due-this-week
        // are "near"; beyond a week out and undated are "later".
        #expect(AppState.isNearOrOverdue(a(0), now: now))
        #expect(AppState.isNearOrOverdue(a(6), now: now))
        #expect(AppState.isNearOrOverdue(a(-30), now: now))  // long overdue is still near
        #expect(!AppState.isNearOrOverdue(a(10), now: now))
        #expect(!AppState.isNearOrOverdue(undated, now: now))  // undated sorts to Later

        #expect(AppState.isTooOld(a(-200), now: now))       // ~6.5 months ago
        #expect(!AppState.isTooOld(a(-10), now: now))
        #expect(!AppState.isTooOld(undated, now: now))      // can't age an undated item
    }

    @MainActor @Test func assessmentDetection() {
        func item(_ kind: Assignment.Kind, _ title: String) -> Assignment {
            Assignment(source: .canvas, sourceID: title, kind: kind, course: "C",
                       title: title, dueAt: nil, url: nil)
        }
        #expect(AppState.isAssessment(item(.quiz, "anything")))         // by kind
        #expect(AppState.isAssessment(item(.assignment, "Midterm 1")))  // by title
        #expect(AppState.isAssessment(item(.assignment, "Final Exam")))
        #expect(!AppState.isAssessment(item(.assignment, "Homework 3")))
    }
}
