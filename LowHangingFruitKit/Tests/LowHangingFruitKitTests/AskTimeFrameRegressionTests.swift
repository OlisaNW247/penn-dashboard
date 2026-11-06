import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The frozen regression set for the tree's time-frame work
/// (`docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`, Part 3 steps 1 and 2, measured
/// by Part 4): a pinned clock, no model, and assertions on structured outputs
/// only (the intent, the resolved local days, which passages are sent and in
/// what order, and Latest@8, "the newest relevant post is in the block").
///
/// The clock is 2026-11-02T18:12:00Z, which is Monday 13:12 in New York
/// (daylight saving ended the day before, so the offset is -05:00). Nothing
/// here reads the real clock.

// MARK: - Shared fixtures

enum TimeFrameFixture {
    static let newYork = TimeZone(identifier: "America/New_York")!

    /// Eastern wall-clock time, built the way `AskMeetingExcerptTests` does.
    static func eastern(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    /// The pinned moment of the research's recording day.
    static let pinned: Date = ISO8601DateFormatter().date(from: "2026-11-02T18:12:00Z")!

    static let cis = CourseSummary(courseID: "1", code: "CIS 2620", name: "CIS 2620 Operating Systems", url: nil)

    static func ed(_ id: Int, title: String, body: String, posted: Date) -> CourseDocument {
        let thread = EdThread(
            id: id, userID: 7, courseID: 101, type: "announcement", title: title,
            document: "<document version=\"2.0\"><paragraph>\(body)</paragraph></document>",
            category: "General", createdAt: posted, updatedAt: posted
        )
        let decision = EdThreadFilter.decide(thread, authorRole: nil)
        return CourseDocument(
            courseID: "1", course: "CIS 2620", kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: EdDocumentBuilder.title(for: thread), url: nil,
            text: EdDocumentBuilder.text(for: thread, decision: decision), updatedAt: posted
        )
    }

    /// What BM25 finds for a class-meeting question: the weekly schedule.
    static let schedule = CourseDocument(
        courseID: "1", course: "CIS 2620", kind: .page, sourceID: "sched", title: "Meeting times", url: nil,
        text: "The class meets Mondays and Wednesdays in Towne 100."
    )

    static let syllabus = CourseDocument(
        courseID: "1", course: "CIS 2620", kind: .syllabus, sourceID: "syl", title: "CIS 2620 syllabus", url: nil,
        text: "Late policy: homework submitted late loses ten percent per day. Attendance is not graded."
    )

    static func context(
        _ documents: [CourseDocument], askedAt: Date = pinned, previous: String? = nil
    ) -> AssistantContext {
        AssistantContext(
            courseCodes: ["CIS 2620"],
            contextDocument: "the exact document text",
            askedAt: askedAt,
            timeZone: newYork,
            knowledge: CourseKnowledgeBase(courses: [cis], documents: documents),
            previousQuestion: previous
        )
    }

    static func lines(_ block: BackendAssistantResponder.ExcerptBlock) -> [String] {
        block.text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
    }

    /// Latest@8: the newest relevant post is among the (at most eight) excerpts.
    static func latestAt8(_ block: BackendAssistantResponder.ExcerptBlock, _ post: CourseDocument) -> Bool {
        block.sources.prefix(8).contains { $0.documentID == post.id }
    }

    static func frame(_ question: String, now: Date = pinned, zone: TimeZone = newYork) -> AskTimeFrame {
        AskTimeFrame.resolve(question: question, now: now, timeZone: zone)
    }

    static func tag(_ frame: AskTimeFrame) -> String {
        switch frame {
        case .classMeeting: return "meeting"
        case .dueOn: return "due"
        case .recentNews: return "news"
        case .policy: return "policy"
        case .specific: return "specific"
        }
    }

    static func range(_ frame: AskTimeFrame) -> AskDayRange? {
        switch frame {
        case .classMeeting(let range): return range
        case .dueOn(let range): return range
        case .recentNews, .policy, .specific: return nil
        }
    }
}

// MARK: - Step 1: the resolver

@Suite("Ask time frame: the resolver")
struct AskTimeFrameResolverTests {
    typealias F = TimeFrameFixture

    @Test("the pinned clock is Monday 13:12 in New York")
    func pinnedClock() {
        #expect(F.pinned == F.eastern(2026, 11, 2, 13, 12))
    }

    /// (question, now, kind, first local day, last local day)
    private static let table: [(String, Date, String, String?, String?)] = [
        // Class meetings, from the pinned Monday.
        ("do I have class today", F.pinned, "meeting", "2026-11-02", "2026-11-02"),
        ("Do I not have cis 2620 class today?", F.pinned, "meeting", "2026-11-02", "2026-11-02"),
        ("is there class tomorrow", F.pinned, "meeting", "2026-11-03", "2026-11-03"),
        ("is there class tonight", F.pinned, "meeting", "2026-11-02", "2026-11-02"),
        ("do we have lab this week", F.pinned, "meeting", "2026-11-02", "2026-11-08"),
        ("is there lecture on thursday", F.pinned, "meeting", "2026-11-05", "2026-11-05"),
        ("is there class next week", F.pinned, "meeting", "2026-11-09", "2026-11-15"),
        ("is lecture cancelled", F.pinned, "meeting", nil, nil),
        ("when does cis 2400 lecture meet", F.pinned, "meeting", nil, nil),
        // Due-date questions: classified, with a range.
        ("what's due tomorrow", F.pinned, "due", "2026-11-03", "2026-11-03"),
        ("what's due today", F.pinned, "due", "2026-11-02", "2026-11-02"),
        ("anything due this week", F.pinned, "due", "2026-11-02", "2026-11-08"),
        ("what is due next week", F.pinned, "due", "2026-11-09", "2026-11-15"),
        ("homework due thursday", F.pinned, "due", "2026-11-05", "2026-11-05"),
        ("homework due monday", F.pinned, "due", "2026-11-02", "2026-11-02"),
        ("what was due yesterday", F.pinned, "due", "2026-11-01", "2026-11-01"),
        ("assignments due this weekend", F.pinned, "due", "2026-11-07", "2026-11-08"),
        ("is there homework this week", F.pinned, "due", "2026-11-02", "2026-11-08"),
        // Recent news: the existing kind, with its window.
        ("what's new in cis 2620", F.pinned, "news", nil, nil),
        ("what did staff post this week", F.pinned, "news", nil, nil),
        // Policy and specific.
        ("what is the late policy", F.pinned, "policy", nil, nil),
        ("when is the midterm", F.pinned, "policy", nil, nil),
        ("what is the class participation grade", F.pinned, "policy", nil, nil),
        ("what does the syllabus say about laptops", F.pinned, "policy", nil, nil),
        // Whole words only: these used to match exam, late and grade.
        ("can you give an example", F.pinned, "specific", nil, nil),
        ("I will ask later", F.pinned, "specific", nil, nil),
        ("how do I upgrade my laptop", F.pinned, "specific", nil, nil),
        // A change word beside a policy word wants the newest post.
        ("was the midterm moved?", F.pinned, "specific", nil, nil),
        ("is the final still on friday", F.pinned, "specific", nil, nil),
        ("what are the exams", F.pinned, "policy", nil, nil),
        ("when are office hours", F.pinned, "policy", nil, nil),
        ("who teaches cis 2400", F.pinned, "specific", nil, nil),
        ("what is due", F.pinned, "specific", nil, nil),
        ("how many assignments are due this month", F.pinned, "specific", nil, nil),
    ]

    @Test("every question in the table gets its intent and its local days")
    func classificationTable() {
        #expect(Self.table.count >= 25)
        for (question, now, kind, first, last) in Self.table {
            let frame = F.frame(question, now: now)
            #expect(F.tag(frame) == kind, "\(question): got \(frame)")
            #expect(F.range(frame)?.firstDay == first, "\(question): first day")
            #expect(F.range(frame)?.lastDay == last, "\(question): last day")
        }
    }

    @Test("a range is whole local days: midnight to midnight, end exclusive")
    func boundaries() throws {
        let week = try #require(F.range(F.frame("anything due this week")))
        #expect(week.start == F.eastern(2026, 11, 2, 0))
        #expect(week.end == F.eastern(2026, 11, 9, 0))
        let tomorrow = try #require(F.range(F.frame("what's due tomorrow")))
        #expect(tomorrow.start == F.eastern(2026, 11, 3, 0))
        #expect(tomorrow.end == F.eastern(2026, 11, 4, 0))
    }

    @Test("from a Sunday: this week is today alone, next week starts tomorrow")
    func fromASunday() {
        let sunday = F.eastern(2026, 11, 8, 12)
        let cases: [(String, String, String)] = [
            ("homework due this week", "2026-11-08", "2026-11-08"),
            ("homework due next week", "2026-11-09", "2026-11-15"),
            ("homework due this weekend", "2026-11-08", "2026-11-08"),
            ("homework due tomorrow", "2026-11-09", "2026-11-09"),
            ("homework due sunday", "2026-11-08", "2026-11-08"),
            ("homework due monday", "2026-11-09", "2026-11-09"),
            ("homework due saturday", "2026-11-14", "2026-11-14"),
        ]
        for (question, first, last) in cases {
            let range = F.range(F.frame(question, now: sunday))
            #expect(range?.firstDay == first, "\(question)")
            #expect(range?.lastDay == last, "\(question)")
        }
    }

    @Test("across a month boundary: Friday October 30 and Saturday October 31")
    func monthBoundary() {
        let friday = F.eastern(2026, 10, 30, 12)
        let fridayCases: [(String, String, String)] = [
            ("homework due tomorrow", "2026-10-31", "2026-10-31"),
            ("homework due this week", "2026-10-30", "2026-11-01"),
            ("homework due next week", "2026-11-02", "2026-11-08"),
            ("homework due monday", "2026-11-02", "2026-11-02"),
            ("homework due this weekend", "2026-10-31", "2026-11-01"),
        ]
        for (question, first, last) in fridayCases {
            let range = F.range(F.frame(question, now: friday))
            #expect(range?.firstDay == first, "\(question)")
            #expect(range?.lastDay == last, "\(question)")
        }
        let saturday = F.eastern(2026, 10, 31, 20)
        let tomorrow = F.range(F.frame("homework due tomorrow", now: saturday))
        #expect(tomorrow?.firstDay == "2026-11-01")
        let thisWeek = F.range(F.frame("homework due this week", now: saturday))
        #expect(thisWeek?.firstDay == "2026-10-31")
        #expect(thisWeek?.lastDay == "2026-11-01")
    }

    @Test("across a year boundary: Thursday December 31")
    func yearBoundary() {
        let thursday = F.eastern(2026, 12, 31, 12)
        #expect(F.range(F.frame("homework due tomorrow", now: thursday))?.firstDay == "2027-01-01")
        let week = F.range(F.frame("homework due this week", now: thursday))
        #expect(week?.firstDay == "2026-12-31")
        #expect(week?.lastDay == "2027-01-03")
        let next = F.range(F.frame("homework due next week", now: thursday))
        #expect(next?.firstDay == "2027-01-04")
        #expect(next?.lastDay == "2027-01-10")
    }

    @Test("a weekend that spans the end of daylight saving ends at the next local midnight")
    func daylightSavingWeekend() throws {
        let saturday = F.eastern(2026, 10, 31, 12)
        let range = try #require(F.range(F.frame("assignments due this weekend", now: saturday)))
        #expect(range.start == F.eastern(2026, 10, 31, 0))
        #expect(range.end == F.eastern(2026, 11, 2, 0))
        #expect(range.firstDay == "2026-10-31" && range.lastDay == "2026-11-01")
    }

    @Test("days are the student's, never UTC's: 21:30 Monday in New York is already Tuesday in UTC")
    func studentsZone() {
        let lateMonday = ISO8601DateFormatter().date(from: "2026-11-03T02:30:00Z")!
        let local = F.range(F.frame("is there class today", now: lateMonday, zone: F.newYork))
        #expect(local?.firstDay == "2026-11-02")
        let utc = F.range(F.frame("is there class today", now: lateMonday, zone: .gmt))
        #expect(utc?.firstDay == "2026-11-03")
    }

    @Test("past N days and last N days are N days back through today")
    func pastDays() {
        let past = F.range(F.frame("assignments due in the past 3 days"))
        #expect(past?.firstDay == "2026-10-30")
        #expect(past?.lastDay == "2026-11-02")
        let last = F.range(F.frame("homework due in the last 10 days"))
        #expect(last?.firstDay == "2026-10-23")
        #expect(last?.lastDay == "2026-11-02")
    }

    @Test("when two day phrases appear, the one written last wins")
    func lastPhraseWins() {
        #expect(F.range(F.frame("homework due monday or tomorrow"))?.firstDay == "2026-11-03")
        #expect(F.range(F.frame("homework due tomorrow or monday"))?.firstDay == "2026-11-02")
    }

    @Test("the resolver hands back exactly RecencyIntent's reading for every news and meeting question, and none for the rest")
    func recencyIntentIsPreserved() {
        let questions = [
            "what are the recent posts", "any announcements from today?", "what was posted this week",
            "posts from the past 7 days", "announcements in the past two weeks", "updates this month",
            "Do I not have cis 2620 class today?", "is there class tomorrow", "when does cis 2400 lecture meet",
            "what's due today", "when is the next quiz", "what is the late policy", "when is the midterm",
            "how many assignments are due this month", "", "what is due yesterday",
        ]
        for question in questions {
            #expect(F.frame(question).recencyIntent == RecencyIntent.detect(in: question), "\(question)")
        }
    }
}

// MARK: - Step 2: freshness in the search

@Suite("Ask time frame: freshness in scoring")
struct AskTimeFrameScoringTests {
    typealias F = TimeFrameFixture

    private static func search(_ documents: [CourseDocument]) -> CourseSearch {
        CourseSearch(knowledge: CourseKnowledgeBase(documents: documents), embeddingProvider: SentenceEmbeddingProvider { nil })
    }

    private static func notice(_ sourceID: String, posted: Date) -> CourseDocument {
        CourseDocument(
            courseID: "1", course: "CIS 2620", kind: .announcement, sourceID: sourceID, title: "Lecture notice", url: nil,
            text: "Lecture is cancelled and the lecture will not meet.", updatedAt: posted
        )
    }

    @Test("the decay is 1 when fresh, 0.75 at one half-life, and never below one half")
    func factorShape() {
        #expect(CourseSearch.freshnessFactor(ageDays: 0) == 1.0)
        #expect(abs(CourseSearch.freshnessFactor(ageDays: 4) - 0.75) < 1e-12)
        #expect(abs(CourseSearch.freshnessFactor(ageDays: 8) - 0.625) < 1e-12)
        #expect(CourseSearch.freshnessFactor(ageDays: 400) >= 0.5)
        #expect(CourseSearch.freshnessFactor(ageDays: 400) < 0.5001)
        // A post dated after the question (a clock skew) is simply fresh.
        #expect(CourseSearch.freshnessFactor(ageDays: -3) == 1.0)
    }

    @Test("an undated post weighs the half-life decay: below a fresh one, above a ten-day-old dated one")
    func undatedIsNeutral() throws {
        #expect(abs(CourseSearch.undatedFreshness - 0.75) < 1e-12)
        let undated = CourseDocument(
            courseID: "1", course: "CIS 2620", kind: .announcement, sourceID: "undated", title: "Lecture notice", url: nil,
            text: "Lecture is cancelled and the lecture will not meet."
        )
        let old = Self.notice("ten", posted: F.eastern(2026, 10, 23))
        let fresh = Self.notice("fresh", posted: F.pinned)
        let search = Self.search([undated, old, fresh])
        let hits = search.search("lecture cancelled", courseIDs: nil, limit: 5, perDocument: 2, intent: .classMeeting(nil), now: F.pinned)
        try #require(hits.count == 3)
        #expect(hits.map(\.document.id) == [fresh.id, undated.id, old.id])
        #expect(abs(hits[0].score / hits[1].score - 1 / 0.75) < 1e-9)
    }

    @Test("under a class-meeting or news intent the newer of two identical posts scores higher, by the factor")
    func newerOutranksOlder() throws {
        let older = Self.notice("old", posted: F.eastern(2026, 10, 20))
        let newer = Self.notice("new", posted: F.eastern(2026, 11, 1))
        let search = Self.search([older, newer])
        let intents: [AskTimeFrame] = [.classMeeting(nil), .recentNews(windowDays: 14)]
        for intent in intents {
            let hits = search.search("lecture cancelled", courseIDs: nil, limit: 5, perDocument: 2, intent: intent, now: F.pinned)
            try #require(hits.count == 2)
            #expect(hits[0].document.id == newer.id, "\(intent)")
            let ratio = CourseSearch.freshnessFactor(ageDays: F.pinned.timeIntervalSince(newer.updatedAt!) / 86_400)
                / CourseSearch.freshnessFactor(ageDays: F.pinned.timeIntervalSince(older.updatedAt!) / 86_400)
            #expect(abs(hits[0].score / hits[1].score - ratio) < 1e-9, "\(intent)")
        }
    }

    @Test("with no intent, or an intent that does not weigh freshness, post dates change nothing")
    func noDecayElsewhere() throws {
        let older = Self.notice("old", posted: F.eastern(2026, 10, 20))
        let newer = Self.notice("new", posted: F.eastern(2026, 11, 1))
        let search = Self.search([older, newer])
        let none = try #require(search.search("lecture cancelled", courseIDs: nil, limit: 5, perDocument: 2).map(\.score).first)
        let intents: [AskTimeFrame?] = [nil, .policy, .specific, .dueOn(F.range(F.frame("homework due tomorrow"))!)]
        for intent in intents {
            let hits = search.search("lecture cancelled", courseIDs: nil, limit: 5, perDocument: 2, intent: intent, now: F.pinned)
            try #require(hits.count == 2)
            #expect(abs(hits[0].score - hits[1].score) < 1e-9, "\(String(describing: intent))")
            #expect(abs(hits[0].score - none) < 1e-9, "\(String(describing: intent))")
        }
        // An intent without a `now` cannot decay either.
        let noClock = search.search("lecture cancelled", courseIDs: nil, limit: 5, perDocument: 2, intent: .classMeeting(nil), now: nil)
        #expect(abs(noClock[0].score - noClock[1].score) < 1e-9)
    }

    @Test("undated kinds are untouched by the decay")
    func undatedKindsUntouched() throws {
        let search = Self.search([F.schedule])
        let plain = try #require(search.search("class meets mondays", courseIDs: nil, limit: 3).first)
        let weighed = try #require(search.search("class meets mondays", courseIDs: nil, limit: 3, intent: .classMeeting(nil), now: F.pinned).first)
        #expect(abs(plain.score - weighed.score) < 1e-9)
    }

    @Test("a word that merely contains a policy word does not lift the syllabus")
    func syllabusBoostWholeWords() throws {
        let text = "For example, a later upgrade of the lab is optional."
        let syllabus = CourseDocument(courseID: "1", course: "CIS 2620", kind: .syllabus, sourceID: "s", title: "Syllabus", url: nil, text: text)
        let page = CourseDocument(courseID: "1", course: "CIS 2620", kind: .page, sourceID: "p", title: "Syllabus", url: nil, text: text)
        for query in ["example", "later upgrade"] {
            let boosted = try #require(Self.search([syllabus]).search(query, courseIDs: nil, limit: 3).first).score
            let neutral = try #require(Self.search([page]).search(query, courseIDs: nil, limit: 3).first).score
            #expect(abs(boosted / neutral - 1.1) < 1e-9, "\(query)")
        }
        #expect(CourseSearch.mentionsPolicyWord("what are the exams"))
        #expect(!CourseSearch.mentionsPolicyWord("an example, later, upgrade"))
    }

    @Test("a policy word lifts the syllabus to 1.5 for policy and specific, and stays at 1.35 for everything else")
    func syllabusBoost() throws {
        let search = Self.search([F.syllabus])
        let base = try #require(search.search("late policy", courseIDs: nil, limit: 3).first).score
        let policy = try #require(search.search("late policy", courseIDs: nil, limit: 3, intent: .policy, now: F.pinned).first).score
        let specific = try #require(search.search("late policy", courseIDs: nil, limit: 3, intent: .specific, now: F.pinned).first).score
        let meeting = try #require(search.search("late policy", courseIDs: nil, limit: 3, intent: .classMeeting(nil), now: F.pinned).first).score
        #expect(abs(policy / base - 1.5 / 1.35) < 1e-9)
        #expect(abs(specific / base - 1.5 / 1.35) < 1e-9)
        #expect(abs(meeting - base) < 1e-9)
    }

    @Test("a policy question's ranking and scores do not depend on when the unrelated posts were made")
    func policyRankingIgnoresPostDates() throws {
        func run(postedOn posted: Date) throws -> [(String, Double)] {
            let post = CourseDocument(
                courseID: "1", course: "CIS 2620", kind: .announcement, sourceID: "a1", title: "Reminder", url: nil,
                text: "Reminder: work that is late is still read by the graders.", updatedAt: posted
            )
            let hits = Self.search([F.syllabus, post]).search(
                "what is the late policy", courseIDs: nil, limit: 5, perDocument: 2,
                intent: F.frame("what is the late policy"), now: F.pinned
            )
            try #require(hits.count == 2)
            return hits.map { ($0.document.id, $0.score) }
        }
        let fresh = try run(postedOn: F.eastern(2026, 11, 2, 9))
        let stale = try run(postedOn: F.eastern(2026, 8, 1))
        #expect(fresh.map { $0.0 } == stale.map { $0.0 })
        for (a, b) in zip(fresh, stale) { #expect(abs(a.1 - b.1) < 1e-9) }
        #expect(fresh[0].0 == F.syllabus.id)
    }
}

// MARK: - Step 3: the frozen regression set, through the excerpt block

@Suite("Ask time frame: regression set")
struct AskTimeFrameRegressionTests {
    typealias F = TimeFrameFixture

    private static let question = "Do I not have cis 2620 class today?"

    @Test("schedule against a later cancellation: the cancellation is sent first and the schedule rides along")
    func scheduleVersusCancellation() throws {
        let post = F.ed(1, title: "No lectures this week but quiz on Monday", body: "Review the proofs from the recitation notes.", posted: F.eastern(2026, 11, 1))
        let block = BackendAssistantResponder.excerptBlock(question: Self.question, context: F.context([F.schedule, post]))
        let lines = F.lines(block)
        try #require(!lines.isEmpty)
        #expect(lines[0].contains("posted Nov 1") && lines[0].contains("No lectures this week"))
        #expect(F.latestAt8(block, post))
        #expect(block.text.contains(BackendAssistantResponder.meetingExcerptNote))
        if case .classMeeting(let range) = F.frame(Self.question) {
            #expect(range?.firstDay == "2026-11-02")
        } else {
            Issue.record("expected a class-meeting intent")
        }
    }

    @Test("schedule against a later room change: the change leads")
    func scheduleVersusRoomChange() throws {
        let post = F.ed(2, title: "Room change", body: "Lecture moves to Moore 216 starting this Wednesday.", posted: F.eastern(2026, 10, 30))
        let block = BackendAssistantResponder.excerptBlock(question: "where is cis 2620 lecture today", context: F.context([F.schedule, post]))
        let lines = F.lines(block)
        try #require(!lines.isEmpty)
        #expect(lines[0].contains("posted Oct 30") && lines[0].contains("Room change"))
        #expect(F.latestAt8(block, post))
    }

    @Test("an earlier cancellation does not outrank a newer \"we are back\": newest first")
    func staleCancellationVersusBackOn() throws {
        let cancelled = F.ed(3, title: "Lecture cancelled", body: "There is no lecture on Wednesday.", posted: F.eastern(2026, 10, 21))
        let back = F.ed(4, title: "Lecture is back on", body: "We are back in Towne 100 on Monday.", posted: F.eastern(2026, 10, 31))
        let block = BackendAssistantResponder.excerptBlock(question: "is there cis 2620 class today", context: F.context([F.schedule, cancelled, back]))
        let lines = F.lines(block)
        try #require(lines.count >= 2)
        #expect(lines[0].contains("Lecture is back on"))
        #expect(lines[1].contains("Lecture cancelled"))
        #expect(F.latestAt8(block, back))
    }

    @Test("the false premise: \"do I not have class today\" with a post from today saying class is on")
    func falsePremise() throws {
        let off = F.ed(5, title: "No class next Wednesday", body: "Lecture is cancelled next Wednesday.", posted: F.eastern(2026, 10, 28))
        let on = F.ed(6, title: "Class is on as usual", body: "We meet today in Towne 100 and the quiz is at the start.", posted: F.eastern(2026, 11, 2, 9))
        let block = BackendAssistantResponder.excerptBlock(question: Self.question, context: F.context([F.schedule, off, on]))
        let lines = F.lines(block)
        try #require(lines.count >= 2)
        #expect(lines[0].contains("posted Nov 2") && lines[0].contains("Class is on as usual"))
        #expect(lines[1].contains("posted Oct 28"))
        #expect(F.latestAt8(block, on))
    }

    @Test("a policy question with a fresh unrelated post: the syllabus leads and no newest-posts rule fires")
    func policyKeepsTheSyllabus() throws {
        let unrelated = F.ed(7, title: "Quiz on Monday", body: "Bring a pencil and review the proofs.", posted: F.eastern(2026, 11, 2, 9))
        let block = BackendAssistantResponder.excerptBlock(
            question: "what is the late policy for cis 2620", context: F.context([F.schedule, F.syllabus, unrelated])
        )
        let lines = F.lines(block)
        try #require(!lines.isEmpty)
        #expect(lines[0].contains("· syllabus ·"))
        #expect(!block.text.contains(BackendAssistantResponder.recencyExcerptNote))
        #expect(!block.text.contains(BackendAssistantResponder.meetingExcerptNote))
        if case .policy = F.frame("what is the late policy for cis 2620") {} else { Issue.record("expected policy") }
    }

    @Test("no recent post: the meeting note is sent, no old post is picked, and the rest is BM25 alone")
    func noRecentPost() {
        let old = F.ed(8, title: "Parking", body: "Parking permits are available at the garage.", posted: F.eastern(2026, 10, 5))
        let block = BackendAssistantResponder.excerptBlock(question: Self.question, context: F.context([F.schedule, old]))
        #expect(block.text.contains(BackendAssistantResponder.meetingExcerptNote))
        #expect(!F.lines(block).contains { $0.contains("Parking permits") })
        #expect(!block.sources.contains { $0.documentID == old.id })
        #expect(block.sources.first?.documentID == F.schedule.id)
    }

    @Test("a due-date question gets the excerpts a plain search gives, with no note, whatever the post dates")
    func dueQuestionIsUnchanged() throws {
        let freshPost = F.ed(9, title: "Homework 5", body: "Homework 5 is due tomorrow at noon.", posted: F.eastern(2026, 11, 2, 9))
        let oldPost = F.ed(10, title: "Homework 2", body: "Homework 2 is due tomorrow at noon.", posted: F.eastern(2026, 9, 1))
        let documents = [F.schedule, oldPost, freshPost]
        let question = "what homework is due tomorrow"
        let frame = F.frame(question)
        guard case .dueOn(let range) = frame else { Issue.record("expected due-on"); return }
        #expect(range.firstDay == "2026-11-03")
        #expect(frame.recencyIntent == nil)

        let block = BackendAssistantResponder.excerptBlock(question: question, context: F.context(documents))
        let plain = CourseSearch(knowledge: CourseKnowledgeBase(courses: [F.cis], documents: documents))
            .search(question, courseIDs: nil, limit: BackendAssistantResponder.excerptLimit, perDocument: BackendAssistantResponder.excerptsPerDocument)
            .filter { !$0.isTextlessEdPost }
        try #require(!plain.isEmpty)
        #expect(block.sources.map(\.documentID) == plain.map(\.document.id))
        #expect(!block.text.contains(BackendAssistantResponder.recencyExcerptNote))
        #expect(!block.text.contains(BackendAssistantResponder.meetingExcerptNote))
    }

    @Test("a news question: the newest post is in the block (Latest@8) among many older ones")
    func latestAtEightForNews() throws {
        var posts: [CourseDocument] = []
        for n in 0..<10 {
            posts.append(F.ed(100 + n, title: "Board note \(n)", body: "Reminder number \(n) about the project.", posted: F.eastern(2026, 10, 10 + n)))
        }
        let newest = F.ed(200, title: "Midterm room", body: "The midterm is in Towne 100.", posted: F.eastern(2026, 11, 1))
        let block = BackendAssistantResponder.excerptBlock(question: "what's new in cis 2620", context: F.context(posts + [newest, F.schedule]))
        #expect(F.latestAt8(block, newest))
        #expect(F.lines(block).first?.contains("Midterm room") == true)
        #expect(block.text.contains(BackendAssistantResponder.recencyExcerptNote))
    }

    @Test("a short follow-up is read with the question before it: \"and tomorrow?\" keeps the meeting rule")
    func followUpKeepsMeeting() throws {
        let post = F.ed(11, title: "No lectures this week", body: "Enjoy the break.", posted: F.eastern(2026, 11, 1))
        let block = BackendAssistantResponder.excerptBlock(
            question: "and tomorrow?", context: F.context([F.schedule, post], previous: Self.question)
        )
        #expect(block.text.contains(BackendAssistantResponder.meetingExcerptNote))
        #expect(F.lines(block).first?.contains("No lectures this week") == true)
        let merged = F.frame("\(Self.question) and tomorrow?")
        #expect(F.range(merged)?.firstDay == "2026-11-03")
    }

    @Test("across a month boundary: asked Friday October 30, a post from the 29th leads and tomorrow is the 31st")
    func monthBoundaryBlock() throws {
        let asked = F.eastern(2026, 10, 30, 12)
        let post = F.ed(12, title: "No section tomorrow", body: "Section is cancelled tomorrow.", posted: F.eastern(2026, 10, 29))
        let question = "is there cis 2620 class tomorrow"
        let block = BackendAssistantResponder.excerptBlock(question: question, context: F.context([F.schedule, post], askedAt: asked))
        #expect(F.lines(block).first?.contains("No section tomorrow") == true)
        #expect(F.latestAt8(block, post))
        #expect(F.range(F.frame(question, now: asked))?.firstDay == "2026-10-31")
    }

    @Test("from a Sunday: this week is Sunday alone and the post from Friday still leads")
    func sundayBlock() throws {
        let asked = F.eastern(2026, 11, 8, 12)
        let post = F.ed(13, title: "Lab is optional", body: "Lab attendance is optional this week.", posted: F.eastern(2026, 11, 6))
        let question = "do we have cis 2620 lab this week"
        let block = BackendAssistantResponder.excerptBlock(question: question, context: F.context([F.schedule, post], askedAt: asked))
        #expect(F.lines(block).first?.contains("Lab is optional") == true)
        #expect(F.latestAt8(block, post))
        let range = F.range(F.frame(question, now: asked))
        #expect(range?.firstDay == "2026-11-08")
        #expect(range?.lastDay == "2026-11-08")
    }

    @Test("an empty board and a meeting question still yield the note and no excerpts from posts")
    func emptyBoard() {
        let block = BackendAssistantResponder.excerptBlock(question: Self.question, context: F.context([F.schedule]))
        #expect(block.text.contains(BackendAssistantResponder.meetingExcerptNote))
        #expect(block.sources.allSatisfy { $0.documentID == F.schedule.id })
    }
}
