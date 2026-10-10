import Foundation
import Testing
@testable import LowHangingFruitKit

/// The on-device answerer's `lookup` and its "next exam" fallback read Ed
/// posts through `CourseSearch` like any other document. Before this, an
/// Ed passage went into the answer with the builder's `[ed · reason]
/// category` line glued onto its first sentence, and a post that is only a
/// picture could be the best hit and the whole answer. Documents here are
/// built with the real `EdDocumentBuilder` and `EdThreadFilter`.
@Suite("On-device answers from Ed posts")
struct AskEdLookupTests {
    private static let course = AssistantFixture.courses[0]

    private static func ed(_ id: Int, title: String, body: String?, category: String? = "General", pinned: Bool = false, type: String = "announcement") -> CourseDocument {
        let thread = EdThread(
            id: id, userID: 7, courseID: 101, type: type, title: title,
            document: body.map { "<document version=\"2.0\"><paragraph>\($0)</paragraph></document>" },
            category: category, isPinned: pinned
        )
        return CourseDocument(
            courseID: course.courseID, course: course.code, kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: EdDocumentBuilder.title(for: thread), url: URL(string: "https://edstem.org/us/courses/101/discussion/\(id)"),
            text: EdDocumentBuilder.text(for: thread, decision: EdThreadFilter.decide(thread, authorRole: nil)),
            updatedAt: AssistantFixture.at(day: 4, hour: 9), fetchedAt: AssistantFixture.now
        )
    }

    private static func imageOnlyEd(_ id: Int, title: String) -> CourseDocument {
        let thread = EdThread(
            id: id, userID: 7, courseID: 101, type: "announcement", title: title,
            document: "<document version=\"2.0\"><image src=\"https://static.edusercontent.com/files/x\" width=\"10\" height=\"10\"/></document>",
            category: title
        )
        return CourseDocument(
            courseID: course.courseID, course: course.code, kind: .ed, sourceID: EdDocumentBuilder.sourceID(for: thread),
            title: title, url: nil,
            text: EdDocumentBuilder.text(for: thread, decision: EdThreadFilter.decide(thread, authorRole: nil)),
            updatedAt: AssistantFixture.at(day: 4, hour: 9), fetchedAt: AssistantFixture.now
        )
    }

    private static func page(_ id: String, title: String, text: String) -> CourseDocument {
        CourseDocument(courseID: course.courseID, course: course.code, kind: .page, sourceID: id, title: title, url: nil, text: text, fetchedAt: AssistantFixture.now)
    }

    private static func answerer(_ documents: [CourseDocument]) -> ClassQuestionAnswerer {
        ClassQuestionAnswerer(context: AskKnowledgeContext(
            userName: "", now: AssistantFixture.now, calendar: AssistantFixture.calendar, items: [],
            knowledge: CourseKnowledgeBase(courses: AssistantFixture.courses, documents: documents, lastSyncedAt: AssistantFixture.now)
        ))
    }

    // MARK: - The header

    @Test("a lookup shows an Ed post without its header line, for the best hit and the second")
    func lookupStripsTheHeader() throws {
        let documents = [
            Self.ed(1, title: "Zeppelin review session", body: "The zeppelin review session is Sunday at 3 PM in Huntsman 245.", category: "Logistics", pinned: true, type: "post"),
            Self.ed(2, title: "Zeppelin office hours", body: "Zeppelin review office hours move to Monday in Towne 313."),
        ]
        let question = "tell me about the zeppelin review"
        #expect(QuestionParser.parse(question, courses: AssistantFixture.courses).intent == .lookup(query: question))
        let answer = Self.answerer(documents).answer(question)

        #expect(answer.text.hasPrefix("From the CIS 2400 ed discussion \""))
        #expect(answer.text.contains("Huntsman 245") || answer.text.contains("Towne 313"))
        #expect(answer.text.contains("Also, the CIS 2400 ed discussion"))
        #expect(!answer.text.contains("[ed ·"))
        #expect(!answer.text.contains("Logistics"))
        // What the on-device model is given to rephrase from is clean too.
        #expect(!answer.grounding.isEmpty)
        #expect(answer.grounding.allSatisfy { !$0.passage.text.contains("[ed ·") })
        #expect(answer.sources.count == 2)
    }

    @Test("the next-exam fallback shows an Ed post without its header line")
    func nextItemFallbackStripsTheHeader() {
        let documents = [Self.ed(1, title: "Exam logistics", body: "Midterm 1 is Friday, October 16 at 7 PM in Towne 100.", category: "Exams", pinned: true, type: "post")]
        let question = "when is my next midterm?"
        #expect(QuestionParser.parse(question, courses: AssistantFixture.courses).intent == .nextItem(kind: .exam))
        let answer = Self.answerer(documents).answer(question)

        #expect(answer.text.hasPrefix("I don't see a dated exam on your calendar yet. Here's what the CIS 2400 ed discussion says:\n"))
        #expect(answer.text.contains("Towne 100"))
        #expect(!answer.text.contains("[ed ·"))
        #expect(!answer.text.contains("pinned"))
        #expect(answer.grounding.allSatisfy { !$0.passage.text.contains("[ed ·") })
    }

    @Test("a document that is not from Ed passes through the lookup untouched")
    func otherKindsAreUntouched() {
        let answer = Self.answerer(AssistantFixture.knowledge.documents).answer("what textbook do we use for cis 2400")
        #expect(answer.text.contains("Bryant and O'Hallaron"))
        #expect(answer.grounding.contains { $0.passage.text.hasPrefix("Grading") })
    }

    // MARK: - Image-only posts

    /// The raw ranking, to prove the picture would otherwise have been the
    /// best hit, so these tests cannot pass vacuously if ranking changes.
    private static func rawTop(_ documents: [CourseDocument], query: String) -> [SearchHit] {
        CourseSearch(knowledge: CourseKnowledgeBase(courses: AssistantFixture.courses, documents: documents))
            .search(query, courseIDs: nil, limit: 4)
    }

    @Test("a lookup skips an image-only Ed post and answers from the next hit")
    func lookupSkipsImageOnlyPost() {
        let picture = Self.imageOnlyEd(900, title: "zeppelin review")
        let syllabusPage = Self.page("p1", title: "Course schedule", text: "The zeppelin review for the final exam is held in the last week of class, in Towne 100, with every TA present.")
        let documents = [picture, syllabusPage]
        let question = "tell me about the zeppelin review"
        #expect(Self.rawTop(documents, query: question).first?.document.id == picture.id)   // premise

        let answer = Self.answerer(documents).answer(question)
        #expect(answer.text.contains("Towne 100"))
        #expect(!answer.text.contains("[image]"))
        #expect(!answer.text.contains("ed discussion"))
        #expect(answer.sources.map(\.title) == ["Course schedule"])
        #expect(answer.grounding.allSatisfy { $0.document.kind != .ed })
    }

    @Test("an Ed post with only a header is skipped too")
    func lookupSkipsHeaderOnlyPost() {
        let headerOnly = Self.ed(901, title: "zeppelin review", body: nil, category: "zeppelin review")
        let syllabusPage = Self.page("p1", title: "Course schedule", text: "The zeppelin review for the final exam is held in the last week of class, in Towne 100.")
        let question = "tell me about the zeppelin review"
        #expect(Self.rawTop([headerOnly, syllabusPage], query: question).first?.document.id == headerOnly.id)   // premise

        let answer = Self.answerer([headerOnly, syllabusPage]).answer(question)
        #expect(answer.text.contains("Towne 100"))
        #expect(answer.sources.map(\.title) == ["Course schedule"])
    }

    @Test("when the only match is an image-only Ed post, the answer is 'Couldn't find that.'")
    func onlyImageOnlyMatch() {
        let picture = Self.imageOnlyEd(900, title: "zeppelin review")
        let question = "tell me about the zeppelin review"
        #expect(Self.rawTop([picture], query: question).first?.document.id == picture.id)   // premise
        let answer = Self.answerer([picture]).answer(question)
        #expect(answer.text == "Couldn't find that.")
        #expect(answer.sources.isEmpty)
    }

    @Test("the next-exam fallback skips an image-only Ed post and answers from the next hit")
    func nextItemFallbackSkipsImageOnlyPost() {
        let picture = Self.imageOnlyEd(900, title: "midterm exam date schedule")
        let syllabusPage = Self.page("p1", title: "Exam dates", text: "Midterm 1 is Friday, October 16 at 7 PM in Towne 100, and the final exam is in December.")
        let question = "when is my next midterm?"
        #expect(Self.rawTop([picture, syllabusPage], query: "exam date schedule \(question)").first?.document.id == picture.id)   // premise

        let answer = Self.answerer([picture, syllabusPage]).answer(question)
        #expect(answer.text.hasPrefix("I don't see a dated exam on your calendar yet. Here's what the CIS 2400 page says:\n"))
        #expect(answer.text.contains("Towne 100"))
        #expect(!answer.text.contains("[image]"))
        #expect(answer.sources.map(\.title) == ["Exam dates"])
    }
}
