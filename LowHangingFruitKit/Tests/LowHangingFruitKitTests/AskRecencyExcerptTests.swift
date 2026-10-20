import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A question about the newest posts is answered from the newest posts. On
/// 2026-10-20 "What have been the recent staff posts on Ed for my cis 2620
/// class" got the six posts whose words matched, Aug 28 to Oct 7, and not the
/// two newest on the phone (Oct 12 and Oct 18), whose text shared none of the
/// query's words; the model then said nothing newer existed. These tests drive
/// the same pure seam as `AskEdExcerptTests` (`excerptBlock`), so no network.
@Suite("RecencyIntent")
struct RecencyIntentTests {
    @Test("words that ask for the newest fire on their own, with no window")
    func recencyWordsAlone() {
        let questions = [
            "what are the recent posts", "anything posted recently", "what's the latest",
            "newest announcement", "any changes lately", "what's new in cis 2620", "whats new",
            "what\u{2019}s new on ed", "any news", "any updates", "are there new posts", "the most recent one",
        ]
        for question in questions {
            #expect(RecencyIntent.detect(in: question) == RecencyIntent(windowDays: nil), "\(question)")
        }
    }

    @Test("a time phrase fires only beside something that gets posted, and sets the window")
    func windowsNeedAPostingNoun() {
        let table: [(String, Int)] = [
            ("any announcements from today?", 1),
            ("what did the staff say yesterday", 2),
            ("what was posted this week", 7),
            ("any ed posts in the past week", 7),
            ("announcements last week", 7),
            ("posts from the past 7 days", 7),
            ("posts from the last 7 days", 7),
            ("what did they post the week before", 7),
            ("announcements in the past two weeks", 14),
            ("announcements in the last two weeks", 14),
            ("posts from the past 2 weeks", 14),
            ("posts from the last 2 weeks", 14),
            ("messages from the past 14 days", 14),
            ("updates this month", 30),
            ("announcements from the past month", 30),
            ("announcements from last month", 30),
            ("posts from the past 30 days", 30),
            ("past 10 days of announcements", 10),
            ("last 3 days of ed posts", 3),
        ]
        for (question, days) in table {
            #expect(RecencyIntent.detect(in: question) == RecencyIntent(windowDays: days), "\(question)")
        }
    }

    @Test("a posting noun with a recency word and no time phrase is the newest, no cut")
    func nounWithRecencyWord() {
        #expect(RecencyIntent.detect(in: "recent staff posts on ed") == RecencyIntent(windowDays: nil))
        #expect(RecencyIntent.detect(in: "latest announcement") == RecencyIntent(windowDays: nil))
    }

    @Test("a time phrase beats a recency word, and the phrase written last beats an earlier one")
    func windowWins() {
        let merged = "What have been the recent staff posts on Ed for my cis 2620 class What about in the past week"
        #expect(RecencyIntent.detect(in: merged) == RecencyIntent(windowDays: 7))
        #expect(RecencyIntent.detect(in: "posts from today and then the past month") == RecencyIntent(windowDays: 30))
    }

    @Test("deadline questions never fire")
    func negatives() {
        let questions = [
            "when is the next quiz", "what's due today", "what is due this week",
            "is there homework this week", "what is due yesterday", "when is the midterm",
            "what is the late policy", "", "how many assignments are due this month",
        ]
        for question in questions {
            #expect(RecencyIntent.detect(in: question) == nil, "\(question)")
        }
    }
}

@Suite("Ask excerpts: the newest posts first")
struct AskRecencyExcerptTests {
    private static let cis = CourseSummary(courseID: "1", code: "CIS 2620", name: "CIS 2620 Operating Systems", url: nil)
    private static let math = CourseSummary(courseID: "2", code: "MATH 1400", name: "MATH 1400 Calculus", url: nil)

    private static func eastern(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day; components.hour = hour
        return calendar.date(from: components)!
    }

    private static let asked = eastern(2026, 10, 20)

    /// An Ed document built the way ingestion builds it, so its header carries
    /// the `· posted yyyy-MM-dd` token that `shownPostedAt` reads.
    private static func ed(
        _ id: Int, title: String, body: String?, posted: Date,
        courseID: String = "1", course: String = "CIS 2620"
    ) -> CourseDocument {
        let thread = EdThread(
            id: id, userID: 7, courseID: 101, type: "announcement", title: title,
            document: body.map { "<document version=\"2.0\"><paragraph>\($0)</paragraph></document>" },
            category: "General", createdAt: posted, updatedAt: posted
        )
        let decision = EdThreadFilter.decide(thread, authorRole: nil)
        return CourseDocument(
            courseID: courseID, course: course, kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: EdDocumentBuilder.title(for: thread), url: nil,
            text: EdDocumentBuilder.text(for: thread, decision: decision), updatedAt: posted
        )
    }

    private static func imageOnlyEd(_ id: Int, title: String, posted: Date) -> CourseDocument {
        let thread = EdThread(
            id: id, userID: 7, courseID: 101, type: "announcement", title: title,
            document: "<document version=\"2.0\"><image src=\"https://static.edusercontent.com/files/x\" width=\"10\" height=\"10\"/></document>",
            category: "General", createdAt: posted, updatedAt: posted
        )
        return CourseDocument(
            courseID: "1", course: "CIS 2620", kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: title, url: nil,
            text: EdDocumentBuilder.text(for: thread, decision: EdThreadFilter.decide(thread, authorRole: nil)), updatedAt: posted
        )
    }

    // The bodies and titles deliberately avoid "staff", "post" and "recent":
    // none of these shares a word with the question, which is the whole bug.
    private static let aug26 = ed(1, title: "Welcome and logistics", body: "Lectures start in Towne 100 and recitations begin on Friday.", posted: eastern(2026, 8, 26))
    private static let aug28 = ed(2, title: "Setup reminder", body: "Please finish the environment setup before the first homework is released.", posted: eastern(2026, 8, 28))
    private static let sep3 = ed(3, title: "Homework 1 clarification", body: "Problem 2 allows any language that you like; the autograder accepts both.", posted: eastern(2026, 9, 3))
    private static let oct7 = ed(4, title: "Midterm review session", body: "A review session for the midterm meets Sunday in Towne 100.", posted: eastern(2026, 10, 7))
    private static let oct12 = ed(5, title: "Thanksgiving schedule", body: "Since it is right before Thanksgiving there is no quiz on Nov 23.", posted: eastern(2026, 10, 12))
    private static let oct18 = ed(6, title: "Project partners", body: "Partner assignments are final; swap requests close Monday.", posted: eastern(2026, 10, 18))

    /// Matches the question's words, and is not news.
    private static let distractor = CourseDocument(
        courseID: "1", course: "CIS 2620", kind: .page, sourceID: "p1", title: "Solutions schedule", url: nil,
        text: "The staff posts solutions on Fridays after the late deadline."
    )

    private static let allSix = [aug26, aug28, sep3, oct7, oct12, oct18]

    private static func context(_ documents: [CourseDocument], askedAt: Date = asked, previous: String? = nil) -> AssistantContext {
        AssistantContext(
            courseCodes: ["CIS 2620", "MATH 1400"],
            contextDocument: "the exact document text",
            askedAt: askedAt,
            knowledge: CourseKnowledgeBase(courses: [cis, math], documents: documents),
            previousQuestion: previous
        )
    }

    private static func lines(_ block: BackendAssistantResponder.ExcerptBlock) -> [String] {
        block.text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
    }

    private static let recentQuestion = "What have been the recent staff posts on Ed for my cis 2620 class"

    // MARK: - The reported question

    @Test("recent staff posts: the newest posts lead, newest first, ahead of the words that matched")
    func newestLead() throws {
        let block = BackendAssistantResponder.excerptBlock(
            question: Self.recentQuestion, context: Self.context(Self.allSix + [Self.distractor])
        )
        let lines = Self.lines(block)
        try #require(lines.count == 7)
        #expect(lines[0].hasPrefix("[1] ") && lines[0].contains("posted Oct 18") && lines[0].contains("\"Project partners\""))
        #expect(lines[1].hasPrefix("[2] ") && lines[1].contains("posted Oct 12") && lines[1].contains("\"Thanksgiving schedule\""))
        #expect(lines[2].contains("posted Oct 7"))
        #expect(lines[3].contains("posted Sep 3"))
        #expect(lines[4].contains("posted Aug 28"))
        #expect(lines[5].contains("posted Aug 26"))
        // The word match still rides along, after the picks.
        #expect(lines[6].contains("\"Solutions schedule\""))
        #expect(block.text.contains(BackendAssistantResponder.recencyExcerptNote))
        #expect(block.text.components(separatedBy: BackendAssistantResponder.recencyExcerptNote).count == 2)
        // The note sits in the header, under the Ed note, before the first excerpt.
        let all = block.text.components(separatedBy: "\n")
        #expect(all[1] == BackendAssistantResponder.edExcerptNote)
        #expect(all[2] == BackendAssistantResponder.recencyExcerptNote)
        #expect(all[3].hasPrefix("[1] "))
        // Sources follow the numbered lines.
        #expect(block.sources.map(\.title) == [
            "Project partners", "Thanksgiving schedule", "Midterm review session", "Homework 1 clarification",
            "Setup reminder", "Welcome and logistics", "Solutions schedule",
        ])
    }

    @Test("\"what about in the past week\" after that question keeps the course and cuts the window to 7 days")
    func followUpWindow() throws {
        let block = BackendAssistantResponder.excerptBlock(
            question: "What about in the past week",
            context: Self.context(Self.allSix + [Self.distractor], previous: Self.recentQuestion)
        )
        let lines = Self.lines(block)
        try #require(!lines.isEmpty)
        #expect(lines[0].contains("posted Oct 18"))
        // Oct 12 is 8 days old: not a pick, so at most BM25 brings it, behind the pick.
        if let index = lines.firstIndex(where: { $0.contains("posted Oct 12") }) {
            #expect(index > 0)
        }
        #expect(lines.filter { $0.contains("posted Oct 18") }.count == 1)
        #expect(block.text.contains(BackendAssistantResponder.recencyExcerptNote))
    }

    @Test("a window with nothing in it falls back to the three newest posts")
    func emptyWindow() throws {
        let block = BackendAssistantResponder.excerptBlock(
            question: "any announcements from today?", context: Self.context(Self.allSix)
        )
        let lines = Self.lines(block)
        try #require(lines.count >= 3)
        #expect(lines[0].contains("posted Oct 18"))
        #expect(lines[1].contains("posted Oct 12"))
        #expect(lines[2].contains("posted Oct 7"))
        #expect(block.text.contains(BackendAssistantResponder.recencyExcerptNote))
    }

    // MARK: - Scope

    @Test("a newer post in another course is not picked when the question names its course, and leads when it names none")
    func scope() throws {
        let other = Self.ed(50, title: "Quiz 3 moved", body: "The third quiz moves to Thursday.", posted: Self.eastern(2026, 10, 19), courseID: "2", course: "MATH 1400")
        let documents = Self.allSix + [other]

        let named = Self.lines(BackendAssistantResponder.excerptBlock(question: Self.recentQuestion, context: Self.context(documents)))
        try #require(!named.isEmpty)
        #expect(named[0].contains("posted Oct 18"))
        #expect(!named.contains { $0.contains("MATH 1400") })

        let unnamed = Self.lines(BackendAssistantResponder.excerptBlock(question: "what's new on ed", context: Self.context(documents)))
        try #require(unnamed.count >= 2)
        #expect(unnamed[0].contains("MATH 1400") && unnamed[0].contains("posted Oct 19"))
        #expect(unnamed[1].contains("posted Oct 18"))
    }

    // MARK: - Left alone

    @Test("a question that does not ask about recency gets exactly the search's excerpts and no note")
    func nonRecencyUnchanged() throws {
        let syllabus = CourseDocument(
            courseID: "1", course: "CIS 2620", kind: .syllabus, sourceID: "syllabus", title: "CIS 2620 syllabus", url: nil,
            text: "The midterm is on October 29 in class. The final exam is in December."
        )
        let documents = Self.allSix + [Self.distractor, syllabus]
        let question = "when is the midterm"
        let block = BackendAssistantResponder.excerptBlock(question: question, context: Self.context(documents))

        let expected = CourseSearch(knowledge: CourseKnowledgeBase(courses: [Self.cis, Self.math], documents: documents))
            .search(question, courseIDs: nil, limit: BackendAssistantResponder.excerptLimit, perDocument: BackendAssistantResponder.excerptsPerDocument)
            .filter { !$0.isTextlessEdPost }
        try #require(!expected.isEmpty)   // premise: the search finds something to compare with
        #expect(block.sources.map(\.documentID) == expected.map(\.document.id))
        #expect(!block.text.contains(BackendAssistantResponder.recencyExcerptNote))
    }

    // MARK: - What is never picked

    @Test("a picture-only Ed post and an undated announcement are never picked")
    func unusablePostsSkipped() throws {
        let picture = Self.imageOnlyEd(90, title: "Whiteboard photo", posted: Self.eastern(2026, 10, 19))
        let headerOnly = Self.ed(91, title: "Empty board note", body: nil, posted: Self.eastern(2026, 10, 19))
        let undated = CourseDocument(
            courseID: "1", course: "CIS 2620", kind: .announcement, sourceID: "a-undated", title: "Undated note", url: nil,
            text: "Office hours are in the lab.", updatedAt: nil
        )
        let block = BackendAssistantResponder.excerptBlock(
            question: Self.recentQuestion, context: Self.context(Self.allSix + [picture, headerOnly, undated])
        )
        let lines = Self.lines(block)
        try #require(!lines.isEmpty)
        #expect(lines[0].contains("posted Oct 18"))
        #expect(!lines.contains { $0.contains("Whiteboard photo") || $0.contains("Empty board note") })
        #expect(!lines.prefix(6).contains { $0.contains("Undated note") })
    }

    @Test("Canvas announcements are picked too, in date order with Ed posts")
    func announcementsMixIn() throws {
        let announcement = CourseDocument(
            courseID: "1", course: "CIS 2620", kind: .announcement, sourceID: "a1", title: "Exam room", url: nil,
            text: "The exam will be held in Towne 100.", updatedAt: Self.eastern(2026, 10, 15)
        )
        let block = BackendAssistantResponder.excerptBlock(
            question: "latest announcements for cis 2620", context: Self.context(Self.allSix + [announcement])
        )
        let lines = Self.lines(block)
        try #require(lines.count >= 3)
        #expect(lines[0].contains("posted Oct 18"))
        #expect(lines[1].contains("posted Oct 15") && lines[1].contains("· announcement ·"))
        #expect(lines[2].contains("posted Oct 12"))
    }
}
