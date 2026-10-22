import Foundation
import Testing
@testable import LowHangingFruitKit

/// `CourseDocument.Kind.file` is text the Chrome extension pulled out of a
/// Canvas File (PDF or slides) and the phone only ever receives. These pin the
/// Swift half of that: the raw value the backend's `DOCUMENT_KINDS` must
/// agree with, the Codable and wire round trips, retrieval weighted like a
/// page, and the exclusions that keep a file out of syllabus and profile
/// input and out of the "is this course split" decision.
@Suite("File document kind")
struct FileKindTests {
    private func fileDoc(title: String = "Lecture 4 slides", text: String = "Caches and locality.") -> CourseDocument {
        CourseDocument(
            courseID: "1234",
            course: "CIS 2400",
            kind: .file,
            sourceID: "98765",
            title: title,
            url: URL(string: "https://canvas.upenn.edu/courses/1234/files/98765"),
            text: text,
            updatedAt: Date(timeIntervalSince1970: 9_000),
            fetchedAt: Date(timeIntervalSince1970: 10_000)
        )
    }

    @Test("Kind(rawValue: \"file\") resolves, labels as course file, and is in allCases")
    func rawValueResolves() {
        #expect(CourseDocument.Kind(rawValue: "file") == .file)
        #expect(CourseDocument.Kind.file.rawValue == "file")
        #expect(CourseDocument.Kind.file.label == "course file")
        #expect(CourseDocument.Kind.allCases.contains(.file))
    }

    @Test("a file document round-trips through Codable")
    func codableRoundTrip() throws {
        let original = fileDoc()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CourseDocument.self, from: data)
        #expect(restored == original)
        #expect(restored.kind == .file)
        #expect(restored.id == "file:1234:98765")
    }

    @Test("a knowledge base written before file existed still decodes")
    func oldKnowledgeBaseDecodes() throws {
        let page = CourseDocument(courseID: "1", course: "CIS 2400", kind: .page, sourceID: "p", title: "Logistics", url: nil, text: "Office hours.")
        let old = CourseKnowledgeBase(courses: [], documents: [page])
        let data = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(CourseKnowledgeBase.self, from: data)
        #expect(restored.documents.map(\.kind) == [.page])
    }

    @Test("a file CourseDocumentWire round-trips through document() and back")
    func wireRoundTrip() throws {
        let original = fileDoc()
        let wire = CourseDocumentWire(document: original)
        #expect(wire.kind == "file")
        let restored = try #require(wire.document())
        #expect(restored.kind == .file)
        #expect(restored.id == original.id)
        #expect(restored.contentHash == original.contentHash)
    }

    private func topScore(kind: CourseDocument.Kind, query: String) throws -> Double {
        let doc = CourseDocument(
            courseID: "1", course: "CIS 2400", kind: kind, sourceID: "9", title: "Locality", url: nil,
            text: "Caches exploit temporal and spatial locality to hide memory latency."
        )
        let filler = CourseDocument(
            courseID: "1", course: "CIS 2400", kind: .home, sourceID: "h", title: "Welcome", url: nil,
            text: "Welcome to the course. Office hours are Tuesdays."
        )
        let search = CourseSearch(
            knowledge: CourseKnowledgeBase(documents: [doc, filler]),
            embeddingProvider: SentenceEmbeddingProvider { nil }
        )
        let hits = search.search(query, kinds: [kind], limit: 3)
        return try #require(hits.first).score
    }

    @Test("a file is weighted like a page in retrieval")
    func weightedLikePage() throws {
        let query = "caches locality latency"
        let page = try topScore(kind: .page, query: query)
        let file = try topScore(kind: .file, query: query)
        #expect(abs(page - file) < 1e-9)
    }

    @Test("a file is never read as the syllabus or as syllabus exam rows")
    func notSyllabusInput() {
        let syllabus = fileDoc(title: "Syllabus", text: "Midterm 1: Oct 23")
        let knowledge = CourseKnowledgeBase(courses: [], documents: [syllabus])
        #expect(knowledge.syllabusText(forCourseID: "1234") == nil)
        #expect(SyllabusExamRows.kindOrder.contains(.file) == false)
    }

    @Test("a file titled like a lab does not make a course look split")
    func notProfileOrSplitInput() {
        let lab = fileDoc(title: "Lab 3 recitation review", text: "Recitation and lab section notes.")
        #expect(DocumentComponent.courseIsSplit([lab]) == false)
    }
}
