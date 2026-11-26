import Foundation
import Testing
@testable import LowHangingFruitKit

/// The v11 test pass of 2026-11-11 (docs/V11_TEST_PHONE_2026-11-11.md, §1).
///
/// `AgentDraftSubmitterTests` drives the submitter with a fake `submit`
/// closure, and `CanvasSubmissionClientTests` drives the client with a fake
/// `beforeFirstPost`. Neither proves the two together: that the record the
/// real store writes is **on disk at the moment Canvas sees the first POST**,
/// for every payload the phone can send. Here the real submitter calls the
/// real client over a scripted Canvas and the real file-backed store, and the
/// script itself reads the store's file when a POST arrives. Serialized: the
/// stub's script and log are process-wide.
@Suite("v11 test pass: the submit rules end to end", .serialized)
struct V11SubmitRulesTests {
    static let base = URL(string: "https://canvas.example.edu")!

    enum Answer {
        case reply(Int, [String: String], String)
        case fail(URLError.Code)
    }

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var script: (URLRequest) -> Answer = { _ in .reply(404, [:], "{}") }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var seen: [URLRequest] = []

        static func reset(_ script: @escaping (URLRequest) -> Answer) {
            lock.lock(); seen = []; lock.unlock()
            self.script = script
        }
        static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
        static var posts: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
        /// POSTs to Canvas's own host (the file store's upload is not a Canvas POST).
        static var canvasPosts: [URLRequest] { posts.filter { $0.url?.host == base.host } }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var copy = request
            if copy.httpBody == nil, let stream = copy.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                stream.close()
                copy.httpBody = data
            }
            Self.lock.lock(); Self.seen.append(copy); Self.lock.unlock()
            switch Self.script(copy) {
            case let .reply(status, headers, body):
                var all = ["Content-Type": "application/json"]
                for (k, v) in headers { all[k] = v }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            case let .fail(code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        }
        override func stopLoading() {}
    }

    /// Thread-safe "what did the store hold when the first Canvas POST came in".
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _recordAtFirstPost: Bool?
        func note(_ present: Bool) { lock.lock(); if _recordAtFirstPost == nil { _recordAtFirstPost = present }; lock.unlock() }
        var recordAtFirstPost: Bool? { lock.lock(); defer { lock.unlock() }; return _recordAtFirstPost }
    }

    static let preflightAll = #"{"submission_types":["online_text_entry","online_url","online_upload"],"locked_for_user":false,"can_submit":true,"submission":{"attempt":null,"submitted_at":null}}"#
    static let created = #"{"id":357257138,"attempt":1,"workflow_state":"submitted","submitted_at":"2026-11-11T03:52:00Z"}"#

    static func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: "canvas.example.edu", .path: "/"])!
    }

    static let item = AgentSnapshot.WorkItem(
        id: "event-assignment-34", course: "PHYS 0151", title: "Problem Set 7", kind: .assignment, dueAt: nil,
        done: false, noSubmission: false, url: nil, source: "canvas",
        canvasAssignmentID: "34", canvasCourseID: "12")

    /// A Canvas that takes everything. `post` overrides the submission POST's
    /// answer; `verify` the verify GET's. Every Canvas POST consults the
    /// store's file through `probe`, which is the point of this suite.
    static func canvas(store: AgentSubmitAttemptStore, draftID: String, probe: Probe,
                       preflight: String = preflightAll, post: Answer? = nil,
                       verify: Answer = .reply(200, [:], created)) -> (URLRequest) -> Answer {
        { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""
            if request.url?.host == "files.example.net" {
                return .reply(201, [:], #"{"id":555,"display_name":"x.pdf"}"#)
            }
            if method == "POST" { probe.note(store.record(for: draftID) != nil) }
            if method == "GET", path.hasSuffix("/submissions/self") { return verify }
            if method == "GET" {
                return .reply(200, ["Set-Cookie": "_csrf_token=FRESH%2BTOKEN; path=/; secure"], preflight)
            }
            if path.hasSuffix("/submissions/self/files") {
                return .reply(200, [:], #"{"upload_url":"https://files.example.net/upload","upload_params":{"key":"k1"},"file_param":"file"}"#)
            }
            return post ?? .reply(201, [:], created)
        }
    }

    static func client() -> CanvasSubmissionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return CanvasSubmissionClient(session: URLSession(configuration: configuration), baseURL: base,
                                      cookies: [cookie("canvas_session", "SESSIONSECRET"), cookie("_csrf_token", "JAR")])
    }

    static func store() -> AgentSubmitAttemptStore {
        AgentSubmitAttemptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("V11SubmitRules-\(UUID().uuidString)/attempts.json"))
    }

    /// The live app's wiring of `AgentDraftSubmitter.run` (AppState+AgentDrafts
    /// `submitAgentDraft`), with the real client.
    static func run(_ draft: AgentDraft, store: AgentSubmitAttemptStore, file: Data? = nil,
                    pdf: RenderedDraftPDF? = nil, item: AgentSnapshot.WorkItem? = item,
                    reports: ReportLog = ReportLog()) async -> AgentSubmitResult {
        let c = client()
        return await AgentDraftSubmitter.run(
            draft: draft, item: item, store: store,
            loadFile: { file },
            submit: { courseID, assignmentID, payload, before in
                await c.submit(courseID: courseID, assignmentID: assignmentID, payload: payload, beforeFirstPost: before)
            },
            report: { reports.add($0); return true },
            pdf: pdf)
    }

    final class ReportLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AgentDraftDecision] = []
        func add(_ d: AgentDraftDecision) { lock.lock(); items.append(d); lock.unlock() }
        var all: [AgentDraftDecision] { lock.lock(); defer { lock.unlock() }; return items }
    }

    enum Kind: String, CaseIterable { case text, url, file, renderedPDF }

    static func draft(_ kind: Kind, id: String = "smd_\(UUID().uuidString.prefix(8))") -> (AgentDraft, Data?, RenderedDraftPDF?) {
        switch kind {
        case .text:
            return (AgentDraft(id: id, assignmentID: item.id, kind: .text, body: "My answer."), nil, nil)
        case .url:
            return (AgentDraft(id: id, assignmentID: item.id, kind: .url, url: "https://github.com/me/project"), nil, nil)
        case .file:
            return (AgentDraft(id: id, assignmentID: item.id, kind: .file, fileName: "ps7.pdf",
                               mimeType: "application/pdf", fileBytes: 9), Data("%PDF-1.4\n".utf8), nil)
        case .renderedPDF:
            return (AgentDraft(id: id, assignmentID: item.id, kind: .text, body: "# Problem 1\n\nWork."),
                    nil, RenderedDraftPDF(name: "Problem Set 7.pdf", data: Data("%PDF-1.7 rendered".utf8)))
        }
    }

    // MARK: The record before the first POST

    @Test("for every payload the record is on disk when Canvas sees the first POST, and one submission POST goes out",
          arguments: Kind.allCases)
    func recordBeforeFirstPost(kind: Kind) async throws {
        let s = Self.store(), probe = Probe()
        let (draft, file, pdf) = Self.draft(kind)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe))
        let result = await Self.run(draft, store: s, file: file, pdf: pdf)
        #expect(result == .submitted(verified: true))
        #expect(probe.recordAtFirstPost == true, "the attempt record must exist before any POST")
        let submissionPosts = Stub.canvasPosts.filter { !($0.url?.path.hasSuffix("/files") ?? false) }
        #expect(submissionPosts.count == 1)
        // A fresh instance over the same file sees the outcome: it is on disk.
        let reread = try #require(s.record(for: draft.id))
        #expect(reread.outcome == .submitted && reread.canvasSubmissionID == "357257138")

        // The payload Canvas got is the one the draft named.
        let body = (try? JSONSerialization.jsonObject(with: submissionPosts.first?.httpBody ?? Data())) as? [String: Any]
        let type = (body?["submission"] as? [String: Any])?["submission_type"] as? String
        switch kind {
        case .text: #expect(type == "online_text_entry")
        case .url: #expect(type == "online_url")
        case .file, .renderedPDF: #expect(type == "online_upload")
        }
    }

    @Test("a second run with a record is refused before any request at all", arguments: Kind.allCases)
    func secondRunRefused(kind: Kind) async {
        let s = Self.store(), probe = Probe()
        let (draft, file, pdf) = Self.draft(kind)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe))
        _ = await Self.run(draft, store: s, file: file, pdf: pdf)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe))
        let second = await Self.run(draft, store: s, file: file, pdf: pdf)
        #expect(second == .checkCanvas)
        #expect(Stub.requests.isEmpty, "not even the preflight GET")
    }

    @Test("a timeout after the POST leaves the record, says check canvas, and never retries")
    func timeoutAfterPost() async throws {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe, post: .fail(.timedOut)))
        let reports = ReportLog()
        let result = await Self.run(draft, store: s, reports: reports)
        #expect(result == .checkCanvas)
        #expect(Stub.canvasPosts.count == 1, "exactly one POST: never retried")
        #expect(try #require(s.record(for: draft.id)).outcome == .indeterminate)
        #expect(reports.all.isEmpty, "only the student, looking at Canvas, knows: nothing is reported")
        #expect(AgentDraftSubmitter.pendingReport(for: try #require(s.record(for: draft.id))) == nil)

        // And a relaunch (a new store over the same file) still refuses.
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe))
        #expect(await Self.run(draft, store: s) == .checkCanvas)
        #expect(Stub.requests.isEmpty)
    }

    @Test("a POST that never left the phone is a definite failure, recorded and reported, one POST")
    func neverSent() async throws {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe, post: .fail(.notConnectedToInternet)))
        let reports = ReportLog()
        #expect(await Self.run(draft, store: s, reports: reports) == .failed)
        #expect(Stub.canvasPosts.count == 1)
        #expect(try #require(s.record(for: draft.id)).outcome == .failed)
        #expect(reports.all == [.failed(errorClass: "offline")])
    }

    @Test("401, 403, 422 and 500 on the POST map to the documented outcomes", arguments: [
        (401, "failed:session"), (403, "failed:rejected_403"), (422, "failed:rejected_422"),
        (500, "indeterminate"), (502, "indeterminate"), (503, "indeterminate"),
    ])
    func statusMapping(status: Int, expected: String) async throws {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe, post: .reply(status, [:], #"{"errors":[]}"#)))
        let reports = ReportLog()
        let result = await Self.run(draft, store: s, reports: reports)
        let record = try #require(s.record(for: draft.id))
        #expect(Stub.canvasPosts.count == 1, "never retried")
        if expected == "indeterminate" {
            #expect(result == .checkCanvas)
            #expect(record.outcome == .indeterminate)
            #expect(reports.all.isEmpty)
        } else {
            let errorClass = String(expected.dropFirst("failed:".count))
            #expect(result == .failed)
            #expect(record.outcome == .failed && record.errorClass == errorClass)
            #expect(reports.all == [.failed(errorClass: errorClass)])
        }
    }

    @Test("a 2xx with no submission id is indeterminate, never submitted")
    func createdWithoutID() async throws {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe, post: .reply(200, [:], #"{"ok":true}"#)))
        #expect(await Self.run(draft, store: s) == .checkCanvas)
        #expect(try #require(s.record(for: draft.id)).outcome == .indeterminate)
    }

    @Test("a verify with no submitted_at keeps the submission, unverified, and still reports it", arguments: [
        Answer.reply(200, [:], #"{"id":357257138,"attempt":1,"submitted_at":null}"#),
        .reply(200, [:], #"{"id":357257138,"attempt":0}"#),
        .reply(500, [:], "{}"),
        .fail(.timedOut),
    ])
    func verifyDisagrees(verify: Answer) async throws {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe, verify: verify))
        let reports = ReportLog()
        #expect(await Self.run(draft, store: s, reports: reports) == .submitted(verified: false))
        #expect(try #require(s.record(for: draft.id)).outcome == .submitted)
        #expect(reports.all == [.submitted(canvasSubmissionID: "357257138", attempt: 1)])
        #expect(Stub.canvasPosts.count == 1)
    }

    @Test("a failed upload after the record is a definite failure with no submission POST")
    func uploadFailsAfterRecord() async throws {
        let s = Self.store(), probe = Probe()
        let (draft, file, _) = Self.draft(.file)
        let happy = Self.canvas(store: s, draftID: draft.id, probe: probe)
        Stub.reset { request in
            if request.url?.host == "files.example.net" { return .reply(500, [:], "{}") }
            return happy(request)
        }
        #expect(await Self.run(draft, store: s, file: file) == .failed)
        #expect(try #require(s.record(for: draft.id)).outcome == .failed)
        #expect(Stub.canvasPosts.allSatisfy { $0.url?.path.hasSuffix("/files") == true }, "only the slot POST")
    }

    @Test("refusals at preflight write no record and leave the draft sendable later", arguments: [
        #"{"submission_types":["on_paper"]}"#,
        #"{"submission_types":["online_text_entry"],"locked_for_user":true}"#,
        #"{"submission_types":["online_text_entry"],"can_submit":false}"#,
    ])
    func preflightRefusals(preflight: String) async {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe, preflight: preflight))
        let result = await Self.run(draft, store: s)
        if case .refused = result {} else { Issue.record("expected a refusal, got \(result)") }
        #expect(s.record(for: draft.id) == nil)
        #expect(Stub.posts.isEmpty)
    }

    @Test("a store whose file cannot be read refuses before any POST, end to end")
    func unreadableStoreRefuses() async throws {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        // Corrupt the file: the store must not read it as "no record".
        let url = Self.fileURL(of: s)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe))
        let result = await Self.run(draft, store: s)
        #expect(result == .refused(.attemptNotRecorded))
        #expect(Stub.posts.isEmpty)
    }

    // MARK: fetchRules

    @Test("fetchRules records nothing and posts nothing, whatever Canvas answers", arguments: [
        Answer.reply(200, [:], preflightAll), .reply(401, [:], "{}"), .reply(500, [:], "{}"), .fail(.timedOut),
    ])
    func fetchRulesIsReadOnly(answer: Answer) async {
        let s = Self.store()
        Stub.reset { _ in answer }
        _ = await Self.client().fetchRules(courseID: "12", assignmentID: "34")
        #expect(Stub.posts.isEmpty)
        #expect(Stub.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(s.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Self.fileURL(of: s).path))
    }

    // MARK: Concurrency

    @Test("two submits of the same draft at once: one record, at most one submission POST")
    func concurrentSubmits() async throws {
        let s = Self.store(), probe = Probe()
        let (draft, _, _) = Self.draft(.text)
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe))
        async let a = Self.run(draft, store: s)
        async let b = Self.run(draft, store: s)
        let results = await [a, b]
        let submissionPosts = Stub.canvasPosts.filter { !($0.url?.path.hasSuffix("/files") ?? false) }
        #expect(submissionPosts.count == 1)
        #expect(results.filter { $0 == .submitted(verified: true) }.count == 1)
        #expect(results.contains(.checkCanvas))
        #expect(s.all().count == 1)
    }

    // MARK: Helpers

    /// The store keeps its URL private; the tests build it, so they know it.
    static func fileURL(of store: AgentSubmitAttemptStore) -> URL {
        Mirror(reflecting: store).children.first { $0.label == "fileURL" }!.value as! URL
    }
}
