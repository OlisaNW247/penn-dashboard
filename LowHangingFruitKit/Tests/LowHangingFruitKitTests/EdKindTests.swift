import Foundation
import Testing
@testable import LowHangingFruitKit

/// `CourseDocument.Kind.ed` (Ed Discussion posts) is a new kind on both sides
/// of the wire. These pin the Swift half: the raw value the backend's
/// `DOCUMENT_KINDS` must agree with, the wire round trip a later upload task
/// leans on, and the search weighting that treats an Ed announcement like a
/// Canvas one.
@Suite("Ed document kind")
struct EdKindTests {
    private func edDoc() -> CourseDocument {
        CourseDocument(
            courseID: "1234",
            course: "CIS 2400",
            kind: .ed,
            sourceID: "8675309",
            title: "Midterm room change",
            url: URL(string: "https://edstem.org/us/courses/42/discussion/8675309"),
            text: "The midterm moves to Towne 100.",
            updatedAt: Date(timeIntervalSince1970: 9_000),
            fetchedAt: Date(timeIntervalSince1970: 10_000)
        )
    }

    @Test("Kind(rawValue: \"ed\") resolves, and labels as ed discussion")
    func rawValueResolves() {
        #expect(CourseDocument.Kind(rawValue: "ed") == .ed)
        #expect(CourseDocument.Kind.ed.rawValue == "ed")
        #expect(CourseDocument.Kind.ed.label == "ed discussion")
        #expect(CourseDocument.Kind.allCases.contains(.ed))
    }

    @Test("an ed document's id follows kind:courseID:sourceID")
    func idConvention() {
        #expect(edDoc().id == "ed:1234:8675309")
    }

    @Test("an ed CourseDocumentWire round-trips through document() and back")
    func wireRoundTrip() throws {
        let original = edDoc()
        let wire = CourseDocumentWire(document: original)
        #expect(wire.kind == "ed")
        #expect(wire.id == "ed:1234:8675309")

        let restored = try #require(wire.document())
        #expect(restored.kind == .ed)
        #expect(restored.id == original.id)
        #expect(restored.sourceID == original.sourceID)
        #expect(restored.title == original.title)
        #expect(restored.text == original.text)
        #expect(restored.url == original.url)
        #expect(restored.contentHash == original.contentHash)

        let again = CourseDocumentWire(document: restored)
        #expect(again.kind == wire.kind)
        #expect(again.id == wire.id)
        #expect(again.contentHash == wire.contentHash)
    }

    @Test("a hand-built wire with kind ed is accepted by document()")
    func handBuiltWire() {
        let wire = CourseDocumentWire(
            id: "ed:1234:77",
            courseID: "1234",
            course: "CIS 2400",
            kind: "ed",
            sourceID: "77",
            title: "T",
            text: "body",
            fetchedAt: Date(),
            contentHash: "abc"
        )
        #expect(wire.document()?.kind == .ed)
    }

    /// `kindBoost` is private, so this goes through `search` the way
    /// `CourseKnowledgeTests` does: the same text filed once as an
    /// announcement and once as an ed post, in otherwise identical knowledge
    /// bases, must score identically, for a recency query (the 1.4 boost) and
    /// for a plain one (1.0). A cold embedding provider keeps the order
    /// BM25-only, so the scores are comparable.
    private func topScore(kind: CourseDocument.Kind, query: String) throws -> Double {
        let post = CourseDocument(
            courseID: "1", course: "CIS 2400", kind: kind, sourceID: "9", title: "Exam update", url: nil,
            text: "The exam was rescheduled to Friday because of the storm."
        )
        let filler = CourseDocument(
            courseID: "1", course: "CIS 2400", kind: .page, sourceID: "p", title: "Logistics", url: nil,
            text: "Office hours are Tuesdays. Bring a laptop to recitation."
        )
        let search = CourseSearch(
            knowledge: CourseKnowledgeBase(documents: [post, filler]),
            embeddingProvider: SentenceEmbeddingProvider { nil }
        )
        let hits = search.search(query, kinds: [kind], limit: 3)
        return try #require(hits.first).score
    }

    @Test("ed is boosted like an announcement for a recency query")
    func boostMatchesAnnouncementForRecencyQuery() throws {
        let query = "was the exam rescheduled"
        let announcement = try topScore(kind: .announcement, query: query)
        let ed = try topScore(kind: .ed, query: query)
        #expect(abs(announcement - ed) < 1e-9)
    }

    @Test("ed is weighted like an announcement for a plain query")
    func boostMatchesAnnouncementForPlainQuery() throws {
        let query = "exam friday storm"
        let announcement = try topScore(kind: .announcement, query: query)
        let ed = try topScore(kind: .ed, query: query)
        #expect(abs(announcement - ed) < 1e-9)
    }
}
