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

    // MARK: windowed read

    /// Records the queries the stub saw, from the URLProtocol's thread.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var offsetsStore: [Int] = []
        private var limitsStore: [String] = []
        private var sortsStore: [String] = []
        func note(_ request: URLRequest) {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
            lock.lock(); defer { lock.unlock() }
            offsetsStore.append(Int(value("offset")) ?? -1)
            limitsStore.append(value("limit"))
            sortsStore.append(value("sort"))
        }
        var offsets: [Int] { lock.lock(); defer { lock.unlock() }; return offsetsStore }
        var limits: [String] { lock.lock(); defer { lock.unlock() }; return limitsStore }
        var sorts: [String] { lock.lock(); defer { lock.unlock() }; return sortsStore }
    }

    private static let windowNow = Date(timeIntervalSince1970: 1_800_000_000)

    /// A threads body for ids `ids`; `daysAgo` gives each thread's creation
    /// age and `updatedDaysAgo` its optional last-activity age.
    private static func pageBody(
        ids: ClosedRange<Int>,
        daysAgo: (Int) -> Double,
        updatedDaysAgo: (Int) -> Double? = { _ in nil }
    ) -> String {
        let formatter = ISO8601DateFormatter()
        func stamp(_ days: Double) -> String {
            formatter.string(from: windowNow.addingTimeInterval(-days * 86_400))
        }
        let threads = ids.map { id -> String in
            var json = #"{"id":\#(id),"user_id":7,"course_id":101,"type":"post","title":"T\#(id)","is_private":false,"created_at":"\#(stamp(daysAgo(id)))""#
            if let updated = updatedDaysAgo(id) { json += #","updated_at":"\#(stamp(updated))""# }
            return json + "}"
        }
        return #"{"threads":["# + threads.joined(separator: ",") + #"],"users":[{"id":7,"course_role":"admin"}]}"#
    }

    /// A client whose stub serves `pages[offset / 100]` (an empty page past
    /// the end) and records every request.
    private func pagedClient(_ pages: [String], seen: Seen, failAtOffset: Int? = nil) -> EdClient {
        client { request in
            seen.note(request)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset = Int(items.first { $0.name == "offset" }?.value ?? "") ?? 0
            if offset == failAtOffset { return Reply(status: 500, body: "{}") }
            let index = offset / 100
            return Reply(status: 200, body: index < pages.count ? pages[index] : #"{"threads":[],"users":[]}"#)
        }
    }

    @Test("the windowed read stops on a short page, and the union keeps Ed's order across pages")
    func windowStopsOnShortPage() async throws {
        let seen = Seen()
        let c = pagedClient([
            Self.pageBody(ids: 1...100, daysAgo: { Double($0) * 0.1 }),
            Self.pageBody(ids: 101...140, daysAgo: { Double($0) * 0.1 }),
            Self.pageBody(ids: 141...240, daysAgo: { Double($0) * 0.1 }),   // must never be asked for
        ], seen: seen)
        defer { StubURLProtocol.handler = nil }
        let response = try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow)
        #expect(seen.offsets == [0, 100])
        #expect(response.threads.map(\.id) == Array(1...140))
        #expect(response.users.map(\.id) == [7])
        #expect(seen.limits == ["100", "100"])
        #expect(seen.sorts == ["new", "new"])
    }

    @Test("the windowed read stops when a page's oldest thread is outside the window")
    func windowStopsOnOldThread() async throws {
        let seen = Seen()
        // 95 recent threads, then 5 from 200 days ago: the page is full, but
        // its oldest thread is past the 120-day window, so page two is moot.
        let c = pagedClient([
            Self.pageBody(ids: 1...100, daysAgo: { $0 <= 95 ? Double($0) : 200 }),
            Self.pageBody(ids: 101...200, daysAgo: { _ in 300 }),
        ], seen: seen)
        defer { StubURLProtocol.handler = nil }
        let response = try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow)
        #expect(seen.offsets == [0])
        #expect(response.threads.count == 100)
    }

    @Test("last activity, not creation, decides whether the window has closed")
    func windowUsesLastActivity() async throws {
        let seen = Seen()
        // Every thread was created 300 days ago but was active within the
        // last 10 days, so the window is open on every page.
        let c = pagedClient([
            Self.pageBody(ids: 1...100, daysAgo: { _ in 300 }, updatedDaysAgo: { Double($0) * 0.1 }),
            Self.pageBody(ids: 101...140, daysAgo: { _ in 300 }, updatedDaysAgo: { Double($0) * 0.1 }),
        ], seen: seen)
        defer { StubURLProtocol.handler = nil }
        let response = try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow)
        #expect(seen.offsets == [0, 100])
        #expect(response.threads.count == 140)
    }

    @Test("the windowed read never goes past three pages, offsets 0, 100, 200")
    func windowStopsAtThreePages() async throws {
        let seen = Seen()
        let pages = (0..<5).map { page in
            Self.pageBody(ids: (page * 100 + 1)...(page * 100 + 100), daysAgo: { Double($0) * 0.01 })
        }
        let c = pagedClient(pages, seen: seen)
        defer { StubURLProtocol.handler = nil }
        let response = try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow)
        #expect(EdClient.maxWindowPages == 3)
        #expect(seen.offsets == [0, 100, 200])
        #expect(response.threads.map(\.id) == Array(1...300))
    }

    @Test("pageLimit lowers the cap, and a limit below one still reads one page")
    func windowPageLimit() async throws {
        let seen = Seen()
        let pages = (0..<3).map { page in
            Self.pageBody(ids: (page * 100 + 1)...(page * 100 + 100), daysAgo: { Double($0) * 0.01 })
        }
        let c = pagedClient(pages, seen: seen)
        defer { StubURLProtocol.handler = nil }
        _ = try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow, pageLimit: 2)
        #expect(seen.offsets == [0, 100])
        _ = try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow, pageLimit: 0)
        #expect(seen.offsets == [0, 100, 0])
    }

    @Test("a thread that shifted between pages is kept once")
    func windowDeduplicates() async throws {
        let seen = Seen()
        let c = pagedClient([
            Self.pageBody(ids: 1...100, daysAgo: { Double($0) * 0.1 }),
            Self.pageBody(ids: 100...139, daysAgo: { Double($0) * 0.1 }),
        ], seen: seen)
        defer { StubURLProtocol.handler = nil }
        let response = try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow)
        #expect(response.threads.map(\.id) == Array(1...139))
    }

    @Test("an error on a later page throws, so the caller keeps the stored set instead of a partial one")
    func windowErrorThrows() async {
        let seen = Seen()
        let c = pagedClient([
            Self.pageBody(ids: 1...100, daysAgo: { Double($0) * 0.1 }),
            Self.pageBody(ids: 101...140, daysAgo: { Double($0) * 0.1 }),
        ], seen: seen, failAtOffset: 100)
        defer { StubURLProtocol.handler = nil }
        await #expect(throws: EdClient.Error.http(500)) {
            try await c.threadsWithinWindow(courseID: 101, now: Self.windowNow)
        }
        #expect(seen.offsets == [0, 100])
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

    @Test("the document's header carries the creation day while updatedAt stays the last-activity time")
    func documentCarriesPostingDay() throws {
        let created = now.addingTimeInterval(-7 * 86_400)
        let bumped = now.addingTimeInterval(-86_400)
        let thread = EdThread(
            id: 901, userID: 7, courseID: 101, type: "announcement", title: "Welcome",
            content: "<p>Hello class</p>", isPrivate: false,
            createdAt: created, updatedAt: bumped
        )
        let doc = try #require(
            EdIngestion.documents(course: course, edCourseID: 101, response: staffResponse([thread]), now: now).first
        )
        let header = EdDocumentHeader.parse(doc.text)
        #expect(doc.updatedAt == bumped)
        #expect(doc.text.contains(" · posted " + EdDocumentHeader.postedDayString(created)))
        let posted = try #require(header.postedAt)
        #expect(EdDocumentHeader.postedDayString(posted) == EdDocumentHeader.postedDayString(created))
        #expect(header.body == "Hello class")
    }

    @Test("an anonymous announcement yields no document")
    func anonymousAnnouncementYieldsNothing() {
        let anonymous = EdThread(
            id: 6, userID: 7, courseID: 101, type: "announcement", title: "Secret", content: "<p>x</p>",
            isPrivate: false, isAnonymous: true, createdAt: now.addingTimeInterval(-86_400)
        )
        let docs = EdIngestion.documents(course: course, edCourseID: 101, response: staffResponse([anonymous]), now: now)
        #expect(docs.isEmpty)
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
