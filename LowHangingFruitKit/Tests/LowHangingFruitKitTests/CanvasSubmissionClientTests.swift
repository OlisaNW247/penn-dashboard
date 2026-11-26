import Foundation
import Testing
@testable import LowHangingFruitKit

/// `CanvasSubmissionClient` against a scripted Canvas. Never run against the
/// real one (Known gaps); these pin what the client sends and how it reads
/// each answer. Serialized: the stub's script and log are process-wide.
@Suite("Canvas submission client", .serialized)
struct CanvasSubmissionClientTests {
    static let base = URL(string: "https://canvas.example.edu")!

    // MARK: The stub

    enum Answer {
        case reply(Int, [String: String], String)
        case fail(URLError.Code)
    }

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var script: (URLRequest) -> Answer = { _ in .reply(404, [:], "{}") }
        private static let lock = NSLock()
        nonisolated(unsafe) private static var log: [String] = []
        nonisolated(unsafe) private static var seen: [URLRequest] = []

        static func reset(_ script: @escaping (URLRequest) -> Answer) {
            lock.lock(); log = []; seen = []; lock.unlock()
            self.script = script
        }
        static func note(_ event: String) { lock.lock(); log.append(event); lock.unlock() }
        static var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
        static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
        static var posts: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }

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
            Self.lock.lock()
            Self.seen.append(copy)
            Self.log.append("\(copy.httpMethod ?? "?") \(copy.url?.host ?? "")\(copy.url?.path ?? "")")
            Self.lock.unlock()
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

    // MARK: Fixtures

    static func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: "canvas.example.edu", .path: "/"])!
    }

    static let preflightText = #"{"submission_types":["online_text_entry","online_url","online_upload"],"locked_for_user":false,"can_submit":true,"submission":{"attempt":null,"submitted_at":null}}"#
    static let created = #"{"id":987,"attempt":1,"workflow_state":"submitted","submitted_at":"2026-11-10T10:00:00Z"}"#

    /// A Canvas that takes everything: preflight (with a fresh CSRF cookie),
    /// the submission, the verify, and the file slot and upload.
    static func happy(preflight: String = preflightText, post: Answer? = nil,
                      verify: Answer = .reply(200, [:], created)) -> (URLRequest) -> Answer {
        { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""
            if request.url?.host == "files.example.net" {
                return .reply(201, [:], #"{"id":555,"display_name":"essay.pdf"}"#)
            }
            if method == "GET", path.hasSuffix("/submissions/self") { return verify }
            if method == "GET" {
                return .reply(200, ["Set-Cookie": "_csrf_token=FRESH%2BTOKEN; path=/; secure"], preflight)
            }
            if path.hasSuffix("/submissions/self/files") {
                return .reply(200, [:], #"{"upload_url":"https://files.example.net/upload","upload_params":{"key":"k1","policy":"p","size":3},"file_param":"file"}"#)
            }
            return post ?? .reply(201, [:], created)
        }
    }

    func client(cookies: [HTTPCookie] = [cookie("canvas_session", "SESSION"), cookie("_csrf_token", "JAR")]) -> CanvasSubmissionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return CanvasSubmissionClient(session: URLSession(configuration: configuration), baseURL: Self.base, cookies: cookies)
    }

    func submit(_ payload: CanvasSubmissionClient.Payload, client c: CanvasSubmissionClient? = nil,
                before: () throws -> Void = { Stub.note("ATTEMPT") }) async -> CanvasSubmissionClient.Outcome {
        await (c ?? client()).submit(courseID: "12", assignmentID: "34", payload: payload, beforeFirstPost: before)
    }

    static func json(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    // MARK: Text and URL

    @Test("a text entry: one POST with the CSRF header and cookies, verified")
    func textHappy() async {
        Stub.reset(Self.happy())
        let outcome = await submit(.text("First line\nsecond line\n\nNew paragraph <b>"))
        #expect(outcome == .submitted(submissionID: "987", attempt: 1, verified: true))
        #expect(Stub.posts.count == 1)
        let post = Stub.posts[0]
        #expect(post.url?.path == "/api/v1/courses/12/assignments/34/submissions")
        // The preflight's fresh token wins over the jar's, decoded.
        #expect(post.value(forHTTPHeaderField: "X-CSRF-Token") == "FRESH+TOKEN")
        #expect(post.value(forHTTPHeaderField: "Cookie")?.contains("canvas_session=SESSION") == true)
        #expect(post.value(forHTTPHeaderField: "Origin") == "https://canvas.example.edu")
        let submission = Self.json(post)["submission"] as? [String: Any]
        #expect(submission?["submission_type"] as? String == "online_text_entry")
        #expect(submission?["body"] as? String == "<p>First line<br>second line</p><p>New paragraph &lt;b&gt;</p>")
        #expect(submission?.count == 2)
        // Preflight, attempt, POST, verify, in that order.
        #expect(Stub.events == [
            "GET canvas.example.edu/api/v1/courses/12/assignments/34", "ATTEMPT",
            "POST canvas.example.edu/api/v1/courses/12/assignments/34/submissions",
            "GET canvas.example.edu/api/v1/courses/12/assignments/34/submissions/self",
        ])
    }

    @Test("the jar's _csrf_token is the fallback when the preflight sets none")
    func jarToken() async {
        Stub.reset { request in
            if request.httpMethod == "GET", !(request.url?.path ?? "").hasSuffix("/self") {
                return .reply(200, [:], Self.preflightText)
            }
            return Self.happy()(request)
        }
        _ = await submit(.text("x"), client: client(cookies: [Self.cookie("canvas_session", "S"), Self.cookie("_csrf_token", "JAR%3D")]))
        #expect(Stub.posts.first?.value(forHTTPHeaderField: "X-CSRF-Token") == "JAR=")
    }

    @Test("no CSRF token anywhere: refused before the attempt, nothing posted")
    func noToken() async {
        Stub.reset { request in
            request.httpMethod == "GET" ? .reply(200, [:], Self.preflightText) : .reply(201, [:], Self.created)
        }
        let outcome = await submit(.text("x"), client: client(cookies: [Self.cookie("canvas_session", "S")]))
        #expect(outcome == .refused(.noCSRF))
        #expect(Stub.posts.isEmpty)
        #expect(!Stub.events.contains("ATTEMPT"))
    }

    @Test("a URL submission sends online_url and the link")
    func urlBody() async throws {
        Stub.reset(Self.happy())
        let outcome = await submit(.url(try #require(URL(string: "https://github.com/me/repo"))))
        #expect(outcome == .submitted(submissionID: "987", attempt: 1, verified: true))
        let submission = Self.json(Stub.posts[0])["submission"] as? [String: Any]
        #expect(submission?["submission_type"] as? String == "online_url")
        #expect(submission?["url"] as? String == "https://github.com/me/repo")
    }

    // MARK: Files

    @Test("a file: slot POST on Canvas, upload with no cookie or CSRF, then file_ids")
    func fileTwoStep() async {
        Stub.reset(Self.happy())
        let outcome = await submit(.file(name: "essay.pdf", mimeType: "application/pdf", data: Data("pdf".utf8)))
        #expect(outcome == .submitted(submissionID: "987", attempt: 1, verified: true))
        #expect(Stub.posts.count == 3)
        let slot = Stub.posts[0], upload = Stub.posts[1], submission = Stub.posts[2]
        #expect(slot.url?.path == "/api/v1/courses/12/assignments/34/submissions/self/files")
        #expect(slot.value(forHTTPHeaderField: "X-CSRF-Token") == "FRESH+TOKEN")
        let slotBody = Self.json(slot)
        #expect(slotBody["name"] as? String == "essay.pdf")
        #expect(slotBody["size"] as? Int == 3)
        #expect(slotBody["content_type"] as? String == "application/pdf")

        #expect(upload.url?.host == "files.example.net")
        #expect(upload.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(upload.value(forHTTPHeaderField: "X-CSRF-Token") == nil)
        let text = String(decoding: upload.httpBody ?? Data(), as: UTF8.self)
        #expect(text.contains("name=\"key\"\r\n\r\nk1\r\n"))
        #expect(text.contains("name=\"size\"\r\n\r\n3\r\n"))
        #expect(text.contains("name=\"file\"; filename=\"essay.pdf\"\r\nContent-Type: application/pdf\r\n\r\npdf\r\n"))
        // The file part comes after every param.
        let fileAt = text.range(of: "filename=")!.lowerBound
        #expect(text.range(of: "name=\"policy\"")!.lowerBound < fileAt)

        let body = Self.json(submission)["submission"] as? [String: Any]
        #expect(body?["submission_type"] as? String == "online_upload")
        #expect(body?["file_ids"] as? [Int] == [555])
        // The attempt is recorded before the first POST of any kind.
        let attemptAt = Stub.events.firstIndex(of: "ATTEMPT")!
        let firstPost = Stub.events.firstIndex { $0.hasPrefix("POST") }!
        #expect(attemptAt < firstPost)
    }

    @Test("an upload answered with a redirect is confirmed with one GET")
    func fileConfirm() async {
        Stub.reset { request in
            if request.url?.host == "files.example.net" {
                return .reply(303, ["Location": "https://canvas.example.edu/api/v1/files/555/create_success?uuid=u"], "")
            }
            if request.url?.path == "/api/v1/files/555/create_success" {
                return .reply(200, [:], #"{"id":555}"#)
            }
            return Self.happy()(request)
        }
        let outcome = await submit(.file(name: "essay.pdf", mimeType: "application/pdf", data: Data("pdf".utf8)))
        #expect(outcome == .submitted(submissionID: "987", attempt: 1, verified: true))
        #expect(Stub.events.contains("GET canvas.example.edu/api/v1/files/555/create_success"))
        // Canvas's own origin: the confirm carries the session.
        let confirm = Stub.requests.first { $0.url?.path == "/api/v1/files/555/create_success" }
        #expect(confirm?.value(forHTTPHeaderField: "Cookie")?.contains("canvas_session") == true)
    }

    @Test("a failed upload is definite: no submission POST")
    func uploadFails() async {
        Stub.reset { request in
            request.url?.host == "files.example.net" ? .reply(500, [:], "{}") : Self.happy()(request)
        }
        let outcome = await submit(.file(name: "essay.pdf", mimeType: "application/pdf", data: Data("pdf".utf8)))
        #expect(outcome == .failed(errorClass: "upload"))
        #expect(!Stub.posts.contains { $0.url?.path.hasSuffix("/submissions") == true })
    }

    @Test("a file whose extension the assignment does not allow is refused")
    func extensionRefused() async {
        Stub.reset(Self.happy(preflight: #"{"submission_types":["online_upload"],"allowed_extensions":["docx"],"locked_for_user":false}"#))
        let outcome = await submit(.file(name: "essay.pdf", mimeType: "application/pdf", data: Data("pdf".utf8)))
        #expect(outcome == .refused(.unsupportedType))
        #expect(Stub.posts.isEmpty)
    }

    @Test("extensions are normalised like the sheet's: a leading dot and upper case still match")
    func extensionNormalised() async {
        Stub.reset(Self.happy(preflight: #"{"submission_types":["online_upload"],"allowed_extensions":[".PDF"],"locked_for_user":false}"#))
        let outcome = await submit(.file(name: "essay.pdf", mimeType: "application/pdf", data: Data("pdf".utf8)))
        #expect(outcome == .submitted(submissionID: "987", attempt: 1, verified: true))
        #expect(CanvasSubmissionClient.accepts(types: ["online_upload"], payload: .file(name: "a.Pdf", mimeType: "", data: Data()),
                                               allowedExtensions: [" .pdf "]))
    }

    // MARK: The early read

    @Test("fetchRules is the preflight GET alone: nothing posted, no attempt recorded")
    func fetchRulesGETOnly() async throws {
        Stub.reset(Self.happy(preflight: #"{"submission_types":["online_upload"],"allowed_extensions":[".PDF","docx"],"locked_for_user":false,"can_submit":true}"#))
        let store = AgentSubmitAttemptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchRules-\(UUID().uuidString)/a.json"))
        let answer = await client().fetchRules(courseID: "12", assignmentID: "34")
        #expect(answer == .rules(CanvasSubmissionRules(submissionTypes: ["online_upload"], allowedExtensions: ["pdf", "docx"], canSubmit: true)))
        #expect(Stub.requests.count == 1)
        #expect(Stub.requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(Stub.requests.first?.url?.path == "/api/v1/courses/12/assignments/34")
        #expect(Stub.posts.isEmpty)
        #expect(!Stub.events.contains("ATTEMPT"))
        #expect(store.all().isEmpty)

        Stub.reset { _ in .reply(401, [:], "{}") }
        #expect(await client().fetchRules(courseID: "12", assignmentID: "34") == .refused(.sessionDead))
        Stub.reset { _ in .fail(.notConnectedToInternet) }
        #expect(await client().fetchRules(courseID: "12", assignmentID: "34") == .refused(.offline))
        Stub.reset { _ in .reply(500, [:], "{}") }
        #expect(await client().fetchRules(courseID: "12", assignmentID: "34") == .refused(.preflightFailed))
        Stub.reset(Self.happy())
        #expect(await client().fetchRules(courseID: "x", assignmentID: "34") == .refused(.missingIDs))
        #expect(Stub.requests.isEmpty)
    }

    // MARK: Refusals before anything is posted

    @Test("quizzes, external tools, media and none are refused up front", arguments: [
        #"["online_quiz"]"#, #"["external_tool"]"#, #"["media_recording"]"#, #"["none"]"#, #"["on_paper"]"#, "[]",
    ])
    func unsupported(types: String) async {
        Stub.reset(Self.happy(preflight: #"{"submission_types":\#(types),"locked_for_user":false}"#))
        #expect(await submit(.text("x")) == .refused(.unsupportedType))
        #expect(Stub.posts.isEmpty)
        #expect(!Stub.events.contains("ATTEMPT"))
    }

    @Test("a locked assignment, or can_submit false, is refused")
    func locked() async {
        Stub.reset(Self.happy(preflight: #"{"submission_types":["online_text_entry"],"locked_for_user":true}"#))
        #expect(await submit(.text("x")) == .refused(.locked))
        Stub.reset(Self.happy(preflight: #"{"submission_types":["online_text_entry"],"locked_for_user":false,"can_submit":false}"#))
        #expect(await submit(.text("x")) == .refused(.locked))
        #expect(Stub.posts.isEmpty)
    }

    @Test("a dead session at preflight is refused; so are bad ids")
    func sessionAndIDs() async {
        Stub.reset { _ in .reply(401, [:], "{}") }
        #expect(await submit(.text("x")) == .refused(.sessionDead))
        Stub.reset { _ in .reply(200, ["Content-Type": "text/html"], "<html>") }
        #expect(await submit(.text("x")) == .refused(.sessionDead))
        Stub.reset(Self.happy())
        let bad = await client().submit(courseID: "12a", assignmentID: "34", payload: .text("x"), beforeFirstPost: {})
        #expect(bad == .refused(.missingIDs))
        #expect(Stub.requests.isEmpty)
    }

    @Test("no attempt record, no POST")
    func attemptThrows() async {
        struct Boom: Error {}
        Stub.reset(Self.happy())
        let outcome = await submit(.text("x"), before: { throw Boom() })
        #expect(outcome == .refused(.attemptNotRecorded))
        #expect(Stub.posts.isEmpty)
    }

    // MARK: After the POST

    @Test("a 422 is a definite failure and is never retried")
    func noRetry() async {
        Stub.reset(Self.happy(post: .reply(422, ["Set-Cookie": "_csrf_token=NEW; path=/"], #"{"errors":"x"}"#)))
        #expect(await submit(.text("x")) == .failed(errorClass: "rejected_422"))
        #expect(Stub.posts.count == 1)
    }

    @Test("a 5xx, a timeout or a lost connection after the POST is indeterminate")
    func indeterminate() async {
        Stub.reset(Self.happy(post: .reply(502, [:], "{}")))
        #expect(await submit(.text("x")) == .indeterminate)
        Stub.reset(Self.happy(post: .fail(.timedOut)))
        #expect(await submit(.text("x")) == .indeterminate)
        Stub.reset(Self.happy(post: .fail(.networkConnectionLost)))
        #expect(await submit(.text("x")) == .indeterminate)
        // 2xx with no id: Canvas answered, but not with a submission.
        Stub.reset(Self.happy(post: .reply(200, [:], "{}")))
        #expect(await submit(.text("x")) == .indeterminate)
        #expect(Stub.posts.count == 1)
    }

    @Test("a POST that never left the phone is a definite failure")
    func neverSent() async {
        Stub.reset(Self.happy(post: .fail(.notConnectedToInternet)))
        #expect(await submit(.text("x")) == .failed(errorClass: "offline"))
        Stub.reset(Self.happy(post: .reply(401, [:], "{}")))
        #expect(await submit(.text("x")) == .failed(errorClass: "session"))
    }

    @Test("a verify that disagrees or fails keeps the submission, unverified")
    func verifyDisagrees() async {
        Stub.reset(Self.happy(verify: .reply(200, [:], #"{"attempt":null,"submitted_at":null}"#)))
        #expect(await submit(.text("x")) == .submitted(submissionID: "987", attempt: 1, verified: false))
        Stub.reset(Self.happy(verify: .fail(.timedOut)))
        #expect(await submit(.text("x")) == .submitted(submissionID: "987", attempt: 1, verified: false))
    }

    @Test("verifyAgrees compares submitted_at and the attempt")
    func verifyRule() {
        let at = "2026-11-10T10:00:00Z"
        #expect(CanvasSubmissionClient.verifyAgrees(["submitted_at": at, "attempt": 2], postedAttempt: 2, priorAttempt: 1))
        #expect(!CanvasSubmissionClient.verifyAgrees(["submitted_at": at, "attempt": 1], postedAttempt: 2, priorAttempt: 1))
        #expect(CanvasSubmissionClient.verifyAgrees(["submitted_at": at, "attempt": 2], postedAttempt: nil, priorAttempt: 1))
        #expect(!CanvasSubmissionClient.verifyAgrees(["submitted_at": at, "attempt": 1], postedAttempt: nil, priorAttempt: 1))
        #expect(!CanvasSubmissionClient.verifyAgrees(["attempt": 2], postedAttempt: 2, priorAttempt: nil))
        #expect(CanvasSubmissionClient.verifyAgrees(["submitted_at": at], postedAttempt: nil, priorAttempt: nil))
    }

    @Test("htmlBody escapes everything and keeps paragraphs")
    func html() {
        #expect(CanvasSubmissionClient.htmlBody("a & \"b\"") == "<p>a &amp; &quot;b&quot;</p>")
        #expect(CanvasSubmissionClient.htmlBody("<img src=x onerror=1>") == "<p>&lt;img src=x onerror=1&gt;</p>")
        #expect(CanvasSubmissionClient.htmlBody("one\r\ntwo\n\n\n\nthree") == "<p>one<br>two</p><p>three</p>")
    }
}
