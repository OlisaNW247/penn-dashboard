import Foundation
import Testing
@testable import LowHangingFruitKit

/// "Latest announcements" on the on-device answerer, for a class whose
/// announcements live on Ed Discussion. The Ed documents here are built with
/// the real `EdDocumentBuilder` and `EdThreadFilter`, so the header the
/// answerer must strip is the header the app really writes.
@Suite("Latest announcements with Ed Discussion")
struct AskEdAnnouncementsTests {
    private static let cis = AssistantFixture.courses[0]
    private static let econ = AssistantFixture.courses[1]

    /// An Ed document for `course`, in the shape ingestion produces. `kind`
    /// picks which reason the filter gives it: an announcement, a pinned post,
    /// or a staff post.
    private enum EdKind { case announcement, pinned, staffPost }

    private static func ed(
        _ id: Int, _ kind: EdKind, course: CourseSummary = cis, title: String, body: String, posted: Date?
    ) -> CourseDocument {
        let thread: EdThread
        var role: String?
        switch kind {
        case .announcement:
            thread = EdThread(id: id, userID: 7, type: "announcement", title: title, document: Self.xml(body), category: "General")
        case .pinned:
            thread = EdThread(id: id, userID: 7, type: "post", title: title, document: Self.xml(body), category: "Logistics", subcategory: "Exams", isPinned: true)
        case .staffPost:
            thread = EdThread(id: id, userID: 7, type: "post", title: title, document: Self.xml(body), category: "Homework")
            role = "ta"
        }
        let decision = EdThreadFilter.decide(thread, authorRole: role)
        return CourseDocument(
            courseID: course.courseID, course: course.code, kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: EdDocumentBuilder.title(for: thread), url: URL(string: "https://edstem.org/us/courses/101/discussion/\(id)"),
            text: EdDocumentBuilder.text(for: thread, decision: decision), updatedAt: posted, fetchedAt: AssistantFixture.now
        )
    }

    private static func xml(_ paragraphs: String...) -> String {
        "<document version=\"2.0\">" + paragraphs.map { "<paragraph>\($0)</paragraph>" }.joined() + "</document>"
    }

    private static func canvas(_ id: String, course: CourseSummary = cis, title: String, body: String, posted: Date?) -> CourseDocument {
        CourseDocument(
            courseID: course.courseID, course: course.code, kind: .announcement, sourceID: id, title: title,
            url: URL(string: "https://canvas.upenn.edu/courses/\(course.courseID)/discussion_topics/\(id)"),
            text: "Posted: whenever\n" + body, updatedAt: posted, fetchedAt: AssistantFixture.now
        )
    }

    private static func syllabus(_ course: CourseSummary = cis) -> CourseDocument {
        CourseDocument(courseID: course.courseID, course: course.code, kind: .syllabus, sourceID: "syllabus", title: "\(course.code) syllabus", url: nil,
                       text: "Grading\nProblem sets 50 percent.", fetchedAt: AssistantFixture.now)
    }

    private static func context(_ documents: [CourseDocument]) -> AskKnowledgeContext {
        AskKnowledgeContext(
            userName: "", now: AssistantFixture.now, calendar: AssistantFixture.calendar, items: [],
            knowledge: CourseKnowledgeBase(courses: AssistantFixture.courses, documents: documents, lastSyncedAt: AssistantFixture.now)
        )
    }

    private static func answer(_ question: String, _ documents: [CourseDocument]) -> AssistantAnswer {
        ClassQuestionAnswerer(context: context(documents)).answer(question)
    }

    private static func position(of needle: String, in text: String) -> Int? {
        text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }

    // MARK: - The chip

    @Test("a class with only Ed announcements shows the Latest announcements chip")
    func edOnlyClassShowsChip() {
        let announcement = Self.context([Self.ed(1, .announcement, title: "Exam logistics", body: "Room is Towne 100.", posted: AssistantFixture.at(day: 3, hour: 9))])
        #expect(ClassQuestionAnswerer.suggestedQuestions(for: announcement).contains("Latest announcements"))

        let pinned = Self.context([Self.ed(2, .pinned, title: "FAQ", body: "Read this first.", posted: AssistantFixture.at(day: 3, hour: 9))])
        #expect(ClassQuestionAnswerer.suggestedQuestions(for: pinned).contains("Latest announcements"))
    }

    @Test("a class whose Ed material is only plain staff posts does not")
    func staffPostsOnlyHideChip() {
        let context = Self.context([
            Self.ed(3, .staffPost, title: "Homework hint", body: "Start with the cache.", posted: AssistantFixture.at(day: 3, hour: 9)),
            Self.syllabus(),
        ])
        #expect(!ClassQuestionAnswerer.suggestedQuestions(for: context).contains("Latest announcements"))
    }

    // MARK: - The answer

    @Test("an Ed-only class lists its announcement and pinned post newest first, dated, with no header text")
    func edOnlyClassListsAnnouncementsAndPinned() {
        let documents = [
            Self.ed(1, .announcement, title: "Exam logistics", body: "Room is Towne 100.", posted: AssistantFixture.at(day: 3, hour: 9)),
            Self.ed(2, .pinned, title: "Course FAQ", body: "Office hours are on the board.", posted: AssistantFixture.at(day: 7, hour: 14)),
            Self.ed(3, .staffPost, title: "Homework hint", body: "Start with the cache.", posted: AssistantFixture.at(day: 8, hour: 8)),
        ]
        let answer = Self.answer("Latest announcements", documents)
        let text = answer.text

        #expect(text.hasPrefix("Latest announcements:\n1. CIS 2400 · Course FAQ (Monday, Sep 7): Office hours are on the board."))
        #expect(text.contains("2. CIS 2400 · Exam logistics (Thursday, Sep 3): Room is Towne 100."))
        // The staff post is neither an announcement nor pinned, even though it
        // is the newest thing on the board.
        #expect(!text.contains("Homework hint"))
        #expect(!text.contains("Start with the cache"))
        #expect(!text.contains("[ed ·"))
        #expect(!text.contains("Logistics / Exams"))
        #expect(!text.contains("No announcements"))

        #expect(answer.sources.count == 2)
        #expect(answer.sources.allSatisfy { $0.kind == "ed discussion" })
        #expect(answer.grounding.count == 2)
        #expect(answer.grounding.allSatisfy { !$0.passage.text.contains("[ed ·") })
        #expect(answer.grounding.first?.passage.text == "Office hours are on the board.")
    }

    @Test("a line of an Ed post that starts with 'Due:' is kept, not filtered like a Canvas header line")
    func dueLineOfEdPostIsKept() {
        let pinned = Self.ed(1, .pinned, title: "Project 2", body: "Due: Friday at 5 PM on Gradescope", posted: AssistantFixture.at(day: 7, hour: 14))
        let text = Self.answer("Latest announcements", [pinned]).text
        #expect(text.contains("Project 2 (Monday, Sep 7): Due: Friday at 5 PM on Gradescope"))
    }

    @Test("a class with Canvas and Ed announcements interleaves them by date")
    func interleavesByDate() throws {
        let documents = [
            Self.canvas("c1", title: "Canvas newest", body: "Canvas one.", posted: AssistantFixture.at(day: 7, hour: 9)),
            Self.ed(1, .announcement, title: "Ed second", body: "Ed one.", posted: AssistantFixture.at(day: 6, hour: 9)),
            Self.canvas("c2", title: "Canvas third", body: "Canvas two.", posted: AssistantFixture.at(day: 5, hour: 9)),
            Self.ed(2, .pinned, title: "Ed oldest", body: "Ed two.", posted: AssistantFixture.at(day: 4, hour: 9)),
        ]
        let text = Self.answer("Latest announcements", documents).text
        let first = try #require(Self.position(of: "1. CIS 2400 · Canvas newest", in: text))
        let second = try #require(Self.position(of: "2. CIS 2400 · Ed second", in: text))
        let third = try #require(Self.position(of: "3. CIS 2400 · Canvas third", in: text))
        #expect(first < second && second < third)
        // The list is the three newest, as it always was.
        #expect(!text.contains("Ed oldest"))
        #expect(text.contains("Ed second (Sunday, Sep 6)"))
    }

    @Test("a scoped question lists only that course's Ed announcements")
    func scopedToOneCourse() {
        let documents = [
            Self.ed(1, .announcement, course: Self.cis, title: "CIS note", body: "About CIS.", posted: AssistantFixture.at(day: 7, hour: 9)),
            Self.ed(2, .announcement, course: Self.econ, title: "ECON note", body: "About ECON.", posted: AssistantFixture.at(day: 6, hour: 9)),
        ]
        let text = Self.answer("any announcements in econ?", documents).text
        #expect(text.hasPrefix("Latest announcements for ECON 1:"))
        #expect(text.contains("ECON note"))
        #expect(!text.contains("CIS note"))
    }

    @Test("a class with neither still says there are none")
    func neitherSaysNone() {
        let documents = [
            Self.syllabus(),
            Self.ed(3, .staffPost, title: "Homework hint", body: "Start with the cache.", posted: AssistantFixture.at(day: 8, hour: 8)),
            Self.canvas("c9", course: Self.econ, title: "ECON news", body: "Review Sunday.", posted: AssistantFixture.at(day: 4, hour: 9)),
        ]
        // CIS has a staff post and a syllabus but no announcement of either kind.
        let scoped = Self.answer("any announcements in cis 2400?", documents)
        #expect(scoped.text == "No announcements for CIS 2400 yet.")
        #expect(scoped.sources.isEmpty)

        // With nothing synced at all, say that and nothing else.
        let empty = ClassQuestionAnswerer(context: AskKnowledgeContext(
            userName: "", now: AssistantFixture.now, calendar: AssistantFixture.calendar, items: [], knowledge: .empty
        )).answer("Latest announcements")
        #expect(empty.text == "Nothing synced yet.")
    }
}
