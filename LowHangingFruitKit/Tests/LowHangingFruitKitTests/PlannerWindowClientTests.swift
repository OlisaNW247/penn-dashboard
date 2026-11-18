import Foundation
import Testing
@testable import LowHangingFruitKit

/// `CanvasStructuredSourcesClient.fetchPlannerWindow`, the planner leg of a
/// full run on its own, over a canned transport.
@Suite("Planner window client")
struct PlannerWindowClientTests {
    private let base = URL(string: "https://canvas.example.edu")!
    private let t0 = ISO8601DateFormatter().date(from: "2026-11-18T14:00:00Z")!
    private let t1 = ISO8601DateFormatter().date(from: "2026-11-18T17:00:00Z")!

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private func client(
        status: Int = 200, body: String = "[]", headers: [String: String] = [:],
        record: Recorder = Recorder(), second: (status: Int, body: String)? = nil
    ) -> CanvasStructuredSourcesClient {
        CanvasStructuredSourcesClient(baseURL: base, transport: { url in
            record.add(url)
            let isSecond = record.all.count > 1
            let (code, text) = isSecond ? (second?.status ?? status, second?.body ?? body) : (status, body)
            let http = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!
            return (Data(text.utf8), http)
        })
    }

    @Test("It asks the planner path with the two dates and per_page, once")
    func request() async throws {
        let rec = Recorder()
        _ = await client(record: rec).fetchPlannerWindow(start: t0, end: t1)
        let url = try #require(rec.all.first)
        #expect(rec.all.count == 1)
        #expect(url.path == "/api/v1/planner/items")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(q["start_date"] == "2026-11-18T14:00:00Z")
        #expect(q["end_date"] == "2026-11-18T17:00:00Z")
        #expect(q["per_page"] == "100")
    }

    @Test("A good page decodes, is complete, and reports the bucket")
    func goodPage() async {
        let body = """
        [{"plannable_type":"assignment","plannable_id":55,"course_id":7,
          "plannable":{"title":"PSet","due_at":"2026-11-18T16:00:00Z","assignment_id":55},
          "submissions":{"submitted":true}}]
        """
        let r = await client(body: body, headers: ["X-Rate-Limit-Remaining": "412.5"])
            .fetchPlannerWindow(start: t0, end: t1)
        #expect(r.items.count == 1)
        #expect(r.items[0].submitted == true)
        #expect(r.completed && !r.rateLimited && !r.sessionExpired)
        #expect(r.remaining == 412.5)
    }

    @Test("A 403 rate-limit answer is rateLimited, with nothing believed")
    func rateLimited() async {
        let r = await client(status: 403, body: "403 Forbidden (Rate Limit Exceeded)")
            .fetchPlannerWindow(start: t0, end: t1)
        #expect(r.rateLimited)
        #expect(!r.completed)
        #expect(r.items.isEmpty)
    }

    @Test("A 401 is sessionExpired")
    func unauthorized() async {
        let r = await client(status: 401).fetchPlannerWindow(start: t0, end: t1)
        #expect(r.sessionExpired)
        #expect(!r.completed)
    }

    @Test("A page that is HTML (a login page) is sessionExpired")
    func loginPage() async {
        let r = await client(body: "<html><body>Log in</body></html>").fetchPlannerWindow(start: t0, end: t1)
        #expect(r.sessionExpired && !r.completed)
    }

    @Test("A truncated page (a next link that is refused, or a failure on page two) is not complete")
    func truncated() async {
        let link = "<https://evil.example/next>; rel=\"next\""
        let r1 = await client(body: "[{\"plannable_type\":\"assignment\",\"plannable_id\":1}]",
                              headers: ["Link": link]).fetchPlannerWindow(start: t0, end: t1)
        #expect(r1.items.count == 1)
        #expect(!r1.completed, "an off-host next page is not followed, so the read is partial")

        let next = "<https://canvas.example.edu/api/v1/planner/items?page=2&per_page=100>; rel=\"next\""
        let r2 = await client(body: "[{\"plannable_type\":\"assignment\",\"plannable_id\":1}]",
                              headers: ["Link": next], second: (500, "")).fetchPlannerWindow(start: t0, end: t1)
        #expect(r2.items.count == 1)
        #expect(!r2.completed)
    }

    @Test("A low bucket keeps the page and stops, reporting rateLimited")
    func lowBucket() async {
        let r = await client(body: "[{\"plannable_type\":\"assignment\",\"plannable_id\":1}]",
                             headers: ["X-Rate-Limit-Remaining": "10"]).fetchPlannerWindow(start: t0, end: t1)
        #expect(r.rateLimited)
        #expect(r.items.count == 1)
        #expect(r.remaining == 10)
    }
}
