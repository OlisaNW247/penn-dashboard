import Foundation
import Testing
@testable import LowHangingFruitKit

/// A fixed "now" (Tuesday 2026-09-08 10:00 in Philadelphia) and a small
/// semester's worth of items and materials, so every answer is deterministic.
enum AssistantFixture {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    static var now: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 8; components.hour = 10
        return calendar.date(from: components)!
    }

    /// Defaults to 11:59 PM (Canvas's usual deadline); any other hour is on the hour.
    static func at(day: Int, hour: Int = 23, minute: Int? = nil, month: Int = 9) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = month; components.day = day; components.hour = hour
        components.minute = minute ?? (hour == 23 ? 59 : 0)
        return calendar.date(from: components)!
    }

    static func item(_ id: String, _ course: String, _ title: String, due: Date?, kind: Assignment.Kind = .assignment, done: Bool = false) -> WorkItem {
        WorkItem(id: id, course: course, title: title, kind: kind, dueAt: due,
                 url: URL(string: "https://canvas.upenn.edu/courses/\(course.hasPrefix("CIS") ? 1 : 2)/assignments/\(id)"), isCompleted: done)
    }

    static let items: [WorkItem] = [
        item("1", "CIS 2400", "PSet 2: bits and bytes", due: at(day: 6)),                       // overdue (Sunday)
        item("2", "CIS 2400", "PSet 3: caches", due: at(day: 10)),                              // Thursday
        item("3", "CIS 2400", "Midterm 1", due: at(day: 30, hour: 12), kind: .quiz),            // Sept 30
        item("4", "ECON 1", "Problem set 3", due: at(day: 11, hour: 17)),                       // Friday 5 PM
        item("5", "ECON 1", "Weekly quiz 2", due: at(day: 9, hour: 9), kind: .quiz),            // Wednesday
        item("6", "ECON 1", "Midterm 1", due: at(day: 1, hour: 19, month: 10)),                 // Oct 1
        item("7", "MGMT 1010", "Group case writeup", due: at(day: 15, hour: 9)),                // next Tuesday
        item("8", "CIS 2400", "PSet 1: warmup", due: at(day: 2), done: true),                   // done
        item("9", "MGMT 1010", "Reading response", due: nil),
    ]

    static let courses = [
        CourseSummary(courseID: "1", code: "CIS 2400", name: "CIS 2400 Introduction to Computer Systems", url: URL(string: "https://canvas.upenn.edu/courses/1")),
        CourseSummary(courseID: "2", code: "ECON 1", name: "ECON 1 Introduction to Micro Economics", url: URL(string: "https://canvas.upenn.edu/courses/2")),
        CourseSummary(courseID: "3", code: "MGMT 1010", name: "MGMT 1010 Introduction to Management", url: nil),
    ]

    static var knowledge: CourseKnowledgeBase {
        CourseKnowledgeBase(courses: courses, documents: [
            CourseDocument(courseID: "1", course: "CIS 2400", kind: .syllabus, sourceID: "syllabus", title: "CIS 2400 syllabus",
                           url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/syllabus"),
                           text: "Grading\nProblem sets 50%, midterm 20%, final 30%.\nLate policy\nYou have three late days for the semester. After that, late work loses 10% per day and is not accepted after three days.\nTextbook\nBryant and O'Hallaron, Computer Systems: A Programmer's Perspective.",
                           fetchedAt: now),
            CourseDocument(courseID: "2", course: "ECON 1", kind: .syllabus, sourceID: "syllabus", title: "ECON 1 syllabus", url: nil,
                           text: "Late policy\nProblem sets are due Fridays at 5 PM. Late problem sets receive half credit within 24 hours and no credit after that.\nExams\nMidterm 1 is Thursday, October 1 at 7 PM in Meyerson B1.",
                           fetchedAt: now),
            CourseDocument(courseID: "1", course: "CIS 2400", kind: .announcement, sourceID: "a1", title: "Recitation moved this week",
                           url: URL(string: "https://canvas.upenn.edu/courses/1/discussion_topics/a1"),
                           text: "Posted: Mon, Sep 7 at 9:00 AM\nThis week's recitation moves to Thursday at 4 PM in Towne 313 because of the career fair.",
                           updatedAt: at(day: 7, hour: 9), fetchedAt: now),
            CourseDocument(courseID: "2", course: "ECON 1", kind: .announcement, sourceID: "a2", title: "Review session Sunday", url: nil,
                           text: "Posted: Fri, Sep 4 at 3:00 PM\nReview session for the first midterm is Sunday at 3 PM in Huntsman 245.",
                           updatedAt: at(day: 4, hour: 15), fetchedAt: now),
            CourseDocument(courseID: "1", course: "CIS 2400", kind: .assignment, sourceID: "2", title: "PSet 3: caches",
                           url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/2"),
                           text: "Due: Thu, Sep 10 at 11:59 PM\nPoints: 100\nStatus: not submitted\nImplement a direct-mapped cache simulator and answer the questions in the handout.",
                           fetchedAt: now, dueAt: at(day: 10), pointsPossible: 100, submitted: false),
            CourseDocument(courseID: "1", course: "CIS 2400", kind: .assignment, sourceID: "8", title: "PSet 1: warmup",
                           url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/8"),
                           text: "Due: Wed, Sep 2 at 11:59 PM\nPoints: 50\nStatus: submitted\nGet the toolchain working.",
                           fetchedAt: now, dueAt: at(day: 2), pointsPossible: 50, submitted: true),
        ], lastSyncedAt: now)
    }

    static var context: AskKnowledgeContext {
        AskKnowledgeContext(userName: "Olisa", now: now, calendar: calendar, items: items, knowledge: knowledge)
    }

    static func answer(_ question: String) -> AssistantAnswer {
        ClassQuestionAnswerer(context: context).answer(question)
    }
}

@Suite("Question parsing")
struct QuestionParserTests {
    private func parse(_ q: String) -> ParsedQuestion {
        QuestionParser.parse(q, courses: AssistantFixture.courses)
    }

    @Test("recognizes upcoming-work questions and their windows")
    func upcoming() {
        #expect(parse("What's due this week?").intent == .upcomingWork(window: .thisWeek, kind: .any))
        #expect(parse("anything due tomorrow").intent == .upcomingWork(window: .tomorrow, kind: .any))
        #expect(parse("what do I have due by friday").intent == .upcomingWork(window: .byWeekday(6), kind: .any))
        #expect(parse("what psets are due next week").intent == .upcomingWork(window: .nextWeek, kind: .assignment))
        #expect(parse("how many things are due today").intent == .howMany(window: .today, kind: .any))
    }

    @Test("recognizes next-exam and item-detail questions")
    func nextAndDetail() {
        #expect(parse("When is my next exam?").intent == .nextItem(kind: .exam))
        #expect(parse("when is the midterm").intent == .nextItem(kind: .exam))
        #expect(parse("next quiz?").intent == .nextItem(kind: .quiz))
        if case let .itemDetail(query) = parse("When is pset 3 due?").intent {
            #expect(query.contains("pset 3"))
        } else {
            Issue.record("expected itemDetail")
        }
    }

    @Test("recognizes submission, overdue, announcements, and course list")
    func others() {
        if case let .submissionStatus(query) = parse("Did I submit pset 1?").intent {
            #expect(query == "pset 1")
        } else {
            Issue.record("expected submissionStatus")
        }
        #expect(parse("what have I not submitted").intent == .submissionStatus(query: ""))
        #expect(parse("Anything overdue?").intent == .overdue)
        #expect(parse("Latest announcements").intent == .recentAnnouncements)
        #expect(parse("what did the professor say recently").intent == .recentAnnouncements)
        #expect(parse("What classes am I taking?").intent == .courseList)
        #expect(parse("hi").intent == .help)
    }

    @Test("falls back to lookup for policy questions and keeps the course")
    func lookup() {
        let parsed = parse("What's the late policy in CIS 2400?")
        #expect(parsed.intent == .lookup(query: "What's the late policy in CIS 2400?"))
        #expect(parsed.course?.code == "CIS 2400")
        #expect(parse("late policy for my econ class").course?.code == "ECON 1")
        #expect(parse("cis2400 textbook").course?.code == "CIS 2400")
        #expect(parse("what is the management late policy").course?.code == "MGMT 1010")
    }
}

@Suite("Class question answerer")
struct ClassQuestionAnswererTests {
    @Test("lists what's due this week, soonest first, skipping done and overdue")
    func dueThisWeek() {
        let answer = AssistantFixture.answer("What's due this week?")
        #expect(answer.isExact)
        #expect(answer.text.hasPrefix("4 things due in the next 7 days:"))
        #expect(answer.text.contains("1. ECON 1 · Weekly quiz 2"))
        #expect(answer.text.contains("2. CIS 2400 · PSet 3: caches"))
        #expect(answer.text.contains("4. MGMT 1010 · Group case writeup"))   // Tue 9 AM, inside 7 days
        #expect(answer.text.contains("Next up: Weekly quiz 2 (ECON 1), in 23 hours."))
        #expect(!answer.text.contains("PSet 1"))          // done
        #expect(!answer.text.contains("PSet 2"))          // overdue, not "upcoming"
        #expect(!answer.text.contains("Midterm"))         // weeks out
        #expect(!answer.text.contains("Reading response")) // no due date
    }

    @Test("scopes to a course when one is named")
    func dueForCourse() {
        let answer = AssistantFixture.answer("what's due this week for cis 2400")
        #expect(answer.text.hasPrefix("1 thing due in the next 7 days for CIS 2400:"))
        #expect(answer.text.contains("PSet 3: caches"))
    }

    @Test("says so when nothing is due, and points at overdue work")
    func nothingDue() {
        let answer = AssistantFixture.answer("anything due today?")
        #expect(answer.text.hasPrefix("Nothing due today."))
        #expect(answer.text.contains("1 overdue item"))
    }

    @Test("finds the next exam across courses")
    func nextExam() {
        let answer = AssistantFixture.answer("When is my next midterm?")
        #expect(answer.text.hasPrefix("Your next exam is Midterm 1 for CIS 2400: Wed, Sep 30 at 12:00 PM"))
        #expect(answer.text.contains("After that: Midterm 1 (ECON 1)"))
    }

    @Test("answers a specific item's due date with the Canvas description")
    func itemDetail() {
        let answer = AssistantFixture.answer("When is pset 3 due?")
        #expect(answer.text.hasPrefix("PSet 3: caches (CIS 2400) is due Thu, Sep 10 at 11:59 PM, in 3 days."))
        #expect(answer.text.contains("Canvas says: Implement a direct-mapped cache simulator"))
        #expect(answer.sources.first?.url?.absoluteString == "https://canvas.upenn.edu/courses/1/assignments/2")
    }

    @Test("never confuses pset 3 with pset 2")
    func numbersMustMatch() {
        let answer = AssistantFixture.answer("when is pset 2 due")
        #expect(answer.text.hasPrefix("PSet 2: bits and bytes (CIS 2400) is due Sun, Sep 6 at 11:59 PM, 1 day ago."))
    }

    @Test("reports submission status from Canvas data")
    func submission() {
        #expect(AssistantFixture.answer("Did I submit pset 1?").text.hasPrefix("Yes. Canvas shows PSet 1: warmup (CIS 2400) as submitted."))
        #expect(AssistantFixture.answer("have I turned in pset 3").text.hasPrefix("Not yet. Canvas shows PSet 3: caches (CIS 2400) as not submitted."))
        #expect(AssistantFixture.answer("what have I not submitted").text.hasPrefix("1 assignment not yet submitted:"))
    }

    @Test("lists overdue work oldest first")
    func overdue() {
        let answer = AssistantFixture.answer("Anything overdue?")
        #expect(answer.text.hasPrefix("1 overdue item:\n1. CIS 2400 · PSet 2: bits and bytes"))
        #expect(AssistantFixture.answer("am I behind in econ").text == "Nothing overdue for ECON 1. Nice.")
    }

    @Test("answers policy questions from the right course's syllabus")
    func latePolicy() {
        let cis = AssistantFixture.answer("What's the late policy in CIS 2400?")
        #expect(!cis.isExact)
        #expect(cis.text.hasPrefix("From the CIS 2400 syllabus \"CIS 2400 syllabus\":"))
        #expect(cis.text.contains("three late days"))
        #expect(cis.sources.first?.title == "CIS 2400 syllabus")
        #expect(!cis.grounding.isEmpty)

        let econ = AssistantFixture.answer("can I turn in problem sets late in econ")
        #expect(econ.text.contains("half credit"))
        #expect(!econ.text.contains("three late days"))
    }

    @Test("answers content questions by retrieval")
    func textbook() {
        let answer = AssistantFixture.answer("what textbook do we use for cis 2400")
        #expect(answer.text.contains("Bryant and O'Hallaron"))
    }

    @Test("surfaces the latest announcements, newest first")
    func announcements() {
        let answer = AssistantFixture.answer("Latest announcements")
        #expect(answer.text.hasPrefix("Latest announcements:\n1. CIS 2400 · Recitation moved this week"))
        #expect(answer.text.contains("2. ECON 1 · Review session Sunday"))
        #expect(answer.text.contains("Thursday at 4 PM"))
        #expect(answer.sources.count == 2)

        let scoped = AssistantFixture.answer("any announcements in econ?")
        #expect(scoped.text.hasPrefix("Latest announcements for ECON 1:"))
        #expect(!scoped.text.contains("Recitation"))
    }

    @Test("lists courses")
    func courses() {
        let answer = AssistantFixture.answer("What classes am I taking?")
        #expect(answer.text.hasPrefix("You're in 3 courses:"))
        #expect(answer.text.contains("1. CIS 2400 · CIS 2400 Introduction to Computer Systems"))
    }

    @Test("admits when the materials don't cover it")
    func unknown() {
        let answer = AssistantFixture.answer("what is the dress code for the gala")
        #expect(answer.text.hasPrefix("I couldn't find that in your course materials."))
        #expect(answer.sources.isEmpty)
    }

    @Test("works with no course materials at all")
    func calendarOnly() {
        let context = AskKnowledgeContext(userName: "", now: AssistantFixture.now, calendar: AssistantFixture.calendar, items: AssistantFixture.items, knowledge: .empty)
        let answerer = ClassQuestionAnswerer(context: context)
        #expect(answerer.answer("what's due this week").text.hasPrefix("4 things due"))
        #expect(answerer.answer("late policy").text.hasPrefix("I only have your calendar so far."))
        #expect(ClassQuestionAnswerer.suggestedQuestions(for: context).count == 4)
    }
}

@Suite("On-device model guardrails")
struct OnDeviceModelTests {
    @Test("prompt carries the draft and at most three passages")
    func prompt() {
        let answer = AssistantFixture.answer("What's the late policy in CIS 2400?")
        let prompt = OnDeviceLanguageModel.buildPrompt(question: "What's the late policy in CIS 2400?", answer: answer)
        #expect(prompt.contains("DRAFT ANSWER:"))
        #expect(prompt.contains("[1] CIS 2400 syllabus"))
        #expect(!prompt.contains("[4]"))
    }

    @Test("rejects rewrites that invent numbers")
    func validation() {
        let answer = AssistantFixture.answer("What's the late policy in CIS 2400?")
        #expect(OnDeviceLanguageModel.validated("You get three late days; after that work loses 10% per day.", against: answer) != nil)
        #expect(OnDeviceLanguageModel.validated("You get 5 late days.", against: answer) == nil)
        #expect(OnDeviceLanguageModel.validated("ok", against: answer) == nil)
    }

    @Test("exact answers are never sent to the model")
    func exactBypass() async {
        let answer = AssistantFixture.answer("What's due this week?")
        #expect(answer.isExact)
        #expect(await OnDeviceLanguageModel.compose(question: "What's due this week?", answer: answer) == nil)
    }
}
