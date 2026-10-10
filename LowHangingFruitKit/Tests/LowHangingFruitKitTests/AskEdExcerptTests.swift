import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// What the `excerpts` block says about Ed Discussion posts and Canvas
/// announcements: the date each was posted, the one line explaining what an
/// "ed discussion" excerpt is, and the rule that a post which is only a
/// picture never takes a slot. Driven through the same pure seam as
/// `AskExcerptChannelTests` (`retrievedExcerpts` / `makeRequest`), so no
/// network and no client.
@Suite("Ask excerpts: Ed posts and dates")
struct AskEdExcerptTests {
    private static let course = CourseSummary(courseID: "1", code: "CIS 2400", name: "CIS 2400 Introduction to Computer Systems", url: nil)

    /// A moment in America/New_York, where every verified school keeps time.
    private static func eastern(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    private static let asked = eastern(2026, 10, 10)

    /// An Ed document built the way ingestion builds it: the real builder for
    /// the text, the real filter for the reason.
    private static func ed(
        _ id: Int, title: String, body: String?, category: String? = "General",
        type: String = "announcement", pinned: Bool = false, posted: Date?
    ) -> CourseDocument {
        let thread = EdThread(
            id: id, userID: 7, courseID: 101, type: type, title: title,
            document: body.map { "<document version=\"2.0\"><paragraph>\($0)</paragraph></document>" },
            category: category, isPinned: pinned
        )
        let decision = EdThreadFilter.decide(thread, authorRole: nil)
        return CourseDocument(
            courseID: "1", course: "CIS 2400", kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: EdDocumentBuilder.title(for: thread), url: nil,
            text: EdDocumentBuilder.text(for: thread, decision: decision), updatedAt: posted
        )
    }

    private static func imageOnlyEd(_ id: Int, title: String, posted: Date?) -> CourseDocument {
        let thread = EdThread(
            id: id, userID: 7, courseID: 101, type: "announcement", title: title,
            document: "<document version=\"2.0\"><image src=\"https://static.edusercontent.com/files/x\" width=\"10\" height=\"10\"/></document>",
            category: title
        )
        return CourseDocument(
            courseID: "1", course: "CIS 2400", kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: title, url: nil,
            text: EdDocumentBuilder.text(for: thread, decision: EdThreadFilter.decide(thread, authorRole: nil)), updatedAt: posted
        )
    }

    private static func canvasAnnouncement(_ id: String, title: String, body: String, posted: Date?) -> CourseDocument {
        CourseDocument(courseID: "1", course: "CIS 2400", kind: .announcement, sourceID: id, title: title, url: nil, text: body, updatedAt: posted)
    }

    private static func syllabus(_ body: String, posted: Date? = nil) -> CourseDocument {
        CourseDocument(courseID: "1", course: "CIS 2400", kind: .syllabus, sourceID: "syllabus", title: "CIS 2400 syllabus", url: nil, text: body, updatedAt: posted)
    }

    private static func context(_ documents: [CourseDocument], askedAt: Date = asked, contextDocument: String = "the exact document text") -> AssistantContext {
        AssistantContext(
            courseCodes: ["CIS 2400"],
            contextDocument: contextDocument,
            askedAt: askedAt,
            knowledge: CourseKnowledgeBase(courses: [course], documents: documents)
        )
    }

    /// The numbered excerpt lines, without the header and the note.
    private static func lines(_ excerpts: String) -> [String] {
        excerpts.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
    }

    private static func line(containing needle: String, in excerpts: String) -> String? {
        lines(excerpts).first { $0.contains(needle) }
    }

    // MARK: - The posted date

    @Test("an Ed post and a Canvas announcement are labelled with the day they were posted")
    func postedDateOnEdAndAnnouncement() throws {
        // 10:30 PM on Oct 3 in Philadelphia is already Oct 4 in UTC; the label
        // must name the student's day.
        let documents = [
            Self.ed(1, title: "Midterm room change", body: "The zeppelin midterm moves to Towne 100.", posted: Self.eastern(2026, 10, 3, 22, 30)),
            Self.canvasAnnouncement("a1", title: "Office hours moved", body: "Zeppelin office hours move to Monday.", posted: Self.eastern(2026, 10, 5, 9)),
        ]
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))

        let edLine = try #require(Self.line(containing: "Midterm room change", in: excerpts))
        #expect(edLine.contains("CIS 2400 · ed discussion · posted Oct 3 · \"Midterm room change\": "))
        let announcementLine = try #require(Self.line(containing: "Office hours moved", in: excerpts))
        #expect(announcementLine.contains("CIS 2400 · announcement · posted Oct 5 · \"Office hours moved\": "))
    }

    @Test("a syllabus carries no posted date, even when it has an updated date")
    func syllabusIsNotDated() throws {
        let documents = [
            Self.syllabus("Zeppelin policy: late work loses ten percent per day.", posted: Self.eastern(2026, 9, 1)),
            Self.ed(1, title: "Reminder", body: "Zeppelin quiz Friday.", posted: Self.eastern(2026, 10, 3)),
        ]
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))
        let syllabusLine = try #require(Self.line(containing: "CIS 2400 syllabus", in: excerpts))
        #expect(!syllabusLine.contains("posted"))
        #expect(syllabusLine.hasPrefix("[") && syllabusLine.contains("CIS 2400 · syllabus · \"CIS 2400 syllabus\": "))
    }

    @Test("a post without a date gets no label rather than a made-up one")
    func undatedPostIsNotLabelled() throws {
        let documents = [Self.ed(1, title: "Undated", body: "Zeppelin note.", posted: nil)]
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))
        let edLine = try #require(Self.line(containing: "Undated", in: excerpts))
        #expect(!edLine.contains("posted"))
    }

    @Test("a post from another year than the question's shows the year")
    func otherYearShowsYear() throws {
        let documents = [
            Self.ed(1, title: "Last year", body: "Zeppelin schedule.", posted: Self.eastern(2025, 10, 3)),
            Self.ed(2, title: "This year", body: "Zeppelin schedule.", posted: Self.eastern(2026, 1, 15)),
        ]
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin schedule", context: Self.context(documents))
        let lastYear = try #require(Self.line(containing: "Last year", in: excerpts))
        #expect(lastYear.contains("posted Oct 3, 2025 · "))
        let thisYear = try #require(Self.line(containing: "This year", in: excerpts))
        #expect(thisYear.contains("posted Jan 15 · "))
        #expect(!thisYear.contains("2026"))
    }

    @Test("the label reads the question's moment, never the clock")
    func labelFollowsAskedAt() throws {
        let documents = [Self.ed(1, title: "Midterm", body: "Zeppelin midterm Friday.", posted: Self.eastern(2026, 10, 3))]
        let sameYear = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents, askedAt: Self.eastern(2026, 10, 10)))
        let earlierYear = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents, askedAt: Self.eastern(2025, 10, 10)))
        #expect(sameYear.contains("posted Oct 3 · "))
        // Asked "in 2025" about a post from 2026: the year is shown, which it
        // could not be if the label compared against today's date.
        #expect(earlierYear.contains("posted Oct 3, 2026 · "))
    }

    @Test("the same inputs give byte-identical output")
    func deterministic() {
        let documents = [
            Self.ed(1, title: "Midterm room change", body: "Zeppelin midterm moves.", posted: Self.eastern(2026, 10, 3)),
            Self.canvasAnnouncement("a1", title: "Office hours moved", body: "Zeppelin office hours.", posted: Self.eastern(2025, 12, 31, 23, 59)),
            Self.syllabus("Zeppelin policy."),
        ]
        let first = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))
        let second = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))
        #expect(!first.isEmpty)
        #expect(first == second)
    }

    // MARK: - The explanatory line

    @Test("the note about Ed excerpts sits directly under the header, once, when an Ed post is among them")
    func noteAppearsWithEdExcerpt() {
        let documents = [
            Self.ed(1, title: "Midterm room change", body: "Zeppelin midterm moves.", posted: Self.eastern(2026, 10, 3)),
            Self.ed(2, title: "Another", body: "Zeppelin quiz.", posted: Self.eastern(2026, 10, 4)),
        ]
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))
        let all = excerpts.components(separatedBy: "\n")
        #expect(all[0] == "RETRIEVED EXCERPTS (from the student's synced course materials):")
        #expect(all[1] == BackendAssistantResponder.edExcerptNote)
        #expect(all[1] == "Excerpts labelled \"ed discussion\" are posts by course staff on the class's Ed board, and carry the date they were posted.")
        #expect(excerpts.components(separatedBy: BackendAssistantResponder.edExcerptNote).count == 2)
        // The numbered lines are still just the excerpts.
        #expect(Self.lines(excerpts).count == 2)
        #expect(all[2].hasPrefix("[1] "))
    }

    @Test("the note is absent when no Ed post is among the excerpts")
    func noNoteWithoutEdExcerpt() {
        let documents = [
            Self.syllabus("Zeppelin policy: late work loses ten percent."),
            Self.canvasAnnouncement("a1", title: "Office hours moved", body: "Zeppelin office hours.", posted: Self.eastern(2026, 10, 5)),
        ]
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))
        #expect(!excerpts.contains(BackendAssistantResponder.edExcerptNote))
        #expect(!excerpts.contains("Ed board"))
        #expect(excerpts.components(separatedBy: "\n")[1].hasPrefix("[1] "))
    }

    // MARK: - The request around the excerpts

    @Test("the context document, the question and the history are untouched by Ed excerpts")
    func requestFieldsUnaffected() {
        let documents = [Self.ed(1, title: "Midterm room change", body: "Zeppelin midterm moves.", posted: Self.eastern(2026, 10, 3))]
        let context = Self.context(documents, contextDocument: "the cached prefix, byte for byte")
        let request = BackendAssistantResponder.makeRequest(question: "when is the zeppelin midterm?", context: context)
        #expect(request.contextDocument == "the cached prefix, byte for byte")
        #expect(request.question == "when is the zeppelin midterm?")
        #expect(request.history.isEmpty)
        #expect(request.askedAt == Self.asked)
        #expect(request.excerpts.contains("posted Oct 3"))
        #expect(!request.contextDocument.contains("posted"))
        #expect(!request.question.contains("RETRIEVED EXCERPTS"))
    }

    // MARK: - Image-only Ed posts

    /// Nine documents match "zeppelin schedule" and only eight ride along.
    /// The image-only post is the shortest and has the query in its title and
    /// category, so it ranks inside the eight; the premise is asserted before
    /// the behaviour so a ranking change fails loudly here instead of making
    /// the test vacuous.
    private static func crowdedKnowledge(extra: [CourseDocument]) -> [CourseDocument] {
        let pages = (0..<8).map { n in
            CourseDocument(
                courseID: "1", course: "CIS 2400", kind: .page, sourceID: "p\(n)", title: "Schedule page \(n)", url: nil,
                text: "The zeppelin schedule for section \(n) lists the readings, the labs, the quizzes and every other date students need to plan the term around."
            )
        }
        return pages + extra
    }

    @Test("an image-only Ed post is skipped and the next hit takes its place")
    func imageOnlyPostIsSkipped() {
        let picture = Self.imageOnlyEd(900, title: "zeppelin schedule", posted: Self.eastern(2026, 10, 3))
        let documents = Self.crowdedKnowledge(extra: [picture])

        let rawTop = CourseSearch(knowledge: CourseKnowledgeBase(courses: [Self.course], documents: documents))
            .search("zeppelin schedule", courseIDs: nil, limit: BackendAssistantResponder.excerptLimit, perDocument: BackendAssistantResponder.excerptsPerDocument)
        #expect(rawTop.count == 8)
        #expect(rawTop.contains { $0.document.id == picture.id })   // premise: it would have taken a slot

        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin schedule", context: Self.context(documents))
        let lines = Self.lines(excerpts)
        #expect(lines.count == 8)
        // All eight places went to the eight pages: the ninth match, the
        // picture, is the one left out, and with it goes the Ed note.
        #expect(lines.allSatisfy { $0.contains("· page ·") })
        #expect(!excerpts.contains(BackendAssistantResponder.edExcerptNote))
    }

    @Test("an Ed post with only a header is skipped too, and an Ed post with text is kept")
    func headerOnlySkippedTextKept() {
        let headerOnly = Self.ed(901, title: "zeppelin schedule", body: nil, category: "zeppelin schedule", posted: Self.eastern(2026, 10, 3))
        let withText = Self.ed(902, title: "zeppelin schedule", body: "Zeppelin schedule: the review is Sunday.", category: "zeppelin schedule", posted: Self.eastern(2026, 10, 4))
        let documents = Self.crowdedKnowledge(extra: [headerOnly, withText])

        let rawTop = CourseSearch(knowledge: CourseKnowledgeBase(courses: [Self.course], documents: documents))
            .search("zeppelin schedule", courseIDs: nil, limit: BackendAssistantResponder.excerptLimit, perDocument: BackendAssistantResponder.excerptsPerDocument)
        #expect(rawTop.contains { $0.document.id == headerOnly.id })   // premise: it would have taken a slot

        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin schedule", context: Self.context(documents))
        #expect(Self.lines(excerpts).count == 8)
        #expect(excerpts.contains("the review is Sunday"))
        let edLines = Self.lines(excerpts).filter { $0.contains("ed discussion") }
        #expect(edLines.count == 1)
        #expect(excerpts.components(separatedBy: "\n")[1] == BackendAssistantResponder.edExcerptNote)
    }

    @Test("when every match is an image-only Ed post there are no excerpts at all")
    func onlyImageOnlyMatches() {
        let documents = [
            Self.imageOnlyEd(910, title: "zeppelin schedule", posted: Self.eastern(2026, 10, 3)),
            Self.imageOnlyEd(911, title: "zeppelin quiz", posted: Self.eastern(2026, 10, 4)),
        ]
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: Self.context(documents))
        #expect(excerpts.isEmpty)
    }

    @Test("a question with no image-only match returns exactly what it always did")
    func nothingToSkipIsUnchanged() {
        let documents = Self.crowdedKnowledge(extra: [])
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin schedule", context: Self.context(documents))
        let direct = CourseSearch(knowledge: CourseKnowledgeBase(courses: [Self.course], documents: documents))
            .search("zeppelin schedule", courseIDs: nil, limit: BackendAssistantResponder.excerptLimit, perDocument: BackendAssistantResponder.excerptsPerDocument)
        #expect(Self.lines(excerpts).count == direct.count)
        for (index, hit) in direct.enumerated() {
            #expect(Self.lines(excerpts)[index].contains("\"\(hit.document.title)\""))
        }
    }
}
