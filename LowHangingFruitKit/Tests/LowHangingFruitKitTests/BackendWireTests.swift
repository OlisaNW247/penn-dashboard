import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Backend wire types")
struct BackendWireTests {
    private static let course = CourseSummary(courseID: "1234", code: "CIS 2400", name: "CIS 2400 Intro to Computer Systems", url: URL(string: "https://canvas.upenn.edu/courses/1234"))

    private func assignmentDoc(text: String = "Implement a cache.", fetchedAt: Date = Date(timeIntervalSince1970: 10_000)) -> CourseDocument {
        CourseDocument(
            courseID: "1234",
            course: "CIS 2400",
            kind: .assignment,
            sourceID: "555",
            title: "PSet 3",
            url: URL(string: "https://canvas.upenn.edu/courses/1234/assignments/555"),
            text: text,
            updatedAt: Date(timeIntervalSince1970: 9_000),
            fetchedAt: fetchedAt,
            dueAt: Date(timeIntervalSince1970: 20_000),
            pointsPossible: 100,
            submitted: true
        )
    }

    // MARK: - CourseDocumentWire round trip

    @Test("CourseDocumentWire round-trips a CourseDocument, dropping submitted")
    func roundTripsDocument() throws {
        let original = assignmentDoc()
        let wire = CourseDocumentWire(document: original)
        #expect(wire.id == original.id)
        #expect(wire.contentHash == original.contentHash)
        #expect(wire.url == original.url?.absoluteString)

        let restored = try #require(wire.document())
        #expect(restored.id == original.id)
        #expect(restored.courseID == original.courseID)
        #expect(restored.course == original.course)
        #expect(restored.kind == original.kind)
        #expect(restored.sourceID == original.sourceID)
        #expect(restored.title == original.title)
        #expect(restored.url == original.url)
        #expect(restored.text == original.text)
        #expect(restored.updatedAt == original.updatedAt)
        #expect(restored.fetchedAt == original.fetchedAt)
        #expect(restored.contentHash == original.contentHash)
        #expect(restored.dueAt == original.dueAt)
        #expect(restored.pointsPossible == original.pointsPossible)
        #expect(restored.submitted == nil)
    }

    @Test("document() rejects an unrecognized kind")
    func rejectsUnknownKind() {
        let wire = CourseDocumentWire(
            id: "essay:1234:1",
            courseID: "1234",
            course: "CIS 2400",
            kind: "essay",
            sourceID: "1",
            title: "T",
            text: "body",
            fetchedAt: Date(),
            contentHash: "abc"
        )
        #expect(wire.document() == nil)
    }

    @Test("document() rejects an id that doesn't match kind:courseID:sourceID")
    func rejectsMismatchedID() {
        let wire = CourseDocumentWire(
            id: "page:9999:1",
            courseID: "1234",
            course: "CIS 2400",
            kind: "page",
            sourceID: "1",
            title: "T",
            text: "body",
            fetchedAt: Date(),
            contentHash: "abc"
        )
        #expect(wire.document() == nil)
    }

    // MARK: - Encoding shape

    @Test("SyncManifestRequest encodes the constant action and no submitted field")
    func encodesManifestRequest() throws {
        let doc = assignmentDoc()
        let request = SyncManifestRequest(
            courses: [CourseSummaryWire(summary: Self.course)],
            documents: [DocumentStub(document: doc)]
        )
        let data = try BackendJSON.encoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"action\":\"manifest\""))
        #expect(!json.contains("submitted"))
    }

    @Test("CourseDocumentWire never encodes a submitted key")
    func documentWireNeverEncodesSubmitted() throws {
        let wire = CourseDocumentWire(document: assignmentDoc())
        let data = try BackendJSON.encoder().encode(wire)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("submitted"))
    }

    @Test("SyncUploadRequest encodes the constant upload action")
    func encodesUploadRequest() throws {
        let request = SyncUploadRequest(documents: [], fullySyncedCourses: [])
        let data = try BackendJSON.encoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"action\":\"upload\""))
    }

    @Test("AskRequest encodes askedAt as an ISO 8601 string")
    func encodesAskedAtAsISO8601() throws {
        let request = AskRequest(
            question: "When is the midterm?",
            contextDocument: "context",
            excerpts: "",
            askedAt: Date(timeIntervalSince1970: 1_800_000_000),
            courseIDs: ["1234"],
            history: [AskTurn(role: "user", content: "hi")]
        )
        let data = try BackendJSON.encoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let askedAt = try #require(object["askedAt"] as? String)
        #expect(askedAt.contains("T"))
        #expect(askedAt.hasSuffix("Z"))
        #expect(BackendJSON.decoder().decodeDateForTesting(askedAt) == Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Decoding dates

    @Test("BackendJSON decoder accepts dates with and without fractional seconds")
    func decodesFractionalAndPlainDates() throws {
        struct Wrapper: Decodable { let date: Date }
        let withFraction = try BackendJSON.decoder().decode(Wrapper.self, from: Data(#"{"date":"2026-09-07T14:03:00.500Z"}"#.utf8))
        let plain = try BackendJSON.decoder().decode(Wrapper.self, from: Data(#"{"date":"2026-09-07T14:03:00Z"}"#.utf8))
        #expect(withFraction.date != plain.date)
        #expect(abs(withFraction.date.timeIntervalSince(plain.date) - 0.5) < 0.001)
    }

    @Test("BackendJSON decoder throws a clear error for an unrecognized date")
    func rejectsUnrecognizedDate() {
        struct Wrapper: Decodable { let date: Date }
        #expect(throws: (any Error).self) {
            try BackendJSON.decoder().decode(Wrapper.self, from: Data(#"{"date":"not a date"}"#.utf8))
        }
    }

    // MARK: - SyncManifestResponse defaults

    @Test("SyncManifestResponse decodes missing keys to empty collections")
    func manifestResponseDefaultsToEmpty() throws {
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data("{}".utf8))
        #expect(response.coursesFresh.isEmpty)
        #expect(response.serverManifest.isEmpty)
        #expect(response.download.isEmpty)
    }

    @Test("SyncManifestResponse decodes present keys")
    func manifestResponseDecodesPresentKeys() throws {
        let json = """
        {"coursesFresh":["1234"],"serverManifest":[{"id":"page:1234:1","contentHash":"abc"}],"download":[]}
        """
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data(json.utf8))
        #expect(response.coursesFresh == ["1234"])
        #expect(response.serverManifest == [DocumentStub(id: "page:1234:1", contentHash: "abc")])
    }

    @Test("SyncUploadResponse decodes a missing profileStale to empty")
    func uploadResponseDefaultsToEmpty() throws {
        let response = try BackendJSON.decoder().decode(SyncUploadResponse.self, from: Data(#"{"accepted":3}"#.utf8))
        #expect(response.accepted == 3)
        #expect(response.profileStale.isEmpty)
    }

    // MARK: - AskStreamEvent.parse

    @Test("parses a delta event")
    func parsesDelta() {
        let event = AskStreamEvent.parse(line: #"data: {"type":"delta","text":"hello"}"#)
        #expect(event == .delta("hello"))
    }

    @Test("parses a data: line with no space before the JSON")
    func parsesDataWithoutSpace() {
        let event = AskStreamEvent.parse(line: #"data:{"type":"delta","text":"hi"}"#)
        #expect(event == .delta("hi"))
    }

    @Test("parses a done event with full usage")
    func parsesDoneWithUsage() {
        let event = AskStreamEvent.parse(line: #"data: {"type":"done","usage":{"promptTokens":10,"completionTokens":5,"cachedTokens":2}}"#)
        #expect(event == .done(promptTokens: 10, completionTokens: 5, cachedTokens: 2))
    }

    @Test("parses a done event with missing usage numbers as zero")
    func parsesDoneWithoutCachedTokens() {
        let event = AskStreamEvent.parse(line: #"data: {"type":"done","usage":{"promptTokens":10,"completionTokens":5}}"#)
        #expect(event == .done(promptTokens: 10, completionTokens: 5, cachedTokens: 0))
    }

    @Test("parses a done event with no usage object at all")
    func parsesDoneWithNoUsage() {
        let event = AskStreamEvent.parse(line: #"data: {"type":"done"}"#)
        #expect(event == .done(promptTokens: 0, completionTokens: 0, cachedTokens: 0))
    }

    @Test("parses an error event")
    func parsesError() {
        let event = AskStreamEvent.parse(line: #"data: {"type":"error","code":"quota_exceeded","message":"Daily limit reached"}"#)
        #expect(event == .error(code: "quota_exceeded", message: "Daily limit reached"))
    }

    @Test("ignores a comment line")
    func ignoresComment() {
        #expect(AskStreamEvent.parse(line: ": keepalive") == nil)
    }

    @Test("ignores a blank line")
    func ignoresBlank() {
        #expect(AskStreamEvent.parse(line: "") == nil)
    }

    @Test("ignores a line that isn't valid JSON")
    func ignoresNonJSON() {
        #expect(AskStreamEvent.parse(line: "data: not json") == nil)
    }

    @Test("ignores an unknown event type")
    func ignoresUnknownType() {
        #expect(AskStreamEvent.parse(line: #"data: {"type":"ping"}"#) == nil)
    }

    @Test("ignores a line that isn't a data: field at all")
    func ignoresNonDataLine() {
        #expect(AskStreamEvent.parse(line: "event: message") == nil)
    }
}

// A tiny test-only helper so the AskRequest date-encoding test can assert
// round-trip equality without hand-rolling another ISO8601DateFormatter.
private extension JSONDecoder {
    func decodeDateForTesting(_ string: String) -> Date? {
        struct Wrapper: Decodable { let date: Date }
        guard let data = "{\"date\":\"\(string)\"}".data(using: .utf8) else { return nil }
        return try? decode(Wrapper.self, from: data).date
    }
}
