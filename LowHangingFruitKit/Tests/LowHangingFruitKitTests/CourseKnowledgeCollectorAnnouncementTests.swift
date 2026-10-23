import Foundation
import Testing
@testable import LowHangingFruitKit

/// The course-material collector's announcements, end to end with no network.
///
/// The collector builds its own Canvas clients from a `URLSession`, so the
/// only seam is the session: a `URLProtocol` answers every request. The
/// announcements route behaves like Canvas, including the rule that bit
/// production: `end_date` defaults to 28 days after `start_date`. A stub that
/// returned whatever it was handed would have passed against the collector as
/// it was (200 days back, no end), which is exactly how the bug went unseen.
/// Every other Canvas route answers an empty list, so a run's per-course
/// endpoints all succeed and the only thing that can keep a course out of the
/// fully-synced set is the announcements call.
///
/// Serialized because the stub's state is process-wide static (a
/// `URLProtocol` is instantiated by the system, with no per-test seam).
@Suite("Course knowledge collector announcements", .serialized)
struct CourseKnowledgeCollectorAnnouncementTests {
    private static let day: TimeInterval = 86_400
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let course = CourseSummary(
        courseID: "1234",
        code: "CIS 2400",
        name: "CIS 2400 Intro to Computer Systems",
        url: URL(string: "https://canvas.upenn.edu/courses/1234")
    )

    // MARK: Stub

    fileprivate struct Post {
        let id: Int
        let title: String
        let messageHTML: String
        let postedAt: Date
    }

    /// What the stub serves and what it saw. Static because the system makes
    /// the `URLProtocol` instance; guarded by a lock because it is written by
    /// the test and read on the loading thread.
    fileprivate final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var posts: [Post] = []
        nonisolated(unsafe) private static var announcementsStatus = 200
        nonisolated(unsafe) private static var announcementQueries: [(start: String?, end: String?)] = []

        static func configure(posts: [Post], announcementsStatus: Int = 200) {
            lock.lock(); defer { lock.unlock() }
            self.posts = posts
            self.announcementsStatus = announcementsStatus
            announcementQueries = []
        }

        static var queries: [(start: String?, end: String?)] {
            lock.lock(); defer { lock.unlock() }
            return announcementQueries
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (status, body) = Self.answer(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func answer(_ request: URLRequest) -> (Int, String) {
            guard let url = request.url, url.path == "/api/v1/announcements" else {
                return (200, "[]")
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = items.first { $0.name == "start_date" }?.value
            let end = items.first { $0.name == "end_date" }?.value

            lock.lock()
            announcementQueries.append((start, end))
            let status = announcementsStatus
            let served = posts
            lock.unlock()

            guard status == 200 else { return (status, "server error") }

            // Canvas: `end_date` defaults to 28 days after `start_date`.
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            guard let startDate = start.flatMap({ formatter.date(from: $0) }) else { return (200, "[]") }
            let endDate = end.flatMap { formatter.date(from: $0) } ?? startDate.addingTimeInterval(28 * 86_400)

            let objects: [[String: Any]] = served
                .filter { $0.postedAt >= startDate && $0.postedAt <= endDate }
                .map { post in
                    [
                        "id": post.id,
                        "context_code": "course_1234",
                        "title": post.title,
                        "message": post.messageHTML,
                        "posted_at": formatter.string(from: post.postedAt),
                        "html_url": "https://canvas.upenn.edu/courses/1234/discussion_topics/\(post.id)",
                    ]
                }
            let data = (try? JSONSerialization.data(withJSONObject: objects)) ?? Data("[]".utf8)
            return (200, String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Harness

    private func makeCollector() -> (collector: CourseKnowledgeCollector, store: CourseKnowledgeStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-announcements-\(UUID().uuidString)", isDirectory: true)
        let store = CourseKnowledgeStore(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let collector = CourseKnowledgeCollector(
            cookies: [],
            store: store,
            session: URLSession(configuration: configuration)
        )
        return (collector, store)
    }

    private func announcementDocuments(_ knowledge: CourseKnowledgeBase) -> [CourseDocument] {
        knowledge.documents.filter { $0.kind == .announcement }
    }

    private func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // MARK: The window

    @Test("the request looks back 120 days and ends one day after now")
    func requestWindow() async throws {
        let (collector, _) = makeCollector()
        StubURLProtocol.configure(posts: [])
        defer { StubURLProtocol.configure(posts: []) }

        _ = try await collector.run(courses: [Self.course], now: Self.now)

        let query = try #require(StubURLProtocol.queries.first)
        #expect(isoDate(query.start) == Self.now.addingTimeInterval(-120 * Self.day))
        #expect(isoDate(query.end) == Self.now.addingTimeInterval(Self.day))
        #expect(CourseKnowledgeCollector.announcementLookbackDays == 120)
    }

    @Test("with Canvas's 28-day default honoured, a post from 3 days ago is collected and one from 150 days ago is not")
    func recentPostCollected() async throws {
        let (collector, _) = makeCollector()
        StubURLProtocol.configure(posts: [
            Post(id: 1, title: "Midterm room", messageHTML: "<p>Room is Towne 100.</p>", postedAt: Self.now.addingTimeInterval(-3 * Self.day)),
            Post(id: 2, title: "Last semester", messageHTML: "<p>Old news.</p>", postedAt: Self.now.addingTimeInterval(-150 * Self.day)),
        ])
        defer { StubURLProtocol.configure(posts: []) }

        let report = try await collector.run(courses: [Self.course], now: Self.now)

        let documents = announcementDocuments(report.knowledge)
        #expect(documents.map(\.sourceID) == ["1"])
        let recent = try #require(documents.first)
        #expect(recent.text == "Room is Towne 100.")
        #expect(recent.updatedAt == Self.now.addingTimeInterval(-3 * Self.day))
        #expect(report.fullyFetchedCourseIDs == ["1234"])
    }

    // MARK: A failed call erases nothing

    @Test("a failed announcements call counts no course as fully synced and keeps the stored announcement")
    func failedCallKeepsStoredAnnouncements() async throws {
        let (collector, store) = makeCollector()
        StubURLProtocol.configure(posts: [
            Post(id: 1, title: "Midterm room", messageHTML: "<p>Room is Towne 100.</p>", postedAt: Self.now.addingTimeInterval(-3 * Self.day)),
        ])
        defer { StubURLProtocol.configure(posts: []) }

        // A good run first: it stores the announcement, and shows that the
        // other endpoints answering is enough for the course to count as
        // fully synced, so the failure below is the only thing that changes it.
        let first = try await collector.run(courses: [Self.course], now: Self.now)
        #expect(first.fullyFetchedCourseIDs == ["1234"])
        #expect(announcementDocuments(store.load()).count == 1)

        StubURLProtocol.configure(posts: [], announcementsStatus: 500)
        let second = try await collector.run(courses: [Self.course], now: Self.now.addingTimeInterval(3_600))

        #expect(second.fullyFetchedCourseIDs.isEmpty)
        #expect(second.syncedCourses == 0)
        #expect(second.errors.contains { $0.hasPrefix("announcements:") })
        // In the run's output, and on disk for the next run.
        #expect(announcementDocuments(second.knowledge).map(\.sourceID) == ["1"])
        #expect(announcementDocuments(store.load()).map(\.sourceID) == ["1"])
    }

    // MARK: Documents the server accepts

    @Test("an untitled post is called Announcement, and a post with no message makes no document")
    func builderGuards() throws {
        let posted = Self.now
        let untitled = try #require(CourseDocumentBuilder.announcement(
            from: CanvasAnnouncement(id: "5", courseID: "1234", title: "  ", message: "  Bring a pencil.  ", postedAt: posted, url: nil),
            course: Self.course
        ))
        #expect(untitled.title == "Announcement")
        #expect(untitled.text == "Bring a pencil.")
        #expect(untitled.updatedAt == posted)

        let emptyTitle = try #require(CourseDocumentBuilder.announcement(
            from: CanvasAnnouncement(id: "6", courseID: "1234", title: "", message: "Hi.", postedAt: nil, url: nil),
            course: Self.course
        ))
        #expect(emptyTitle.title == "Announcement")

        #expect(CourseDocumentBuilder.announcement(
            from: CanvasAnnouncement(id: "7", courseID: "1234", title: "Title only", message: " \n ", postedAt: posted, url: nil),
            course: Self.course
        ) == nil)
    }

    @Test("the text is the same whatever the device's time zone, so classmates hash a post alike")
    func textCarriesNoDate() throws {
        let post = CanvasAnnouncement(id: "8", courseID: "1234", title: "Exam moved", message: "Now Oct 21.", postedAt: Self.now, url: nil)
        let doc = try #require(CourseDocumentBuilder.announcement(from: post, course: Self.course))
        #expect(doc.text == "Now Oct 21.")
        #expect(doc.contentHash == ContentHash.fnv1a("Exam moved" + "\u{1F}" + "Now Oct 21."))
    }

    @Test("the collector uploads no document for an empty-bodied post and titles an untitled one")
    func collectorGuards() async throws {
        let (collector, _) = makeCollector()
        StubURLProtocol.configure(posts: [
            Post(id: 10, title: "", messageHTML: "<p>No title here.</p>", postedAt: Self.now.addingTimeInterval(-Self.day)),
            Post(id: 11, title: "Empty", messageHTML: "<p></p>", postedAt: Self.now.addingTimeInterval(-Self.day)),
        ])
        defer { StubURLProtocol.configure(posts: []) }

        let report = try await collector.run(courses: [Self.course], now: Self.now)

        let documents = announcementDocuments(report.knowledge)
        #expect(documents.map(\.sourceID) == ["10"])
        #expect(documents.first?.title == "Announcement")
    }
}
