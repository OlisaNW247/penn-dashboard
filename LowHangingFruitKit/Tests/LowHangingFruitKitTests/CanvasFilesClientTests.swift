import Foundation
import Testing
#if canImport(CoreText)
import CoreText
import CoreGraphics
#endif
@testable import LowHangingFruitKit

/// A one-page PDF with real text, drawn with CoreText so PDFKit can read it back.
func makeTextPDF(_ text: String) -> Data {
    #if canImport(CoreText)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = CGPoint(x: 36, y: 700)
    CTLineDraw(line, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    return data as Data
    #else
    return Data()
    #endif
}

@Suite("Canvas files client", .serialized)
struct CanvasFilesClientTests {
    fileprivate final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var routes: [String: (Int, [String: String], Data)] = [:]
        nonisolated(unsafe) static var seen: [String] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let path = request.url!.path
            Self.seen.append(path)
            if path.hasSuffix("/hang") { return }
            let (status, headers, body) = Self.routes[path] ?? (404, [:], Data("{}".utf8))
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func client() -> CanvasFilesClient {
        Stub.routes = [:]; Stub.seen = []
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Stub.self]
        return CanvasFilesClient(cookies: [], session: URLSession(configuration: cfg))
    }

    private func meta(type: String = "application/pdf", size: Int? = 1000, locked: Bool = false,
                      url: String = "https://canvas.upenn.edu/files/7/download?verifier=x") -> Data {
        var obj: [String: Any] = ["id": 7, "display_name": "ps1.pdf", "content-type": type,
                                  "url": url, "updated_at": "2026-11-01T12:00:00Z", "locked_for_user": locked]
        if let size { obj["size"] = size }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    @Test("metadata decodes Canvas's keys, content-type included")
    func decode() async throws {
        let c = client()
        Stub.routes["/api/v1/files/7"] = (200, ["Content-Type": "application/json"], meta())
        let m = try await c.metadata(fileID: "7")
        #expect(m.displayName == "ps1.pdf")
        #expect(m.contentType == "application/pdf")
        #expect(m.size == 1000)
        #expect(m.lockedForUser == false)
        #expect(m.updatedAt != nil)
        #expect(m.url?.contains("/files/7/download") == true)
    }

    @Test("a pdf is downloaded")
    func happy() async throws {
        let c = client()
        let pdf = makeTextPDF("hello")
        Stub.routes["/api/v1/files/7"] = (200, ["Content-Type": "application/json"], meta(size: pdf.count))
        Stub.routes["/files/7/download"] = (200, ["Content-Type": "application/pdf"], pdf)
        guard case let .pdf(m, data) = try await c.pdf(fileID: "7") else { Issue.record("expected pdf"); return }
        #expect(m.displayName == "ps1.pdf")
        #expect(data == pdf)
    }

    @Test("not a pdf, locked, or declared too large: skipped without a download")
    func skips() async throws {
        let c = client()
        Stub.routes["/api/v1/files/7"] = (200, ["Content-Type": "application/json"], meta(type: "image/png"))
        #expect(try await c.pdf(fileID: "7") == .skipped(.notPDF))
        Stub.routes["/api/v1/files/7"] = (200, ["Content-Type": "application/json"], meta(locked: true))
        #expect(try await c.pdf(fileID: "7") == .skipped(.locked))
        Stub.routes["/api/v1/files/7"] = (200, ["Content-Type": "application/json"], meta(size: 11 * 1024 * 1024))
        #expect(try await c.pdf(fileID: "7") == .skipped(.tooLarge))
        #expect(!Stub.seen.contains("/files/7/download"))
    }

    @Test("bytes over the cap are refused even when the size said otherwise")
    func bytesCap() async throws {
        let c = client()
        Stub.routes["/api/v1/files/7"] = (200, ["Content-Type": "application/json"], meta(size: 10))
        Stub.routes["/files/7/download"] = (200, ["Content-Type": "application/pdf"],
                                            Data(count: CanvasFilesClient.maxBytes + 1))
        #expect(try await c.pdf(fileID: "7") == .skipped(.tooLarge))
    }

    @Test("403 and 404 skip the file; 401 throws sessionExpired; 500 throws")
    func statuses() async throws {
        let c = client()
        Stub.routes["/api/v1/files/7"] = (403, [:], Data("{}".utf8))
        #expect(try await c.pdf(fileID: "7") == .skipped(.unavailable))
        Stub.routes["/api/v1/files/7"] = (404, [:], Data("{}".utf8))
        #expect(try await c.pdf(fileID: "7") == .skipped(.unavailable))
        Stub.routes["/api/v1/files/7"] = (401, [:], Data("{}".utf8))
        await #expect(throws: CanvasFilesClient.Error.sessionExpired) { try await c.pdf(fileID: "7") }
        Stub.routes["/api/v1/files/7"] = (500, [:], Data("{}".utf8))
        await #expect(throws: CanvasFilesClient.Error.http(500)) { try await c.pdf(fileID: "7") }
    }

    @Test("the document is shaped like the extension's file document")
    func builder() throws {
        let long = String(repeating: "Problem one asks you to prove a thing. ", count: 5)
        let pdf = makeTextPDF(long)
        let course = CourseSummary(courseID: "55", code: "CIS 2400", name: "n", url: nil)
        let m = CanvasFileMetadata(displayName: "ps1.pdf", contentType: "application/pdf",
                                   updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let doc = try #require(CourseDocumentBuilder.file(
            metadata: m, fileID: "7", pdf: pdf, course: course,
            baseURL: URL(string: "https://canvas.upenn.edu")!))
        #expect(doc.kind == .file)
        #expect(doc.sourceID == "7")
        #expect(doc.title == "ps1.pdf")
        #expect(doc.url?.absoluteString == "https://canvas.upenn.edu/courses/55/files/7")
        #expect(doc.id == "file:55:7")
        #expect(doc.course == "CIS 2400")
        #expect(doc.updatedAt == m.updatedAt)
        #expect(doc.text.contains("Problem one"))
    }

    @Test("a scan or a short PDF yields no document")
    func scan() {
        let course = CourseSummary(courseID: "55", code: "C", name: "n", url: nil)
        let m = CanvasFileMetadata(displayName: "x.pdf", contentType: "application/pdf")
        let base = URL(string: "https://canvas.upenn.edu")!
        #expect(CourseDocumentBuilder.file(metadata: m, fileID: "7", pdf: makeTextPDF("too short"), course: course, baseURL: base) == nil)
        #expect(CourseDocumentBuilder.file(metadata: m, fileID: "7", pdf: Data("not a pdf".utf8), course: course, baseURL: base) == nil)
    }

    @Test("the runner counts, records every asked id, and stops on a dead session")
    func runner() async {
        let c = client()
        let pdf = makeTextPDF(String(repeating: "Read chapter three carefully. ", count: 4))
        Stub.routes["/api/v1/files/1"] = (200, ["Content-Type": "application/json"], meta(size: pdf.count, url: "https://canvas.upenn.edu/files/1/download"))
        Stub.routes["/files/1/download"] = (200, [:], pdf)
        Stub.routes["/api/v1/files/2"] = (200, ["Content-Type": "application/json"], meta(type: "image/png"))
        Stub.routes["/api/v1/files/3"] = (401, [:], Data("{}".utf8))
        Stub.routes["/api/v1/users/self"] = (401, [:], Data("{}".utf8))
        Stub.routes["/api/v1/files/4"] = (200, ["Content-Type": "application/json"], meta())
        let plan = ["1", "2", "3", "4"].map {
            AssignmentAttachmentFetch(fileID: $0, courseID: "9", assignmentSourceID: "a", dueAt: nil)
        }
        let course = CourseSummary(courseID: "9", code: "C", name: "n", url: nil)
        let out = await AssignmentAttachmentRunner.run(
            plan: plan, client: c, courses: [course], baseURL: URL(string: "https://canvas.upenn.edu")!)
        #expect(out.planned == 4)
        #expect(out.fetched == 1)
        #expect(out.documents.count == 1)
        #expect(out.skipped == 1)
        #expect(out.attempted.first?.kind == .pooled)
        #expect(out.attemptedIDs == ["1", "2"])
        #expect(out.firstFailure == "sessionExpired")
        #expect(!Stub.seen.contains("/api/v1/files/4"))
        #expect(out.summary == "planned 4 · fetched 1 · pooled 1 · skipped 1 · first failure sessionExpired")
    }

    @Test("a 401 on a live session skips that file and the run continues; users/self is asked once")
    func forbiddenFile() async {
        let c = client()
        Stub.routes["/api/v1/files/1"] = (401, [:], Data("{}".utf8))
        Stub.routes["/api/v1/files/2"] = (401, [:], Data("{}".utf8))
        Stub.routes["/api/v1/files/3"] = (200, ["Content-Type": "application/json"], meta(type: "image/png"))
        Stub.routes["/api/v1/users/self"] = (200, ["Content-Type": "application/json"], Data("{\"id\":1}".utf8))
        let plan = ["1", "2", "3"].map {
            AssignmentAttachmentFetch(fileID: $0, courseID: "9", assignmentSourceID: "a", dueAt: nil)
        }
        let course = CourseSummary(courseID: "9", code: "C", name: "n", url: nil)
        let out = await AssignmentAttachmentRunner.run(
            plan: plan, client: c, courses: [course], baseURL: URL(string: "https://canvas.upenn.edu")!)
        #expect(out.attemptedIDs == ["1", "2", "3"])
        #expect(out.skipped == 3)
        #expect(out.firstFailure == nil)
        #expect(Stub.seen.filter { $0 == "/api/v1/users/self" }.count == 1)
    }

    @Test("a Content-Length over the cap is refused from the headers alone")
    func headerCap() async throws {
        let c = client()
        Stub.routes["/api/v1/files/7"] = (200, ["Content-Type": "application/json"], meta(size: nil))
        Stub.routes["/files/7/download"] = (200, ["Content-Type": "application/pdf",
                                                  "Content-Length": String(CanvasFilesClient.maxBytes + 1)], Data())
        #expect(try await c.pdf(fileID: "7") == .skipped(.tooLarge))
    }

    @Test("a scan or short PDF is recorded as noText, a 403 as failed")
    func outcomeKinds() async {
        let c = client()
        let short = makeTextPDF("tiny")
        Stub.routes["/api/v1/files/1"] = (200, ["Content-Type": "application/json"], meta(size: short.count, url: "https://canvas.upenn.edu/files/1/download"))
        Stub.routes["/files/1/download"] = (200, [:], short)
        Stub.routes["/api/v1/files/2"] = (403, [:], Data("{}".utf8))
        Stub.routes["/api/v1/files/3"] = (200, ["Content-Type": "application/json"], meta(type: "image/png"))
        let plan = ["1", "2", "3"].map {
            AssignmentAttachmentFetch(fileID: $0, courseID: "9", assignmentSourceID: "a", dueAt: nil)
        }
        let out = await AssignmentAttachmentRunner.run(
            plan: plan, client: c, courses: [CourseSummary(courseID: "9", code: "C", name: "n", url: nil)],
            baseURL: URL(string: "https://canvas.upenn.edu")!)
        #expect(out.attempted.map(\.kind) == [.noText, .failed, .noText])
    }

    @Test("the deadline cancels a download that never finishes")
    func deadline() async {
        let c = client()
        Stub.routes["/api/v1/files/1"] = (200, ["Content-Type": "application/json"], meta(url: "https://canvas.upenn.edu/files/1/hang"))
        let plan = [AssignmentAttachmentFetch(fileID: "1", courseID: "9", assignmentSourceID: "a", dueAt: nil)]
        let start = Date()
        let out = await AssignmentAttachmentRunner.run(
            plan: plan, client: c, courses: [CourseSummary(courseID: "9", code: "C", name: "n", url: nil)],
            baseURL: URL(string: "https://canvas.upenn.edu")!, budget: 0.4)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(out.documents.isEmpty)
        #expect(out.firstFailure == nil)
    }

    @Test("the text cap is the extension's 60,000 and never splits a surrogate pair")
    func textCap() throws {
        #expect(CourseDocumentBuilder.fileTextCap == 60_000)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let js = root.appendingPathComponent("chrome-extension/src/core/canvasDocuments.js")
        if let src = try? String(contentsOf: js, encoding: .utf8) {
            #expect(src.contains("FILE_TEXT_MAX_CHARS = 60_000"))
        }
        let course = CourseSummary(courseID: "1", code: "C", name: "n", url: nil)
        let m = CanvasFileMetadata(displayName: "x.pdf", contentType: "application/pdf")
        let long = makeTextPDF(String(repeating: "Lorem ipsum dolor sit amet. ", count: 4))
        let doc = CourseDocumentBuilder.file(metadata: m, fileID: "1", pdf: long, course: course,
                                             baseURL: URL(string: "https://canvas.upenn.edu")!)
        #expect((doc?.text.utf16.count ?? 0) <= 60_000)
    }

    @Test("the collector's merge keeps file documents of a re-synced course")
    func mergeKeepsFiles() {
        let file = CourseDocument(courseID: "1", course: "C", kind: .file, sourceID: "7", title: "t",
                                  url: nil, text: "x")
        var kb = CourseKnowledgeBase.empty
        kb.documents = [file]
        kb.merge(courses: [], documents: [], resyncedCourseIDs: ["1"], preservingKinds: [.ed, .file], syncedAt: Date())
        #expect(kb.documents.count == 1)
    }

    @Test("the collector passes .file to its merge")
    func collectorSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/LowHangingFruitKit/Knowledge/CourseKnowledgeCollector.swift"), encoding: .utf8)
        #expect(src.contains("preservingKinds: [.ed, .file]"))
    }
}
