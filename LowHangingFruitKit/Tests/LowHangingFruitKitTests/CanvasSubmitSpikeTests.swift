import Foundation
import Testing
@testable import LowHangingFruitKit

/// The Phase 0 submit spike: pure request shapes and failure classes, plus
/// one full run through a `URLProtocol` stub proving no log line carries the
/// CSRF value while the POST still sends it. Serialized because the stub's
/// state is process-wide static.
@Suite("Canvas submit spike", .serialized)
struct CanvasSubmitSpikeTests {
    private static let base = URL(string: "https://canvas.example.edu")!

    private static func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: "canvas.example.edu", .path: "/",
        ])!
    }

    // MARK: CSRF

    @Test func csrfFromCookies() {
        let jar = [Self.cookie("canvas_session", "s"), Self.cookie("_csrf_token", "abc")]
        #expect(CanvasSubmitSpike.csrfToken(fromCookies: jar) == "abc")
        #expect(CanvasSubmitSpike.csrfToken(fromCookies: [Self.cookie("canvas_session", "s")]) == nil)
        #expect(CanvasSubmitSpike.csrfToken(fromCookies: [Self.cookie("_csrf_token", "abc%2Fdef%3D")]) == "abc/def=")
    }

    @Test func csrfFromSetCookieLines() {
        #expect(CanvasSubmitSpike.csrfToken(fromSetCookieHeaders: ["_csrf_token=abc; path=/; secure"]) == "abc")
        #expect(CanvasSubmitSpike.csrfToken(fromSetCookieHeaders: ["_csrf_token=abc%2Fdef%3D; path=/; secure"]) == "abc/def=")
        #expect(CanvasSubmitSpike.csrfToken(fromSetCookieHeaders: []) == nil)
        #expect(CanvasSubmitSpike.csrfToken(fromSetCookieHeaders: [
            "canvas_session=x; path=/; secure", "log_session_id=y; path=/",
        ]) == nil)
        #expect(CanvasSubmitSpike.csrfToken(fromSetCookieHeaders: [
            "canvas_session=x; path=/", "_csrf_token=tok; path=/",
        ]) == "tok")
    }

    // MARK: URLs

    @Test func urls() {
        let pre = CanvasSubmitSpike.preflightURL(baseURL: Self.base, courseID: "12", assignmentID: "34")
        #expect(pre.absoluteString == "https://canvas.example.edu/api/v1/courses/12/assignments/34?include%5B%5D=submission&include%5B%5D=can_submit"
            || pre.absoluteString == "https://canvas.example.edu/api/v1/courses/12/assignments/34?include[]=submission&include[]=can_submit")
        #expect(pre.path == "/api/v1/courses/12/assignments/34")
        #expect(CanvasSubmitSpike.submissionsURL(baseURL: Self.base, courseID: "12", assignmentID: "34").absoluteString
            == "https://canvas.example.edu/api/v1/courses/12/assignments/34/submissions")
        #expect(CanvasSubmitSpike.verifyURL(baseURL: Self.base, courseID: "12", assignmentID: "34").absoluteString
            == "https://canvas.example.edu/api/v1/courses/12/assignments/34/submissions/self")
    }

    // MARK: Request shape

    @Test func postShape() {
        let url = CanvasSubmitSpike.submissionsURL(baseURL: Self.base, courseID: "1", assignmentID: "2")
        let request = CanvasSubmitSpike.textEntryRequest(
            url: url, body: "spike", csrfToken: "TOK", cookies: [Self.cookie("canvas_session", "s")], origin: Self.base
        )
        #expect(request.httpMethod == "POST")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-CSRF-Token") == "TOK")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://canvas.example.edu")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://canvas.example.edu/")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("canvas_session=s") == true)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body == #"{"submission":{"body":"<p>spike<\/p>","submission_type":"online_text_entry"}}"#
            || body == #"{"submission":{"body":"<p>spike</p>","submission_type":"online_text_entry"}}"#)
    }

    @Test func postBodyIsParsedAndEscaped() throws {
        let url = CanvasSubmitSpike.submissionsURL(baseURL: Self.base, courseID: "1", assignmentID: "2")
        let request = CanvasSubmitSpike.textEntryRequest(url: url, body: "a < b & c", csrfToken: "T", cookies: [], origin: Self.base)
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
        let submission = object?["submission"] as? [String: String]
        #expect(submission?["submission_type"] == "online_text_entry")
        #expect(submission?["body"] == "<p>a &lt; b &amp; c</p>")
        #expect(submission?.count == 2)
    }

    @Test func getShape() {
        let request = CanvasSubmitSpike.getRequest(url: Self.base, cookies: [Self.cookie("canvas_session", "s")])
        #expect(request.httpMethod == "GET")
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("canvas_session=s") == true)
    }

    // MARK: Classification

    private func classify(_ status: Int, type: String? = "application/json; charset=utf-8", body: String = "{}") -> CanvasSubmitSpike.Outcome {
        CanvasSubmitSpike.classify(status: status, contentType: type, body: Data(body.utf8))
    }

    @Test func classifyCases() {
        #expect(classify(201, body: #"while(1);{"attempt":3,"workflow_state":"submitted","submitted_at":"2026-11-08T10:00:00Z"}"#)
            == .created(attempt: 3, workflowState: "submitted", submittedAt: "2026-11-08T10:00:00Z"))
        #expect(classify(200, body: "{}") == .created(attempt: nil, workflowState: nil, submittedAt: nil))
        #expect(classify(422, body: #"{"errors":"invalid"}"#) == .csrfOrValidation(message: #"{"errors":"invalid"}"#))
        #expect(classify(401) == .sessionDead)
        #expect(classify(200, type: "text/html; charset=utf-8", body: "<html>") == .sessionDead)
        #expect(classify(302, type: nil, body: "") == .sessionDead)
        let max = #"{"attempt":["you have reached the maximum number of attempts"]}"#
        #expect(classify(400, body: max) == .refused(status: 400, message: max))
        #expect(classify(403, body: "{}") == .refused(status: 403, message: "{}"))
        #expect(classify(500) == .other(status: 500))
    }

    // MARK: Full run

    fileprivate final class Stub: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var seen: [URLRequest] = []
        nonisolated(unsafe) private static var postStatus = 201

        static func reset(postStatus: Int) {
            lock.lock(); defer { lock.unlock() }
            seen = []
            self.postStatus = postStatus
        }
        static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            var copy = request
            if copy.httpBody == nil, let stream = copy.httpBodyStream {
                stream.open()
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
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
            let status = Self.postStatus
            Self.lock.unlock()

            var headers = ["Content-Type": "application/json"]
            var body = "{}"
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST" {
                body = status == 201 ? #"{"attempt":1,"workflow_state":"submitted","submitted_at":"2026-11-08T10:00:00Z"}"# : #"{"errors":"bad"}"#
                if status != 201 { headers["Set-Cookie"] = "_csrf_token=SECRETVALUE2; path=/" }
                respond(status, headers, body)
            } else if path.hasSuffix("/submissions/self") {
                respond(200, headers, #"{"attempt":1,"workflow_state":"submitted","submitted_at":"2026-11-08T10:00:00Z"}"#)
            } else {
                headers["Set-Cookie"] = "_csrf_token=SECRETVALUE; path=/; secure"
                respond(200, headers, #"{"submission_types":["online_text_entry"],"locked_for_user":false,"can_submit":true,"allowed_attempts":-1}"#)
            }
        }

        private func respond(_ status: Int, _ headers: [String: String], _ body: String) {
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func run(postStatus: Int) async -> [String] {
        Stub.reset(postStatus: postStatus)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let runner = CanvasSubmitSpikeRunner(
            session: URLSession(configuration: configuration),
            baseURL: Self.base,
            cookies: [Self.cookie("canvas_session", "SESSIONVALUE")]
        )
        let lines = Lines()
        await runner.run(courseID: "1", assignmentID: "2") { lines.add($0) }
        return lines.all
    }

    @Test func fullRunNeverLogsTheToken() async {
        let lines = await run(postStatus: 201)
        #expect(lines.allSatisfy { $0.hasPrefix("LHF-SUBMIT") })
        #expect(lines.allSatisfy { !$0.contains("SECRETVALUE") && !$0.contains("SESSIONVALUE") && !$0.contains("?") })
        #expect(lines.contains { $0.contains("csrf source: setcookie") })
        #expect(lines.contains { $0.contains("created attempt: 1") })
        #expect(lines.last?.hasSuffix("done") == true)
        let posts = Stub.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 1)
        #expect(posts.first?.value(forHTTPHeaderField: "X-CSRF-Token") == "SECRETVALUE")
    }

    @Test func a422RetriesOnceAndNeverThrice() async {
        let lines = await run(postStatus: 422)
        let posts = Stub.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 2)
        #expect(lines.allSatisfy { !$0.contains("SECRETVALUE") })
        #expect(lines.last?.hasSuffix("done") == true)
    }
}
