import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Source chips that open their source. The on-device path takes the URL from
/// the document it answered from; the server path resolves the model's
/// `COURSE|kind|detail` against the documents that turn's excerpts came from,
/// and links only an unambiguous match. Everything here is pure: no network,
/// no view.
@Suite("Ask: source chips that open their source")
struct AskCitationLinkTests {
    private static let course = CourseSummary(courseID: "1", code: "CIS 2400", name: "CIS 2400 Introduction to Computer Systems", url: nil)

    private static func eastern(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour
        return calendar.date(from: c)!
    }

    private static func document(
        _ kind: CourseDocument.Kind, id: String, title: String, text: String, url: String?, course: String = "CIS 2400", courseID: String = "1"
    ) -> CourseDocument {
        CourseDocument(
            courseID: courseID, course: course, kind: kind, sourceID: id, title: title,
            url: url.flatMap { URL(string: $0) }, text: text, updatedAt: eastern(2026, 10, 3)
        )
    }

    private static let syllabusURL = "https://canvas.upenn.edu/courses/1/assignments/syllabus"
    private static let announcementURL = "https://canvas.upenn.edu/courses/1/discussion_topics/a1"
    private static let assignmentURL = "https://canvas.upenn.edu/courses/1/assignments/2"
    private static let edURL = "https://edstem.org/us/courses/9/discussion/101"
    private static let websiteURL = "https://www.cis.upenn.edu/~cis2400/schedule"

    private static var documents: [CourseDocument] {
        [
            document(.syllabus, id: "syllabus", title: "CIS 2400 syllabus", text: "Zeppelin policy: late work loses ten percent per day.", url: syllabusURL),
            document(.announcement, id: "a1", title: "Office hours moved", text: "Posted: Mon\nZeppelin office hours move to Monday.", url: announcementURL),
            document(.assignment, id: "2", title: "PSet 3: caches", text: "Zeppelin cache simulator. Implement a direct-mapped cache.", url: assignmentURL),
            document(.ed, id: "101", title: "Midterm room change", text: "[ed · announcement] General\nThe zeppelin midterm moves to Towne 100.", url: edURL),
            document(.website, id: "w1", title: "Course site schedule", text: "Zeppelin schedule: readings and labs for every week.", url: websiteURL),
        ]
    }

    private static func context(_ documents: [CourseDocument], contextDocument: String = "the exact document text") -> AssistantContext {
        AssistantContext(
            courseCodes: ["CIS 2400"],
            contextDocument: contextDocument,
            askedAt: eastern(2026, 10, 10),
            knowledge: CourseKnowledgeBase(courses: [course], documents: documents)
        )
    }

    /// The documents a turn's excerpts came from, as the responder keeps them.
    private static func sentSources(_ documents: [CourseDocument], question: String = "zeppelin") -> [ExcerptSource] {
        BackendAssistantResponder.prepareRequest(question: question, context: context(documents)).sources
    }

    private static func parse(_ raw: String) -> [AssistantCitation] {
        BackendAssistantResponder.SourcesBlockSplitter.parseCitations(raw)
    }

    // MARK: - On-device path

    @Test("an on-device citation carries the URL of the document it answered from")
    func onDeviceCitationCarriesTheHitsURL() {
        let context = AskKnowledgeContext(
            userName: "", now: AssistantFixture.now, calendar: AssistantFixture.calendar, items: [], knowledge: AssistantFixture.knowledge
        )
        let answer = ClassQuestionAnswerer(context: context).answer("what textbook do we use for cis 2400")
        #expect(answer.sources.first?.kind == "syllabus")
        let citations = OnDeviceAssistantResponder.citations(for: answer.sources)
        #expect(citations.first?.url == URL(string: "https://canvas.upenn.edu/courses/1/assignments/syllabus"))
        #expect(citations.first?.source == "syllabus")
        #expect(citations.first?.detail == "CIS 2400 syllabus")
    }

    @Test("an on-device citation has no link when the source has no URL or an unsafe one")
    func onDeviceCitationWithoutSafeURL() {
        func citation(_ url: String?) -> AssistantCitation? {
            let reference = SourceReference(title: "T", course: "CIS 2400", kind: "page", url: url.flatMap { URL(string: $0) })
            return OnDeviceAssistantResponder.citations(for: [reference]).first
        }
        #expect(citation(nil)?.url == nil)
        #expect(citation("http://canvas.upenn.edu/courses/1/pages/x")?.url == nil)
        #expect(citation("javascript:alert(1)")?.url == nil)
        #expect(citation("file:///etc/hosts")?.url == nil)
        #expect(citation("/courses/1/pages/x")?.url == nil)
        #expect(citation("https:///nohost")?.url == nil)
        #expect(citation("https://canvas.upenn.edu/courses/1/pages/x")?.url != nil)
        // The calendar grid is not the assignment's page (`Models/SourceLink.swift`).
        #expect(citation("https://canvas.upenn.edu/calendar?include_contexts=course_1&month=10&year=2026#assignment_2")?.url == nil)
    }

    // MARK: - Server path: the rule

    @Test("a server citation links when exactly one sent document matches course, kind and title")
    func serverCitationResolvesOnUniqueMatch() throws {
        let sources = Self.sentSources(Self.documents)
        #expect(sources.count == 5)   // premise: every document rode along
        let citations = Self.parse("""
        CIS 2400|syllabus|CIS 2400 syllabus; CIS 2400|announcement|Office hours moved; \
        CIS 2400|canvas|PSet 3: caches; CIS 2400|ed discussion|Midterm room change; \
        CIS 2400|website|Course site schedule
        """)
        #expect(citations.count == 5)
        let resolved = CitationLinks.resolve(citations, against: sources)
        #expect(resolved.map(\.url) == [Self.syllabusURL, Self.announcementURL, Self.assignmentURL, Self.edURL, Self.websiteURL].map { URL(string: $0) })
        // Nothing but the URL changed.
        #expect(resolved.map(\.course) == citations.map(\.course))
        #expect(resolved.map(\.source) == citations.map(\.source))
        #expect(resolved.map(\.detail) == citations.map(\.detail))
    }

    @Test("two sent documents with the same course, kind and title link nothing")
    func ambiguousTitleLinksNothing() {
        let documents = [
            Self.document(.announcement, id: "r1", title: "Reminder", text: "Zeppelin quiz Friday.", url: "https://canvas.upenn.edu/courses/1/discussion_topics/r1"),
            Self.document(.announcement, id: "r2", title: "Reminder", text: "Zeppelin quiz moved.", url: "https://canvas.upenn.edu/courses/1/discussion_topics/r2"),
        ]
        let sources = Self.sentSources(documents)
        #expect(Set(sources.map(\.documentID)).count == 2)   // premise: two distinct documents were sent
        let resolved = CitationLinks.resolve(Self.parse("CIS 2400|announcement|Reminder"), against: sources)
        #expect(resolved.first?.url == nil)
    }

    @Test("two passages of one document are one document, so the citation still links")
    func twoPassagesOfOneDocumentStillLink() {
        // Two paragraphs of 120 words each: the chunker cuts a passage at 160, so two passages.
        let filler = Array(repeating: "zeppelin", count: 120).joined(separator: " ")
        let document = Self.document(.syllabus, id: "syllabus", title: "CIS 2400 syllabus", text: filler + "\n" + filler, url: Self.syllabusURL)
        let sources = Self.sentSources([document])
        #expect(sources.count == 2)   // premise: two excerpts...
        #expect(Set(sources.map(\.documentID)).count == 1)   // ...from one document
        let resolved = CitationLinks.resolve(Self.parse("CIS 2400|syllabus|CIS 2400 syllabus"), against: sources)
        #expect(resolved.first?.url == URL(string: Self.syllabusURL))
    }

    @Test("a citation naming a document that was not in this turn's excerpts links nothing")
    func documentNotSentLinksNothing() {
        let sent = Self.document(.syllabus, id: "syllabus", title: "CIS 2400 syllabus", text: "Zeppelin policy.", url: Self.syllabusURL)
        let notSent = Self.document(.announcement, id: "a9", title: "Parking update", text: "The garage closes on Friday.", url: "https://canvas.upenn.edu/courses/1/discussion_topics/a9")
        let sources = Self.sentSources([sent, notSent])
        #expect(!sources.contains { $0.documentID == notSent.id })   // premise: it exists but was not sent
        let resolved = CitationLinks.resolve(Self.parse("CIS 2400|announcement|Parking update"), against: sources)
        #expect(resolved.first?.url == nil)
    }

    @Test("a matching document whose URL is http, or missing, links nothing")
    func unsafeURLLinksNothing() {
        for url in ["http://canvas.upenn.edu/courses/1/assignments/syllabus", nil] as [String?] {
            let document = Self.document(.syllabus, id: "syllabus", title: "CIS 2400 syllabus", text: "Zeppelin policy.", url: url)
            let sources = Self.sentSources([document])
            #expect(sources.count == 1)
            let resolved = CitationLinks.resolve(Self.parse("CIS 2400|syllabus|CIS 2400 syllabus"), against: sources)
            #expect(resolved.first?.url == nil)
        }
    }

    @Test("an empty turn, a missing detail, or an already-linked citation are left alone")
    func edgeCitations() {
        let sources = Self.sentSources(Self.documents)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|syllabus|CIS 2400 syllabus"), against: []).first?.url == nil)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|syllabus|"), against: sources).first?.url == nil)
        let already = AssistantCitation(course: "CIS 2400", source: "syllabus", detail: "CIS 2400 syllabus", url: URL(string: "https://example.com/mine"))
        #expect(CitationLinks.resolve([already], against: sources) == [already])
    }

    // MARK: - Server path: how tight "matches" is

    @Test("the model's usual detail, a place in the document, is not a title and links nothing")
    func locatingDetailIsNotATitle() {
        let sources = Self.sentSources(Self.documents)
        let resolved = CitationLinks.resolve(Self.parse("CIS 2400|syllabus|\u{a7}4 attendance, p.2; CIS 2400|announcement|aug 26"), against: sources)
        #expect(resolved.allSatisfy { $0.url == nil })
    }

    @Test("a different course, or a kind that does not name the document, links nothing")
    func courseAndKindMustMatch() {
        let sources = Self.sentSources(Self.documents)
        #expect(CitationLinks.resolve(Self.parse("ECON 1|syllabus|CIS 2400 syllabus"), against: sources).first?.url == nil)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|announcement|CIS 2400 syllabus"), against: sources).first?.url == nil)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|syllabus|Office hours moved"), against: sources).first?.url == nil)
        // "canvas" is the prompt's word for pages, assignments, modules and the course home, not the syllabus or an announcement.
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|canvas|CIS 2400 syllabus"), against: sources).first?.url == nil)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|canvas|Office hours moved"), against: sources).first?.url == nil)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|canvas|PSet 3: caches"), against: sources).first?.url == URL(string: Self.assignmentURL))
    }

    @Test("case, spacing, accents and the course's spelling are normalised; nothing else is")
    func normalisation() {
        let sources = Self.sentSources(Self.documents)
        let url = URL(string: Self.syllabusURL)
        #expect(CitationLinks.resolve(Self.parse("cis2400|Syllabus|  cis  2400   SYLLABUS "), against: sources).first?.url == url)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400-001|syllabus|CIS 2400 syllabus"), against: sources).first?.url == url)
        // The detail may contain the whole title, in words.
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|syllabus|the CIS 2400 syllabus, section 4"), against: sources).first?.url == url)
        // Punctuation is part of a title.
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|canvas|PSet 3 caches"), against: sources).first?.url == nil)
        // A title shared by a word is not a match, and neither is a part of it.
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|syllabus|CIS 2400"), against: sources).first?.url == nil)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|syllabus|CIS 2400 syllabuses"), against: sources).first?.url == nil)
        #expect(CitationLinks.resolve(Self.parse("CIS 2400|syllabus|pre-CIS 2400 syllabus"), against: sources).first?.url == url)
    }

    @Test("a title is found only as whole words inside a longer detail")
    func wholeWordsOnly() {
        #expect(CitationLinks.title("Quiz", matches: "Quiz 3 policy"))
        #expect(CitationLinks.title("Quiz", matches: "see the quiz"))
        #expect(!CitationLinks.title("Quiz", matches: "Quizzes"))
        #expect(!CitationLinks.title("Quiz", matches: "pop quiz3"))
        #expect(!CitationLinks.title("", matches: "anything"))
        #expect(CitationLinks.title("Caf\u{e9} hours", matches: "CAFE HOURS"))
    }

    // MARK: - The request and the transcript are unchanged

    /// Captured from the code before citations carried URLs, with this same
    /// input; the encoder is the one `BackendClient.askStream` uses.
    private static let goldenRequest = #"{"askedAt":"2026-10-10T16:00:00.000Z","contextDocument":"the exact document text","courseIDs":["1"],"excerpts":"RETRIEVED EXCERPTS (from the student's synced course materials):\nExcerpts labelled \"ed discussion\" are posts by course staff on the class's Ed board, and carry the date they were posted.\n[1] CIS 2400 · ed discussion · posted Oct 3 · \"Midterm room change\": [ed · announcement] General The zeppelin midterm moves to Towne 100.","history":[],"question":"when is the zeppelin midterm?"}"#

    @Test("the encoded request is byte-identical to what it was before citations carried links")
    func requestBytesUnchanged() throws {
        let ed = Self.document(.ed, id: "101", title: "Midterm room change", text: "[ed · announcement] General\nThe zeppelin midterm moves to Towne 100.", url: Self.edURL)
        let context = Self.context([ed])
        let request = BackendAssistantResponder.makeRequest(question: "when is the zeppelin midterm?", context: context)
        let data = try BackendJSON.encoder().encode(request)
        #expect(String(decoding: data, as: UTF8.self) == Self.goldenRequest)
        // The documents kept for linking never reach the request.
        #expect(!String(decoding: data, as: UTF8.self).contains("edstem.org"))
        #expect(request.history.isEmpty)
        #expect(request.question == "when is the zeppelin midterm?")
        #expect(request.contextDocument == "the exact document text")
        // `makeRequest` and `prepareRequest` are one retrieval, field for field.
        #expect(BackendAssistantResponder.prepareRequest(question: "when is the zeppelin midterm?", context: context).request == request)
    }

    @Test("the splitter still keeps the <sources> block off the transcript, in any chunking")
    func splitterStillHidesTheBlock() {
        let full = "The midterm is in Towne 100.\n<sources>CIS 2400|ed discussion|Midterm room change</sources>"
        for chunkSize in [1, 3, 7, full.count] {
            var splitter = BackendAssistantResponder.SourcesBlockSplitter()
            var visible = ""
            var rest = Substring(full)
            while !rest.isEmpty {
                let chunk = rest.prefix(chunkSize)
                visible += splitter.feed(String(chunk))
                rest = rest.dropFirst(chunk.count)
            }
            visible += splitter.finish()
            #expect(visible == "The midterm is in Towne 100.\n")
            #expect(!visible.contains("sources"))
            #expect(!visible.contains("Midterm room change"))
            // The splitter parses; it never links. Linking is a separate step.
            #expect(splitter.citations == [AssistantCitation(course: "CIS 2400", source: "ed discussion", detail: "Midterm room change")])
            #expect(splitter.citations.allSatisfy { $0.url == nil })
        }
    }

    @Test("a citation built without a URL is equal to one built with url: nil")
    func defaultURLIsNil() {
        #expect(AssistantCitation(course: "A", source: "b", detail: "c") == AssistantCitation(course: "A", source: "b", detail: "c", url: nil))
        #expect(AssistantCitation(course: "A", source: "b", detail: "c").id == AssistantCitation(course: "A", source: "b", detail: "c", url: URL(string: "https://example.com")).id)
    }
}
