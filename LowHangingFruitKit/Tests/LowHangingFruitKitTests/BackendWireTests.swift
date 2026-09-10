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

    @Test("CourseSummaryWire encodes a summary's section, and decodes an absent one to nil")
    func courseSummaryWireSection() throws {
        let sectioned = CourseSummary(courseID: "1234", code: "PHYS 0151", name: "PHYS 0151-401 Lab", url: nil, section: "401")
        let wire = CourseSummaryWire(summary: sectioned)
        #expect(wire.section == "401")
        let data = try BackendJSON.encoder().encode(wire)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"section\":\"401\""))

        // A payload with no "section" key at all — the shape every server
        // response predating this field has — decodes to nil rather than
        // failing the whole struct.
        let legacyJSON = """
        {"courseID":"1234","code":"CIS 2400","name":"CIS 2400","url":null}
        """
        let decoded = try BackendJSON.decoder().decode(CourseSummaryWire.self, from: Data(legacyJSON.utf8))
        #expect(decoded.section == nil)
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

    // MARK: - CourseLinkWire / SyncUploadRequest.links

    @Test("CourseLinkWire round-trips a CourseLink")
    func courseLinkWireRoundTrips() {
        let link = CourseLink(courseID: "1234", href: "https://example.com/syllabus", text: "Course site", origin: .page)
        let wire = CourseLinkWire(link: link)
        #expect(wire.courseID == "1234")
        #expect(wire.href == "https://example.com/syllabus")
        #expect(wire.text == "Course site")
        #expect(wire.origin == "page")
    }

    @Test("SyncUploadRequest encodes an empty links array when none are given")
    func encodesEmptyLinksArray() throws {
        let request = SyncUploadRequest(documents: [], fullySyncedCourses: [])
        let data = try BackendJSON.encoder().encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"links\":[]"))
    }

    @Test("SyncUploadRequest encodes non-empty links")
    func encodesNonEmptyLinks() throws {
        let link = CourseLinkWire(link: CourseLink(courseID: "1234", href: "https://example.com", text: "Site", origin: .syllabus))
        let request = SyncUploadRequest(documents: [], fullySyncedCourses: [], links: [link])
        let data = try BackendJSON.encoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let links = try #require(object["links"] as? [[String: Any]])
        #expect(links.count == 1)
        #expect(links[0]["href"] as? String == "https://example.com")
        #expect(links[0]["origin"] as? String == "syllabus")
        #expect(links[0]["courseID"] as? String == "1234")
    }

    // MARK: - SyncUploadResponse.websitesPending

    @Test("SyncUploadResponse decodes a missing websitesPending to empty")
    func uploadResponseDefaultsWebsitesPendingToEmpty() throws {
        let response = try BackendJSON.decoder().decode(SyncUploadResponse.self, from: Data(#"{"accepted":3}"#.utf8))
        #expect(response.websitesPending.isEmpty)
    }

    @Test("SyncUploadResponse decodes a present websitesPending")
    func uploadResponseDecodesWebsitesPending() throws {
        let response = try BackendJSON.decoder().decode(SyncUploadResponse.self, from: Data(#"{"accepted":3,"websitesPending":["1234","5678"]}"#.utf8))
        #expect(response.websitesPending == ["1234", "5678"])
    }

    // MARK: - DiscoverWebsitesRequest

    @Test("DiscoverWebsitesRequest encodes courseIDs")
    func encodesDiscoverWebsitesRequest() throws {
        let request = DiscoverWebsitesRequest(courseIDs: ["1234", "5678"])
        let data = try BackendJSON.encoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["courseIDs"] as? [String] == ["1234", "5678"])
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

    // MARK: - SyncManifestResponse.catalog

    @Test("SyncManifestResponse decodes a missing catalog to empty")
    func manifestResponseDefaultsCatalogToEmpty() throws {
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data("{}".utf8))
        #expect(response.catalog.isEmpty)
    }

    @Test("SyncManifestResponse decodes a present catalog, including a meeting")
    func manifestResponseDecodesCatalog() throws {
        let json = """
        {"catalog":[{"courseID":"1234","catalogCode":"CIS-2400","title":"Intro to Computer Systems","meetings":[{"sectionID":"001","activity":"LEC","weekday":3,"startMinutes":615,"endMinutes":704}]}]}
        """
        let response = try BackendJSON.decoder().decode(SyncManifestResponse.self, from: Data(json.utf8))
        #expect(response.catalog.count == 1)
        #expect(response.catalog.first?.courseID == "1234")
        #expect(response.catalog.first?.catalogCode == "CIS-2400")
        #expect(response.catalog.first?.credits == nil)
        #expect(response.catalog.first?.meetings.first?.activity == "LEC")
    }

    // MARK: - CourseCatalogEntry decoding

    @Test("CourseCatalogEntry decodes without a meetings key, defaulting to empty")
    func catalogEntryDecodesWithoutMeetings() throws {
        let json = #"{"courseID":"1234","catalogCode":"CIS 2400","title":"Intro to Computer Systems"}"#
        let entry = try BackendJSON.decoder().decode(CourseCatalogEntry.self, from: Data(json.utf8))
        #expect(entry.meetings.isEmpty)
        #expect(entry.credits == nil)
        #expect(entry.id == "1234")
    }

    @Test("CourseCatalogEntry decodes without a components key, defaulting to empty (old server or old on-disk JSON)")
    func catalogEntryDecodesWithoutComponents() throws {
        let json = #"{"courseID":"1234","catalogCode":"PHYS-0151","title":"Intro to Physics"}"#
        let entry = try BackendJSON.decoder().decode(CourseCatalogEntry.self, from: Data(json.utf8))
        #expect(entry.components.isEmpty)
    }

    @Test("CourseCatalogEntry decodes present components, including a zero-credit lab")
    func catalogEntryDecodesComponents() throws {
        let json = """
        {"courseID":"1234","catalogCode":"PHYS-0151","title":"Intro to Physics",
         "components":[
           {"activity":"LEC","credits":1.0,"sectionIDs":["PHYS-0151-151"]},
           {"activity":"LAB","credits":0,"sectionIDs":["PHYS-0151-401"]}
         ]}
        """
        let entry = try BackendJSON.decoder().decode(CourseCatalogEntry.self, from: Data(json.utf8))
        #expect(entry.components.count == 2)
        #expect(entry.components.first { $0.activity == "LAB" }?.credits == 0)
    }

    @Test("CourseCatalogEntry.component(forSectionID:) finds the component naming that section")
    func componentForSectionID() {
        let entry = CourseCatalogEntry(
            courseID: "1234",
            catalogCode: "PHYS-0151",
            title: "Intro to Physics",
            components: [
                CatalogComponent(activity: "LEC", credits: 1.0, sectionIDs: ["PHYS-0151-151"]),
                CatalogComponent(activity: "LAB", credits: 0, sectionIDs: ["PHYS-0151-401"]),
            ]
        )
        #expect(entry.component(forSectionID: "PHYS-0151-401")?.activity == "LAB")
        #expect(entry.component(forSectionID: "PHYS-0151-151")?.credits == 1.0)
        #expect(entry.component(forSectionID: "PHYS-0151-999") == nil)
    }

    // MARK: - ExtractedAssignmentWire.kind / taskKind

    @Test("ExtractedAssignmentWire.taskKind defaults to .submission when kind is absent")
    func extractedAssignmentWireTaskKindDefaultsToSubmission() throws {
        let json = #"{"title":"Read chapter 4","dueAt":null}"#
        let wire = try BackendJSON.decoder().decode(ExtractedAssignmentWire.self, from: Data(json.utf8))
        #expect(wire.kind == nil)
        #expect(wire.taskKind == .submission)
    }

    @Test("ExtractedAssignmentWire.taskKind is .preparation when kind is \"preparation\"")
    func extractedAssignmentWireTaskKindPreparation() throws {
        let json = #"{"title":"Bring a calculator","dueAt":null,"kind":"preparation"}"#
        let wire = try BackendJSON.decoder().decode(ExtractedAssignmentWire.self, from: Data(json.utf8))
        #expect(wire.kind == "preparation")
        #expect(wire.taskKind == .preparation)
    }

    @Test("ExtractedAssignmentWire.taskKind falls back to .submission for an unrecognized kind")
    func extractedAssignmentWireTaskKindUnrecognizedFallsBackToSubmission() throws {
        let json = #"{"title":"Read chapter 4","dueAt":null,"kind":"something-new"}"#
        let wire = try BackendJSON.decoder().decode(ExtractedAssignmentWire.self, from: Data(json.utf8))
        #expect(wire.taskKind == .submission)
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
