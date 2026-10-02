import Foundation
import Testing
@testable import LowHangingFruitKit

/// Covers `EdClient` (what leaves the phone, and how each response is read)
/// and `EdIngestion` (kept threads to pooled documents). The network is a
/// local `URLProtocol` stub, so nothing here touches Ed. The suite is
/// `.serialized` because the stub's handler is one static slot.

private func makeCookie(_ name: String, _ value: String) -> HTTPCookie {
    HTTPCookie(properties: [
        .name: name, .value: value, .domain: "us.edstem.org", .path: "/",
    ])!
}

@Suite("Ed client", .serialized)
struct EdClientTests {

    /// What the stub replies with, and what it saw.
    private struct Reply {
        var status: Int
        var contentType: String = "application/json"
        var body: String
    }

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let reply = handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": reply.contentType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func client(_ auth: EdAuth = .token("t"), _ handler: @escaping (URLRequest) -> Reply) -> EdClient {
        StubURLProtocol.handler = handler
        StubURLProtocol.lastRequest = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return EdClient(auth: auth, session: URLSession(configuration: configuration))
    }

    private let threadsBody = #"""
    {"threads":[{"id":900,"user_id":7,"course_id":101,"type":"announcement","title":"Welcome",
                 "is_private":false,"created_at":"2026-03-05T14:21:55Z"}],
     "users":[{"id":7,"course_role":"admin"}]}
    """#

    // MARK: apply

    @Test("cookies become a Cookie header carrying every cookie, and no x-token")
    func applyCookies() {
        var request = URLRequest(url: URL(string: "https://us.edstem.org/api/user")!)
        EdClient.apply(.cookies([makeCookie("edsession", "abc"), makeCookie("other", "xyz")]), to: &request)
        let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
        #expect(header.contains("edsession=abc"))
        #expect(header.contains("other=xyz"))
        #expect(request.value(forHTTPHeaderField: "x-token") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("a token becomes x-token, and no Cookie header")
    func applyToken() {
        var request = URLRequest(url: URL(string: "https://us.edstem.org/api/user")!)
        EdClient.apply(.token("secret-token"), to: &request)
        #expect(request.value(forHTTPHeaderField: "x-token") == "secret-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
    }

    // MARK: responses

    @Test("401 and 403 are an expired session")
    func unauthorized() async {
        for status in [401, 403] {
            let c = client { _ in Reply(status: status, body: "{}") }
            await #expect(throws: EdClient.Error.sessionExpired) { try await c.user() }
        }
        StubURLProtocol.handler = nil
    }

    @Test("an HTML page on a 200 is Ed's login page, so an expired session")
    func htmlIsLogin() async {
        let c = client { _ in Reply(status: 200, contentType: "text/html; charset=utf-8", body: "<html>log in</html>") }
        await #expect(throws: EdClient.Error.sessionExpired) { try await c.user() }
        StubURLProtocol.handler = nil
    }

    @Test("another failure status is reported as http(code)")
    func serverError() async {
        let c = client { _ in Reply(status: 500, body: "{}") }
        await #expect(throws: EdClient.Error.http(500)) { try await c.user() }
        StubURLProtocol.handler = nil
    }

    @Test("a body that is not the expected JSON is invalidJSON")
    func badBody() async {
        let c = client { _ in Reply(status: 200, body: "[1,2]") }
        do {
            _ = try await c.user()
            Issue.record("expected invalidJSON")
        } catch let error as EdClient.Error {
            if case .invalidJSON = error {} else { Issue.record("expected invalidJSON, got \(error)") }
        } catch {
            Issue.record("unexpected error \(error)")
        }
        StubURLProtocol.handler = nil
    }

    @Test("user() hits /api/user with the auth headers and decodes the enrolments")
    func userDecodes() async throws {
        let c = client(.token("tok")) { _ in
            Reply(status: 200, body: #"{"user":{"id":1},"courses":[{"course":{"id":101,"code":"CIS 2400","name":"Machine Organization"}}]}"#)
        }
        defer { StubURLProtocol.handler = nil }
        let response = try await c.user()
        #expect(response.courses.first?.course.id == 101)
        let request = try #require(StubURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://us.edstem.org/api/user")
        #expect(request.value(forHTTPHeaderField: "x-token") == "tok")
    }

    @Test("threads() builds the path and query, defaulting to limit=100 and sort=new")
    func threadsQuery() async throws {
        let c = client { _ in Reply(status: 200, body: self.threadsBody) }
        defer { StubURLProtocol.handler = nil }
        let response = try await c.threads(courseID: 101)
        #expect(response.threads.count == 1)
        let url = try #require(StubURLProtocol.lastRequest?.url)
        #expect(url.path == "/api/courses/101/threads")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["limit"] == "100")
        #expect(items["sort"] == "new")
        #expect(items["offset"] == "0")
    }

    @Test("threads() clamps limit to Ed's 1...100")
    func threadsClampsLimit() async throws {
        let c = client { _ in Reply(status: 200, body: self.threadsBody) }
        defer { StubURLProtocol.handler = nil }
        _ = try await c.threads(courseID: 101, limit: 500)
        #expect(try queryValue("limit") == "100")
        _ = try await c.threads(courseID: 101, limit: 0)
        #expect(try queryValue("limit") == "1")
    }

    private func queryValue(_ name: String) throws -> String? {
        let url = try #require(StubURLProtocol.lastRequest?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == name }?.value
    }
}

@Suite("Ed ingestion")
struct EdIngestionDocumentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let course = CourseSummary(courseID: "555", code: "CIS 2400", name: "Machine Organization", url: nil)

    private func staffResponse(_ threads: [EdThread]) -> EdThreadsResponse {
        EdThreadsResponse(threads: threads, users: [
            EdThreadUser(id: 7, courseRole: "admin"),
            EdThreadUser(id: 8, courseRole: "student"),
        ])
    }

    private func staffPost(_ id: Int, daysAgo: Double, type: String = "post") -> EdThread {
        EdThread(
            id: id, userID: 7, courseID: 101, type: type, title: "Post \(id)", document: nil,
            content: "<p>Body \(id)</p>", isPrivate: false,
            createdAt: now.addingTimeInterval(-daysAgo * 86_400)
        )
    }

    @Test("a kept announcement becomes an .ed document with the pooled identity and link")
    func announcementBecomesDocument() throws {
        let thread = EdThread(
            id: 900, userID: 7, courseID: 101, type: "announcement", title: "Welcome",
            content: "<p>Hello class</p>", isPrivate: false,
            createdAt: now.addingTimeInterval(-86_400)
        )
        let docs = EdIngestion.documents(course: course, edCourseID: 101, response: staffResponse([thread]), now: now)
        let doc = try #require(docs.first)
        #expect(docs.count == 1)
        #expect(doc.kind == .ed)
        #expect(doc.id == "ed:555:900")
        #expect(doc.courseID == "555")
        #expect(doc.course == "CIS 2400")
        #expect(doc.title == "Welcome")
        #expect(doc.url == EdIngestion.threadURL(edCourseID: 101, threadID: 900))
        #expect(doc.url?.absoluteString == "https://edstem.org/us/courses/101/discussion/900")
        #expect(doc.text.hasPrefix("[ed · announcement]"))
        #expect(doc.fetchedAt == now)
        #expect(doc.updatedAt == thread.createdAt)
    }

    @Test("a student post yields no document")
    func studentPostDropped() {
        let student = EdThread(
            id: 5, userID: 8, courseID: 101, type: "post", title: "Help", content: "<p>x</p>",
            isPrivate: false, createdAt: now.addingTimeInterval(-86_400)
        )
        let docs = EdIngestion.documents(course: course, edCourseID: 101, response: staffResponse([student]), now: now)
        #expect(docs.isEmpty)
    }

    @Test("maxAge drops a 200-day-old staff post and keeps a 10-day-old one")
    func maxAgeApplies() {
        let docs = EdIngestion.documents(
            course: course, edCourseID: 101,
            response: staffResponse([staffPost(1, daysAgo: 200), staffPost(2, daysAgo: 10)]),
            now: now
        )
        #expect(docs.map(\.sourceID) == ["2"])
    }

    @Test("updatedAt, not createdAt, decides recency when present")
    func updatedAtWins() {
        let old = EdThread(
            id: 3, userID: 7, courseID: 101, type: "post", title: "Edited", content: "<p>x</p>",
            isPrivate: false,
            createdAt: now.addingTimeInterval(-300 * 86_400),
            updatedAt: now.addingTimeInterval(-2 * 86_400)
        )
        let docs = EdIngestion.documents(course: course, edCourseID: 101, response: staffResponse([old]), now: now)
        #expect(docs.count == 1)
    }

    @Test("documents come out newest first")
    func newestFirst() {
        let docs = EdIngestion.documents(
            course: course, edCourseID: 101,
            response: staffResponse([staffPost(1, daysAgo: 30), staffPost(2, daysAgo: 1), staffPost(3, daysAgo: 10)]),
            now: now
        )
        #expect(docs.map(\.sourceID) == ["2", "3", "1"])
    }
}
