import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The size of the `excerpts` field `ask` sends with a question, and the
/// guarantee that remembering the previous question (to follow a follow-up
/// into the right course) changes nothing on the wire. Driven through the
/// same pure seam as the rest of `BackendAssistantResponderTests`
/// (`makeRequest` / `retrievedExcerpts`), so no network and no client.
///
/// Passages here are built from words of one fixed width so their length in
/// characters is known exactly, and a single paragraph under the chunker's
/// 160-word target so each stays one passage.
@Suite("Ask excerpt channel")
struct AskExcerptChannelTests {
    private static let course = CourseSummary(courseID: "1", code: "CIS 2400", name: "CIS 2400 Introduction to Computer Systems", url: nil)

    /// One paragraph of exactly `length` characters that starts with the word
    /// "tariff" (the word every question below searches for) and then runs
    /// 12-character filler words. It ends inside a word, never on a space, so
    /// the chunker's trimming cannot shorten it.
    private static func passage(length: Int) -> String {
        var text = "tariff"
        var n = 0
        while text.count < length {
            text += " fillerword" + String(format: "%02d", n % 100)
            n += 1
        }
        return String(text.prefix(length))
    }

    private static func page(_ text: String, id: String, title: String? = nil) -> CourseDocument {
        CourseDocument(courseID: "1", course: "CIS 2400", kind: .page, sourceID: id, title: title ?? "Page \(id)", url: nil, text: text)
    }

    private static func context(_ documents: [CourseDocument], previous: String? = nil, contextDocument: String = "the exact document text") -> AssistantContext {
        AssistantContext(
            courseCodes: ["CIS 2400"],
            contextDocument: contextDocument,
            askedAt: AssistantFixture.now,
            knowledge: CourseKnowledgeBase(courses: [course], documents: documents),
            previousQuestion: previous
        )
    }

    /// The numbered excerpt lines, without the header.
    private static func lines(_ excerpts: String) -> [String] {
        excerpts.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
    }

    /// What follows `"Title": ` on one excerpt line.
    private static func body(of line: String) -> String {
        guard let range = line.range(of: "\": ") else { return "" }
        return String(line[range.upperBound...])
    }

    // MARK: - How many, how long, how many per document

    @Test("up to eight passages ride along, no more")
    func eightPassagesAtMost() {
        let documents = (0..<10).map { Self.page("tariff schedule for section \($0)", id: "p\($0)") }
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "tariff schedule", context: Self.context(documents))
        #expect(Self.lines(excerpts).count == 8)
        #expect(!excerpts.contains("[9]"))
    }

    @Test("a 1,300-character passage arrives whole")
    func passageOfThirteenHundredArrivesWhole() {
        let text = Self.passage(length: 1300)
        #expect(text.count == 1300)
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "tariff", context: Self.context([Self.page(text, id: "long")]))
        #expect(excerpts.contains(text))
    }

    @Test("a 2,000-character passage is cut at a word boundary at or under 1,500")
    func passageOfTwoThousandIsCutBetweenWords() throws {
        let text = Self.passage(length: 2000)
        #expect(text.count == 2000)
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "tariff", context: Self.context([Self.page(text, id: "long")]))
        let line = try #require(Self.lines(excerpts).first)
        let body = Self.body(of: line)
        #expect(body.count <= BackendAssistantResponder.excerptCharacterLimit)
        // Not cut short by more than one word's worth.
        #expect(body.count > BackendAssistantResponder.excerptCharacterLimit - 20)
        #expect(text.hasPrefix(body))
        // Whole words only: the character that follows the kept text is a
        // space, so no word was split.
        #expect(text.dropFirst(body.count).first == " ")
    }

    @Test("three passages from one document can all appear")
    func threePassagesFromOneDocument() {
        // Four paragraphs of 100 words: each lands in its own passage, and all
        // four match, so only the per-document cap decides how many arrive.
        let paragraph = "tariff " + Array(repeating: "filler", count: 99).joined(separator: " ")
        let document = Self.page(Array(repeating: paragraph, count: 4).joined(separator: "\n"), id: "syllabus")
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "tariff", context: Self.context([document]))
        #expect(Self.lines(excerpts).count == 3)
    }

    // MARK: - The word-boundary cut itself

    @Test("text that fits is returned unchanged")
    func shortTextUnchanged() {
        #expect(BackendAssistantResponder.cutAtWordBoundary("late days are free", limit: 100) == "late days are free")
        #expect(BackendAssistantResponder.cutAtWordBoundary("exactly ten", limit: 11) == "exactly ten")
    }

    @Test("a cut inside a word backs up to the space before it")
    func cutInsideAWord() {
        // A plain 18-character prefix would be "late within 24 hou".
        #expect(BackendAssistantResponder.cutAtWordBoundary("late within 24 hours of the deadline", limit: 18) == "late within 24")
    }

    @Test("a cut that lands exactly on a space keeps the whole word before it")
    func cutOnASpace() {
        #expect(BackendAssistantResponder.cutAtWordBoundary("late within 24 hours", limit: 14) == "late within 24")
    }

    @Test("trailing spaces are not kept")
    func trailingSpacesDropped() {
        #expect(BackendAssistantResponder.cutAtWordBoundary("alpha   bravo charlie", limit: 9) == "alpha")
    }

    @Test("one unbroken run longer than the limit is cut at the limit instead of dropped")
    func unbrokenRunIsHardCut() {
        let url = "https://example.edu/" + String(repeating: "a", count: 100)
        #expect(BackendAssistantResponder.cutAtWordBoundary(url, limit: 30) == String(url.prefix(30)))
    }

    // MARK: - The student's local date and time, first in every block

    private static let newYork = TimeZone(identifier: "America/New_York")!

    /// 2026-10-24 01:15:22 UTC: 9:15 pm on Friday the 23rd in New York (EDT).
    private static let lateFriday = ISO8601DateFormatter().date(from: "2026-10-24T01:15:22Z")!

    private static let fridayLine = "The student's local date and time: Friday, October 23, 2026, 9:15 PM (America/New_York, UTC-04:00). Due times in the work list carry this offset; \"today\" and \"tomorrow\" mean the student's calendar day."

    private static func zonedContext(_ documents: [CourseDocument], zone: TimeZone = Self.newYork, askedAt: Date = Self.lateFriday) -> AssistantContext {
        AssistantContext(
            courseCodes: ["CIS 2400"],
            contextDocument: "the exact document text",
            askedAt: askedAt,
            timeZone: zone,
            knowledge: CourseKnowledgeBase(courses: [course], documents: documents)
        )
    }

    @Test("the local date line for 01:15:22 UTC in New York reads Friday, October 23, 2026, 9:15 PM and UTC-04:00")
    func localDateLineInNewYork() {
        let line = BackendAssistantResponder.localDateLine(askedAt: Self.lateFriday, timeZone: Self.newYork)
        #expect(line == Self.fridayLine)
        #expect(line.contains("Friday, October 23, 2026, 9:15 PM"))
        #expect(line.contains("UTC-04:00"))
    }

    @Test("the local date line writes a half-hour offset and a zone east of Greenwich")
    func localDateLineInKolkata() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        let line = BackendAssistantResponder.localDateLine(askedAt: Self.lateFriday, timeZone: kolkata)
        #expect(line.hasPrefix("The student's local date and time: Saturday, October 24, 2026, 6:45 AM (Asia/Kolkata, UTC+05:30)."))
    }

    @Test("a question with no hits yields a block that is exactly the local date line")
    func noHitsIsJustTheLocalDateLine() {
        let documents = [Self.page("tariff schedule", id: "a")]
        let block = BackendAssistantResponder.excerptBlock(question: "xylophone", context: Self.zonedContext(documents))
        #expect(block.text == Self.fridayLine)
        #expect(block.sources.isEmpty)
        // And so does a student with nothing synced at all.
        let empty = BackendAssistantResponder.excerptBlock(question: "tariff", context: Self.zonedContext([]))
        #expect(empty.text == Self.fridayLine)
        #expect(empty.sources.isEmpty)
        let request = BackendAssistantResponder.makeRequest(question: "tariff", context: Self.zonedContext([]))
        #expect(request.excerpts == Self.fridayLine)
    }

    @Test("with hits, the local date line comes first and the header follows it")
    func localDateLineLeadsTheExcerpts() {
        let documents = [Self.page("tariff schedule", id: "a")]
        let block = BackendAssistantResponder.excerptBlock(question: "tariff", context: Self.zonedContext(documents))
        let all = block.text.components(separatedBy: "\n")
        #expect(all[0] == Self.fridayLine)
        #expect(all[1] == "RETRIEVED EXCERPTS (from the student's synced course materials):")
        #expect(all[2].hasPrefix("[1] "))
        #expect(Self.lines(block.text).count == 1)
    }

    @Test("the same question, time and zone give byte-identical blocks")
    func blockIsByteStable() {
        let documents = [Self.page("tariff schedule", id: "a")]
        let first = BackendAssistantResponder.excerptBlock(question: "tariff", context: Self.zonedContext(documents))
        let second = BackendAssistantResponder.excerptBlock(question: "tariff", context: Self.zonedContext(documents))
        #expect(Array(first.text.utf8) == Array(second.text.utf8))
    }

    // MARK: - Line structure survives into the excerpt

    @Test("a two-paragraph passage keeps its newline and indents the continuation line")
    func newlineKeptAndContinuationIndented() throws {
        let document = Self.page("tariff first line\nsecond line of the passage", id: "two")
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "tariff", context: Self.context([document]))
        let all = excerpts.components(separatedBy: "\n")
        let start = try #require(all.firstIndex { $0.hasPrefix("[1] ") })
        #expect(all[start].hasSuffix(": tariff first line"))
        #expect(all[start + 1] == "  second line of the passage")
        #expect(all.count == start + 2)
        // Only the numbered line starts at the left edge.
        #expect(Self.lines(excerpts).count == 1)
    }

    @Test("structuredExcerptBody indents continuation lines, collapses newline runs and leaves blank lines bare")
    func structuredBodyRules() {
        #expect(BackendAssistantResponder.structuredExcerptBody("one") == "one")
        #expect(BackendAssistantResponder.structuredExcerptBody("one\ntwo\nthree") == "one\n  two\n  three")
        #expect(BackendAssistantResponder.structuredExcerptBody("one\n\n\n\n\ntwo") == "one\n\n  two")
        #expect(BackendAssistantResponder.structuredExcerptBody("one\n\ntwo") == "one\n\n  two")
    }

    @Test("a cut inside a continuation line still ends on a whole word")
    func cutInsideAContinuationLine() {
        let body = BackendAssistantResponder.structuredExcerptBody("alpha bravo\ncharlie delta echo")
        // "alpha bravo\n  charlie delta echo": 25 characters ends inside "delta".
        let cut = BackendAssistantResponder.cutAtWordBoundary(body, limit: 25)
        #expect(cut == "alpha bravo\n  charlie")
    }

    // MARK: - Remembering the previous question changes nothing on the wire

    @Test("with a previous question, the question is still the typed text and history is still empty")
    func questionAndHistoryUnchangedByAPreviousQuestion() {
        let documents = [Self.page("tariff schedule", id: "a")]
        let request = BackendAssistantResponder.makeRequest(
            question: "and for the final?",
            context: Self.context(documents, previous: "what's the late policy in CIS 2400?")
        )
        #expect(request.question == "and for the final?")
        #expect(request.history.isEmpty)
    }

    @Test("every field except the retrieved excerpts is identical with and without a previous question")
    func onlyExcerptsMayDiffer() {
        let documents = [Self.page("tariff schedule", id: "a")]
        let alone = BackendAssistantResponder.makeRequest(question: "tariff", context: Self.context(documents))
        let followUp = BackendAssistantResponder.makeRequest(question: "tariff", context: Self.context(documents, previous: "what's the late policy in CIS 2400?"))
        #expect(alone.question == followUp.question)
        #expect(alone.contextDocument == followUp.contextDocument)
        #expect(alone.askedAt == followUp.askedAt)
        #expect(alone.courseIDs == followUp.courseIDs)
        #expect(alone.history == followUp.history)
    }

    @Test("the context document is byte-identical with and without a previous question")
    func contextDocumentIsTheCachePrefix() {
        let text = "# ASSISTANT CONTEXT\nthe exact document text\n"
        let documents = [Self.page("tariff schedule", id: "a")]
        let alone = BackendAssistantResponder.makeRequest(question: "and for the final?", context: Self.context(documents, contextDocument: text))
        let followUp = BackendAssistantResponder.makeRequest(question: "and for the final?", context: Self.context(documents, previous: "what's the late policy in CIS 2400?", contextDocument: text))
        #expect(alone.contextDocument == text)
        #expect(followUp.contextDocument == text)
        #expect(Array(alone.contextDocument.utf8) == Array(followUp.contextDocument.utf8))
    }

    @Test("the previous question's words are nowhere in the encoded request")
    func previousQuestionNeverEncoded() throws {
        let marker = "zxqvmarker"
        let documents = [Self.page("tariff schedule", id: "a")]
        let request = BackendAssistantResponder.makeRequest(
            question: "tariff",
            context: Self.context(documents, previous: "what is the \(marker) policy in CIS 2400?")
        )
        let json = try String(data: JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(!json.isEmpty)
        #expect(!json.contains(marker))
    }
}
