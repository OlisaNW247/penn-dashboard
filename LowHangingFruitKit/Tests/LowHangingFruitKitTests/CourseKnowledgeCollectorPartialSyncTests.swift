import Foundation
import Testing
@testable import LowHangingFruitKit

/// What a course-material run does to a course that only half answered.
///
/// Before 2026-10-23 a course counted as fully synced when at most one of its
/// endpoints failed, so a Modules call that returned 500 left the course in
/// the fully-synced set, `CourseKnowledgeBase.merge` dropped every stored
/// document the run had not re-fetched (all its modules, and whatever else
/// the failed call would have confirmed), and the upload's complete-set rule
/// told the server, and so every classmate, that they were gone. And a 403 on
/// one course's assignments was read as a signed-out student and aborted the
/// whole run before it saved anything. These tests drive the collector end to
/// end through a `URLProtocol`, the way
/// `CourseKnowledgeCollectorAnnouncementTests` does, with the same caveat:
/// the stub's state is process-wide static, so the suite is serialized.
///
/// Every route answers an empty list unless a test says otherwise, so the
/// only thing that can fail a course is the failure the test installs.
@Suite("Course knowledge collector partial syncs", .serialized)
struct CourseKnowledgeCollectorPartialSyncTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let courseA = CourseSummary(
        courseID: "1111",
        code: "CIS 1110",
        name: "CIS 1110 Intro to Programming",
        url: URL(string: "https://canvas.upenn.edu/courses/1111")
    )
    private static let courseB = CourseSummary(
        courseID: "2222",
        code: "CIS 2220",
        name: "CIS 2220 Data Structures",
        url: URL(string: "https://canvas.upenn.edu/courses/2222")
    )

    // MARK: Stub

    /// Answers by course and endpoint. `failures` maps "<courseID>/<endpoint>"
    /// ("1111/modules", "2222/assignments") to the status that route returns;
    /// `assignmentJSON` maps a course id to the body its assignments route
    /// serves. Static because the system makes the `URLProtocol` instance;
    /// locked because the test writes it and the loading thread reads it.
    fileprivate final class PartialSyncStub: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var failures: [String: Int] = [:]
        nonisolated(unsafe) private static var assignmentJSON: [String: String] = [:]
        nonisolated(unsafe) private static var announcementsStatus = 200

        static func configure(
            failures: [String: Int] = [:],
            assignmentJSON: [String: String] = [:],
            announcementsStatus: Int = 200
        ) {
            lock.lock(); defer { lock.unlock() }
            self.failures = failures
            self.assignmentJSON = assignmentJSON
            self.announcementsStatus = announcementsStatus
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
            guard let path = request.url?.path else { return (200, "[]") }
            lock.lock(); defer { lock.unlock() }

            if path == "/api/v1/announcements" {
                return announcementsStatus == 200 ? (200, "[]") : (announcementsStatus, "server error")
            }
            // /api/v1/courses/<id>/<endpoint>[/...]
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 5, parts[0] == "api", parts[2] == "courses" else { return (200, "[]") }
            let courseID = parts[3]
            let endpoint = parts[4]
            if let status = failures["\(courseID)/\(endpoint)"] {
                return (status, "server error")
            }
            if endpoint == "assignments", let body = assignmentJSON[courseID] {
                return (200, body)
            }
            return (200, "[]")
        }
    }

    // MARK: Harness

    private func makeCollector() -> (collector: CourseKnowledgeCollector, store: CourseKnowledgeStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-partial-\(UUID().uuidString)", isDirectory: true)
        let store = CourseKnowledgeStore(directory: directory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PartialSyncStub.self]
        let collector = CourseKnowledgeCollector(
            cookies: [],
            store: store,
            session: URLSession(configuration: configuration)
        )
        return (collector, store)
    }

    /// One page and one module document per course that a clean run, against
    /// a Canvas that now answers `[]` everywhere, would no longer find.
    private func staleDocuments(for course: CourseSummary) -> [CourseDocument] {
        [
            CourseDocument(
                courseID: course.courseID, course: course.code, kind: .page, sourceID: "stale-page",
                title: "Old page", url: nil, text: "Old page text.", fetchedAt: Self.now.addingTimeInterval(-86_400)
            ),
            CourseDocument(
                courseID: course.courseID, course: course.code, kind: .module, sourceID: "stale-module",
                title: "Old module", url: nil, text: "Old module text.", fetchedAt: Self.now.addingTimeInterval(-86_400)
            ),
        ]
    }

    private func seed(_ store: CourseKnowledgeStore, courses: [CourseSummary]) throws {
        var base = CourseKnowledgeBase.empty
        base.merge(
            courses: courses,
            documents: courses.flatMap { staleDocuments(for: $0) },
            resyncedCourseIDs: [],
            syncedAt: Self.now.addingTimeInterval(-86_400)
        )
        try store.save(base)
    }

    private func assignmentBody(id: Int, name: String) -> String {
        """
        [{"id": \(id), "name": "\(name)", "description": "<p>Read chapter 2.</p>",
          "due_at": "2027-01-10T15:00:00Z", "points_possible": 10,
          "updated_at": "2026-12-01T10:00:00Z",
          "html_url": "https://canvas.upenn.edu/courses/1111/assignments/\(id)"}]
        """
    }

    private func ids(_ knowledge: CourseKnowledgeBase, course: CourseSummary) -> Set<String> {
        Set(knowledge.documents.filter { $0.courseID == course.courseID }.map(\.id))
    }

    // MARK: A failed endpoint makes the course partial

    @Test("one failed endpoint keeps the course out of the fully-synced set and keeps what it held")
    func failedEndpointKeepsStoredDocuments() async throws {
        let (collector, store) = makeCollector()
        try seed(store, courses: [Self.courseA])
        PartialSyncStub.configure(
            failures: ["1111/modules": 500],
            assignmentJSON: ["1111": assignmentBody(id: 77, name: "Problem Set 1")]
        )
        defer { PartialSyncStub.configure() }

        let report = try await collector.run(courses: [Self.courseA], now: Self.now)

        #expect(report.fullyFetchedCourseIDs.isEmpty)
        #expect(report.partialCourseIDs == ["1111"])
        #expect(report.syncedCourses == 0)
        // One endpoint down is still a course the notice can call read.
        #expect(report.usableCourses == 1)
        #expect(report.errors.contains { $0.hasPrefix("CIS 1110 modules:") })

        // Nothing the course held was dropped, in the run or on disk...
        let expectedKept: Set<String> = ["page:1111:stale-page", "module:1111:stale-module"]
        #expect(expectedKept.isSubset(of: ids(report.knowledge, course: Self.courseA)))
        #expect(expectedKept.isSubset(of: ids(store.load(), course: Self.courseA)))
        // ...and what did arrive was merged in beside it.
        #expect(ids(report.knowledge, course: Self.courseA).contains("assignment:1111:77"))
    }

    @Test("a failed announcements call makes every fetched course partial, not fully synced")
    func failedAnnouncementsMakesCoursePartial() async throws {
        let (collector, store) = makeCollector()
        try seed(store, courses: [Self.courseA])
        PartialSyncStub.configure(announcementsStatus: 500)
        defer { PartialSyncStub.configure() }

        let report = try await collector.run(courses: [Self.courseA], now: Self.now)

        #expect(report.fullyFetchedCourseIDs.isEmpty)
        #expect(report.partialCourseIDs == ["1111"])
        #expect(ids(report.knowledge, course: Self.courseA).contains("page:1111:stale-page"))
    }

    // MARK: A clean course still prunes

    @Test("a course with no errors is fully synced, and its documents Canvas no longer has are dropped")
    func cleanCourseStillDropsStaleDocuments() async throws {
        let (collector, store) = makeCollector()
        try seed(store, courses: [Self.courseA])
        PartialSyncStub.configure(assignmentJSON: ["1111": assignmentBody(id: 77, name: "Problem Set 1")])
        defer { PartialSyncStub.configure() }

        let report = try await collector.run(courses: [Self.courseA], now: Self.now)

        #expect(report.fullyFetchedCourseIDs == ["1111"])
        #expect(report.partialCourseIDs.isEmpty)
        #expect(report.syncedCourses == 1)
        #expect(report.usableCourses == 1)
        #expect(report.errors.isEmpty)
        let held = ids(store.load(), course: Self.courseA)
        #expect(!held.contains("page:1111:stale-page"))
        #expect(!held.contains("module:1111:stale-module"))
        #expect(held.contains("assignment:1111:77"))
    }

    // MARK: 403 is the course's problem, 401 is the session's

    @Test("a 403 on one course's assignments makes that course partial; the other still fully syncs and the run saves")
    func forbiddenCourseDoesNotAbortTheRun() async throws {
        let (collector, store) = makeCollector()
        try seed(store, courses: [Self.courseA, Self.courseB])
        PartialSyncStub.configure(
            failures: ["1111/assignments": 403],
            assignmentJSON: ["2222": assignmentBody(id: 88, name: "Lab 1")]
        )
        defer { PartialSyncStub.configure() }

        let report = try await collector.run(courses: [Self.courseA, Self.courseB], now: Self.now)

        #expect(report.partialCourseIDs == ["1111"])
        #expect(report.fullyFetchedCourseIDs == ["2222"])
        #expect(report.errors.contains { $0.hasPrefix("CIS 1110 assignments:") && $0.contains("403") })

        // The run reached `store.save`: the clean course's new document is on
        // disk, its stale ones are gone, and the forbidden course kept all it had.
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        let saved = store.load()
        #expect(ids(saved, course: Self.courseB).contains("assignment:2222:88"))
        #expect(!ids(saved, course: Self.courseB).contains("page:2222:stale-page"))
        #expect(!ids(saved, course: Self.courseB).contains("module:2222:stale-module"))
        #expect(ids(saved, course: Self.courseA).isSuperset(of: ["page:1111:stale-page", "module:1111:stale-module"]))
    }

    @Test("a 401 on assignments is still a sign-out: the run throws and saves nothing")
    func unauthorizedStillAbortsTheRun() async throws {
        let (collector, store) = makeCollector()
        PartialSyncStub.configure(failures: ["1111/assignments": 401])
        defer { PartialSyncStub.configure() }

        await #expect(throws: CanvasCourseContentClient.Error.sessionExpired) {
            _ = try await collector.run(courses: [Self.courseA, Self.courseB], now: Self.now)
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: Callers that build a report

    @Test("a report built without the new fields has no partial courses and calls its synced courses usable")
    func reportDefaults() {
        let report = CourseKnowledgeCollector.Report(knowledge: .empty, syncedCourses: 3, errors: [])
        #expect(report.partialCourseIDs.isEmpty)
        #expect(report.usableCourses == 3)
    }
}
