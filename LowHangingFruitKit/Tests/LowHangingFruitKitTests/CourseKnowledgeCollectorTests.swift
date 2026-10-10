import Foundation
import Testing
@testable import LowHangingFruitKit

/// The course-materials collector, run end to end against a stubbed Canvas
/// (a local `URLProtocol`; nothing here touches the network).
///
/// What these pin is the rule that a fetch which failed must never be read as
/// "the teacher deleted it". The merge drops a fully fetched course's
/// documents that this run did not see, and the upload tells the server the
/// same for every classmate, so a course where anything failed has to be
/// merged add-and-update only and left out of the fully-synced set. The
/// suite is `.serialized` because the stub's routes are one static slot.
@Suite("Course materials collector", .serialized)
struct CourseKnowledgeCollectorTests {

    // MARK: - Stub Canvas

    private struct Reply {
        var status: Int = 200
        var body: String = "[]"
        var contentType: String = "application/json"
    }

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var routes: [String: Reply] = [:]
        nonisolated(unsafe) static var requested: [String] = []
        static let lock = NSLock()

        /// A route is the request path, with `?search` appended for the
        /// syllabus client's `search_term=syllabus` lookups of pages and
        /// files, so the page-listing route is not also its search route.
        static func key(for url: URL) -> String {
            let search = (url.query ?? "").contains("search_term=")
            return url.path + (search ? "?search" : "")
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let key = Self.key(for: request.url!)
            Self.lock.lock()
            Self.requested.append(key)
            let reply = Self.routes[key] ?? Reply(status: 404, body: "{\"errors\":[]}")
            Self.lock.unlock()
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

    private struct PageFixture {
        var slug: String
        var title: String = ""
        var body: String = "<p>body</p>"
        var updatedAt: String = "2026-09-01T12:00:00Z"
        var published: Bool = true
    }

    /// One test's world: a temp knowledge store, a session wired to the stub,
    /// and helpers that route a healthy Canvas course.
    private final class Env {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("collector-\(UUID().uuidString)")
        let store: CourseKnowledgeStore
        let session: URLSession
        let base = URL(string: "https://canvas.upenn.edu")!

        init() {
            store = CourseKnowledgeStore(directory: directory)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            session = URLSession(configuration: configuration)
            StubURLProtocol.lock.lock()
            StubURLProtocol.routes = [:]
            StubURLProtocol.requested = []
            StubURLProtocol.lock.unlock()
            route("/api/v1/announcements", Reply())
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func collector() -> CourseKnowledgeCollector {
            CourseKnowledgeCollector(cookies: [], store: store, baseURL: base, session: session)
        }

        func contentClient() -> CanvasCourseContentClient {
            CanvasCourseContentClient(baseURL: base, cookies: [], session: session)
        }

        func route(_ key: String, _ reply: Reply) {
            StubURLProtocol.lock.lock()
            StubURLProtocol.routes[key] = reply
            StubURLProtocol.lock.unlock()
        }

        var requested: [String] {
            StubURLProtocol.lock.lock()
            defer { StubURLProtocol.lock.unlock() }
            return StubURLProtocol.requested
        }

        /// Routes every endpoint the collector calls for one course, all
        /// answering normally. Tests then break the one they care about.
        func healthyCourse(
            _ id: String,
            assignments: [Int] = [1],
            assignmentText: String = "current text",
            syllabus: String? = "<p>Late policy: three days.</p>",
            pages: [PageFixture] = [],
            front: PageFixture? = nil,
            modulePageSlugs: [String] = []
        ) {
            let root = "/api/v1/courses/\(id)"
            let assignmentJSON = assignments.map {
                #"{"id": \#($0), "name": "HW \#($0)", "due_at": null, "description": "<p>\#(assignmentText)</p>", "updated_at": "2026-09-01T12:00:00Z"}"#
            }.joined(separator: ",")
            route("\(root)/assignments", Reply(body: "[\(assignmentJSON)]"))

            let items = modulePageSlugs.enumerated().map { index, slug in
                #"{"id": \#(900 + index), "title": "Read \#(slug)", "type": "Page", "page_url": "\#(slug)"}"#
            }.joined(separator: ",")
            route("\(root)/modules", Reply(body: modulePageSlugs.isEmpty ? "[]" : #"[{"name": "Week 1", "items": [\#(items)]}]"#))

            let syllabusBody = syllabus.map { "\"\($0)\"" } ?? "null"
            route(root, Reply(body: #"{"syllabus_body": \#(syllabusBody)}"#))
            route("\(root)/pages?search", Reply())
            route("\(root)/files?search", Reply())

            route("\(root)/pages", Reply(body: "[\(pages.map(listingJSON).joined(separator: ","))]"))
            for page in pages + (front.map { [$0] } ?? []) {
                route("\(root)/pages/\(page.slug)", Reply(body: fullJSON(page)))
            }
            if let front {
                route("\(root)/front_page", Reply(body: fullJSON(front)))
            }
        }

        private func listingJSON(_ page: PageFixture) -> String {
            #"{"url": "\#(page.slug)", "title": "\#(page.title.isEmpty ? page.slug : page.title)", "updated_at": "\#(page.updatedAt)", "published": \#(page.published)}"#
        }

        private func fullJSON(_ page: PageFixture) -> String {
            #"{"url": "\#(page.slug)", "title": "\#(page.title.isEmpty ? page.slug : page.title)", "body": "\#(page.body)", "updated_at": "\#(page.updatedAt)", "published": \#(page.published), "html_url": "https://canvas.upenn.edu/courses/x/pages/\#(page.slug)"}"#
        }

        func seed(_ documents: [CourseDocument]) throws {
            try store.save(CourseKnowledgeBase(documents: documents))
        }
    }

    private func course(_ id: String, code: String? = nil) -> CourseSummary {
        CourseSummary(courseID: id, code: code ?? "CIS \(id)", name: "Course \(id)", url: URL(string: "https://canvas.upenn.edu/courses/\(id)"))
    }

    private func document(
        _ courseID: String,
        _ kind: CourseDocument.Kind,
        _ sourceID: String,
        text: String = "stored text",
        updatedAt: Date? = nil
    ) -> CourseDocument {
        CourseDocument(
            courseID: courseID, course: "CIS \(courseID)", kind: kind, sourceID: sourceID,
            title: "Stored \(sourceID)", url: nil, text: text, updatedAt: updatedAt,
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func date(_ iso: String) -> Date { CourseContentAPI.parseDate(iso)! }

    private func ids(_ report: CourseKnowledgeCollector.Report) -> Set<String> {
        Set(report.knowledge.documents.map(\.id))
    }

    // MARK: - Defect 1: a half-failed course is partial

    @Test("one failing endpoint keeps all of the course's stored documents, leaves it out of the fully-synced set, and records the error; another course in the run syncs fully")
    func failingEndpointMakesCoursePartial() async throws {
        let env = Env()
        try env.seed([
            document("A", .assignment, "1"),
            document("A", .assignment, "2"),     // no longer on Canvas, but we cannot know that this run
            document("A", .page, "old-page"),
            document("A", .syllabus, "syllabus-body-A"),
            document("B", .assignment, "7"),     // genuinely gone from B
        ])
        env.healthyCourse("A", assignments: [1])
        env.route("/api/v1/courses/A/pages", Reply(status: 500))   // A's page listing fails
        env.healthyCourse("B", assignments: [8])

        let report = try await env.collector().run(courses: [course("A"), course("B")])

        #expect(report.partialCourseIDs == ["A"])
        #expect(report.fullyFetchedCourseIDs == ["B"])
        let held = ids(report)
        #expect(held.isSuperset(of: ["assignment:A:1", "assignment:A:2", "page:A:old-page", "syllabus:A:syllabus-body-A"]))
        // Add and update still happen for the partial course.
        #expect(report.knowledge.documents.first { $0.id == "assignment:A:1" }?.text.contains("current text") == true)
        // The fully fetched course is replaced as before.
        #expect(held.contains("assignment:B:8"))
        #expect(!held.contains("assignment:B:7"))
        #expect(report.errors.contains { $0.hasPrefix("CIS A pages") })

        let upload = SyncPlanner.uploads(local: report.knowledge, serverManifest: [], fullyFetched: report.fullyFetchedCourseIDs)
        #expect(upload.fullySyncedCourses.map(\.courseID) == ["B"])
        #expect(Set(env.store.load().documents.map(\.id)) == held)
    }

    @Test("a fully successful run is unchanged: documents that disappeared from Canvas are dropped and the course is claimed")
    func successfulRunStillDropsAndClaims() async throws {
        let env = Env()
        try env.seed([
            document("A", .assignment, "1"),
            document("A", .assignment, "2"),
            document("A", .page, "old-page"),
            document("A", .syllabus, "syllabus-body-A"),
        ])
        env.healthyCourse("A", assignments: [1], pages: [PageFixture(slug: "new-page")])

        let report = try await env.collector().run(courses: [course("A")])

        #expect(report.partialCourseIDs.isEmpty)
        #expect(report.fullyFetchedCourseIDs == ["A"])
        #expect(report.errors.isEmpty)
        let held = ids(report)
        #expect(held.contains("assignment:A:1"))
        #expect(held.contains("page:A:new-page"))
        #expect(held.contains("syllabus:A:syllabus-body-A"))
        #expect(!held.contains("assignment:A:2"))
        #expect(!held.contains("page:A:old-page"))

        let upload = SyncPlanner.uploads(local: report.knowledge, serverManifest: [], fullyFetched: report.fullyFetchedCourseIDs)
        let claim = try #require(upload.fullySyncedCourses.first)
        #expect(claim.courseID == "A")
        #expect(Set(claim.documentIDs) == held)
    }

    @Test("a failed announcements call, which covers every course, makes every fetched course partial and keeps their announcements")
    func failedAnnouncementsMakesCoursesPartial() async throws {
        let env = Env()
        try env.seed([document("A", .announcement, "5"), document("B", .announcement, "6")])
        env.healthyCourse("A")
        env.healthyCourse("B")
        env.route("/api/v1/announcements", Reply(status: 500))

        let report = try await env.collector().run(courses: [course("A"), course("B")])

        #expect(report.fullyFetchedCourseIDs.isEmpty)
        #expect(report.partialCourseIDs == ["A", "B"])
        #expect(ids(report).isSuperset(of: ["announcement:A:5", "announcement:B:6"]))
        #expect(report.errors.contains { $0.hasPrefix("announcements") })
        // Both courses still answered, so the "couldn't read" notice stays off.
        #expect(report.syncedCourses == 2)
    }

    @Test("a page body that fails to load makes the course partial; a page deleted since the listing (404) does not")
    func failedPageBody() async throws {
        let env = Env()
        try env.seed([document("A", .page, "flaky")])
        env.healthyCourse("A", pages: [PageFixture(slug: "flaky"), PageFixture(slug: "fine")])
        env.route("/api/v1/courses/A/pages/flaky", Reply(status: 500))

        let failed = try await env.collector().run(courses: [course("A")])
        #expect(failed.partialCourseIDs == ["A"])
        #expect(failed.fullyFetchedCourseIDs.isEmpty)
        #expect(ids(failed).isSuperset(of: ["page:A:flaky", "page:A:fine"]))
        #expect(failed.errors.contains { $0.contains("page flaky") })

        env.route("/api/v1/courses/A/pages/flaky", Reply(status: 404))
        let deleted = try await env.collector().run(courses: [course("A")])
        #expect(deleted.partialCourseIDs.isEmpty)
        #expect(deleted.fullyFetchedCourseIDs == ["A"])
        #expect(!ids(deleted).contains("page:A:flaky"))
    }

    // MARK: - Syllabus failures versus no syllabus

    @Test("a syllabus request that fails makes the course partial and keeps the stored syllabus, whichever source failed")
    func failedSyllabusRequest() async throws {
        for failing in ["/api/v1/courses/A", "/api/v1/courses/A/pages?search", "/api/v1/courses/A/files?search"] {
            let env = Env()
            try env.seed([document("A", .syllabus, "syllabus-body-A", text: "old syllabus")])
            env.healthyCourse("A")
            env.route(failing, Reply(status: 500))

            let report = try await env.collector().run(courses: [course("A")])

            #expect(report.partialCourseIDs == ["A"], "\(failing)")
            #expect(report.fullyFetchedCourseIDs.isEmpty, "\(failing)")
            #expect(report.errors.contains { $0.hasPrefix("CIS A syllabus") }, "\(failing)")
            if failing != "/api/v1/courses/A" {
                // The body source still answered, so it is refreshed in place.
                #expect(report.knowledge.documents.first { $0.id == "syllabus:A:syllabus-body-A" }?.text.contains("Late policy") == true)
            } else {
                #expect(report.knowledge.documents.first { $0.id == "syllabus:A:syllabus-body-A" }?.text == "old syllabus")
            }
        }
    }

    @Test("a course with no syllabus is not an error: an empty syllabus body, or a 404 from every syllabus source, leaves it fully synced")
    func noSyllabusIsNotAnError() async throws {
        // Empty body: Canvas answers 200 with a null syllabus_body.
        let empty = Env()
        empty.healthyCourse("A", syllabus: nil)
        let emptyReport = try await empty.collector().run(courses: [course("A")])
        #expect(emptyReport.fullyFetchedCourseIDs == ["A"])
        #expect(emptyReport.errors.isEmpty)
        #expect(!ids(emptyReport).contains { $0.hasPrefix("syllabus:") })

        // 404: every syllabus source says there is nothing there.
        let missing = Env()
        missing.healthyCourse("A")
        missing.route("/api/v1/courses/A", Reply(status: 404))
        missing.route("/api/v1/courses/A/pages?search", Reply(status: 404))
        missing.route("/api/v1/courses/A/files?search", Reply(status: 404))
        let missingReport = try await missing.collector().run(courses: [course("A")])
        #expect(missingReport.fullyFetchedCourseIDs == ["A"])
        #expect(missingReport.errors.isEmpty)
    }

    @Test("the syllabus client's findCandidates still swallows failures, since the paste-a-syllabus screen relies on that")
    func findCandidatesStillSwallowsFailures() async throws {
        let env = Env()
        env.route("/api/v1/courses/A", Reply(status: 500))
        let client = CanvasSyllabusClient(baseURL: env.base, cookies: [], session: env.session)

        #expect(try await client.findCandidates(courseID: "A").isEmpty)
        let search = await client.searchCandidates(courseID: "A")
        #expect(search.candidates.isEmpty)
        #expect(search.failures.count == 1)
    }

    // MARK: - Defect 2: 403 is one course, 401 is the session

    @Test("a 403 on one course's assignments does not abort the run: that course is partial and keeps its documents, the others sync and are saved")
    func forbiddenCourseDoesNotAbort() async throws {
        let env = Env()
        try env.seed([document("A", .assignment, "1"), document("A", .page, "p")])
        env.healthyCourse("A")
        env.route("/api/v1/courses/A/assignments", Reply(status: 403, body: #"{"errors":[{"message":"user not authorized"}]}"#))
        env.healthyCourse("B", assignments: [8])

        let report = try await env.collector().run(courses: [course("A"), course("B")])

        #expect(report.partialCourseIDs == ["A"])
        #expect(report.fullyFetchedCourseIDs == ["B"])
        #expect(report.errors.contains { $0.hasPrefix("CIS A assignments") })
        let saved = Set(env.store.load().documents.map(\.id))
        #expect(saved.contains("assignment:B:8"))
        #expect(saved.isSuperset(of: ["assignment:A:1", "page:A:p"]))
    }

    @Test("a 401, or a login page where JSON should be, still throws sessionExpired and saves nothing")
    func expiredSessionStillAborts() async throws {
        let env = Env()
        let original = [document("A", .assignment, "1")]
        try env.seed(original)
        env.healthyCourse("A")
        env.healthyCourse("B")

        env.route("/api/v1/courses/A/assignments", Reply(status: 401, body: #"{"status":"unauthenticated"}"#))
        await #expect(throws: CanvasCourseContentClient.Error.sessionExpired) {
            try await env.collector().run(courses: [course("A"), course("B")])
        }

        env.route("/api/v1/courses/A/assignments", Reply(status: 200, body: "<html>sign in</html>", contentType: "text/html; charset=utf-8"))
        await #expect(throws: CanvasCourseContentClient.Error.sessionExpired) {
            try await env.collector().run(courses: [course("A"), course("B")])
        }
        #expect(env.store.load().documents.map(\.id) == original.map(\.id))
    }

    @Test("the content client reads 403 as an HTTP error and 401 as an expired session")
    func contentClientStatusMapping() async {
        let env = Env()
        let client = env.contentClient()

        env.route("/api/v1/courses/A/assignments", Reply(status: 403, body: "{}"))
        await #expect(throws: CanvasCourseContentClient.Error.http(403)) { try await client.assignments(courseID: "A") }

        env.route("/api/v1/courses/A/assignments", Reply(status: 401, body: "{}"))
        await #expect(throws: CanvasCourseContentClient.Error.sessionExpired) { try await client.assignments(courseID: "A") }
    }

    // MARK: - Defect 3: which pages get read

    @Test("with 150 published pages, 120 bodies are read, and they include the front page and every module-linked page even when those are the oldest")
    func pageSelection() async throws {
        let env = Env()
        // Listing order is newest first; the front page and the module-linked
        // pages are the oldest of the 150.
        var pages = (1...147).map { PageFixture(slug: "page-\($0)", updatedAt: "2026-09-10T12:00:00Z") }
        pages.append(contentsOf: [
            PageFixture(slug: "linked-a", updatedAt: "2025-01-01T12:00:00Z"),
            PageFixture(slug: "linked-b", updatedAt: "2025-01-01T12:00:00Z"),
        ])
        let front = PageFixture(slug: "welcome", updatedAt: "2024-01-01T12:00:00Z")
        pages.append(front)
        #expect(pages.count == 150)
        env.healthyCourse("A", pages: pages, front: front)

        let result = try await env.contentClient().pages(courseID: "A", priorityPageURLs: ["linked-b", "linked-a"])

        #expect(result.failures.isEmpty)
        #expect(result.frontPage?.url == "welcome")
        let slugs = result.pages.map(\.url)
        #expect(slugs.count + 1 == 120)                       // 119 pages and the front page
        #expect(!slugs.contains("welcome"))                   // read once, as the home document
        #expect(slugs.prefix(2) == ["linked-b", "linked-a"])  // module order, ahead of recency
        #expect(slugs.dropFirst(2).first == "page-1")         // then newest first
        #expect(!slugs.contains("page-147"))                  // pushed past the cap
        // Exactly the bodies reported were requested, and no others.
        let bodyRequests = env.requested.filter { $0.hasPrefix("/api/v1/courses/A/pages/") }
        #expect(bodyRequests.count == 119)
    }

    @Test("the collector builds the front page as a home document and reads module-linked pages the recency order would have skipped")
    func collectorBuildsHomeAndReadsLinkedPages() async throws {
        let env = Env()
        let recent = (1...130).map { PageFixture(slug: "page-\($0)", updatedAt: "2026-09-10T12:00:00Z") }
        let linked = PageFixture(slug: "week-3-reading", body: "<p>Read chapter 3.</p>", updatedAt: "2024-05-05T12:00:00Z")
        let front = PageFixture(slug: "front", title: "Welcome", body: "<p>Office hours Tuesday 4pm.</p>", updatedAt: "2024-01-01T12:00:00Z")
        env.healthyCourse("A", pages: recent + [linked, front], front: front, modulePageSlugs: ["week-3-reading"])

        let report = try await env.collector().run(courses: [course("A")])

        #expect(report.fullyFetchedCourseIDs == ["A"])
        let home = try #require(report.knowledge.documents.first { $0.kind == .home })
        #expect(home.id == "home:A:front")
        #expect(home.title == "Welcome")
        #expect(home.text == "Office hours Tuesday 4pm.")
        #expect(ids(report).contains("page:A:week-3-reading"))
        #expect(!ids(report).contains("page:A:front"))
        #expect(report.knowledge.documents.filter { $0.kind == .page }.count == 119)
        // The server takes the kind: it survives the wire round trip.
        #expect(CourseDocumentWire(document: home).document()?.kind == .home)
    }

    @Test("a course with no front page (404) is not an error; a front page request that fails is")
    func frontPageFailureModes() async throws {
        let none = Env()
        none.healthyCourse("A", pages: [PageFixture(slug: "p")])
        let noFront = try await none.collector().run(courses: [course("A")])
        #expect(noFront.fullyFetchedCourseIDs == ["A"])
        #expect(!noFront.knowledge.documents.contains { $0.kind == .home })

        let broken = Env()
        broken.healthyCourse("A", pages: [PageFixture(slug: "p")])
        broken.route("/api/v1/courses/A/front_page", Reply(status: 500))
        let failed = try await broken.collector().run(courses: [course("A")])
        #expect(failed.partialCourseIDs == ["A"])
        #expect(ids(failed).contains("page:A:p"))
    }

    @Test("a page whose updated_at has not moved is not downloaded again, and its stored document is kept; a changed one is")
    func unchangedPageIsNotRefetched() async throws {
        let env = Env()
        let stamp = "2026-09-01T12:00:00Z"
        try env.seed([
            document("A", .page, "same", text: "stored same", updatedAt: date(stamp)),
            document("A", .page, "moved", text: "stored moved", updatedAt: date("2026-08-01T12:00:00Z")),
        ])
        env.healthyCourse("A", pages: [
            PageFixture(slug: "same", body: "<p>fresh same</p>", updatedAt: stamp),
            PageFixture(slug: "moved", body: "<p>fresh moved</p>", updatedAt: stamp),
        ])

        let report = try await env.collector().run(courses: [course("A")])

        let requested = env.requested
        #expect(!requested.contains("/api/v1/courses/A/pages/same"))
        #expect(requested.contains("/api/v1/courses/A/pages/moved"))
        #expect(report.fullyFetchedCourseIDs == ["A"])
        let byID = Dictionary(uniqueKeysWithValues: report.knowledge.documents.map { ($0.id, $0) })
        #expect(byID["page:A:same"]?.text == "stored same")
        #expect(byID["page:A:moved"]?.text == "fresh moved")
    }

    @Test("the page selection skips unpublished pages even when a module links to them")
    func unpublishedPagesAreNotRead() async throws {
        let env = Env()
        env.healthyCourse("A", pages: [PageFixture(slug: "draft", published: false), PageFixture(slug: "live")], modulePageSlugs: ["draft"])

        let result = try await env.contentClient().pages(courseID: "A", priorityPageURLs: ["draft"])

        #expect(result.pages.map(\.url) == ["live"])
        #expect(!env.requested.contains("/api/v1/courses/A/pages/draft"))
    }

    // MARK: - Pieces

    @Test("a Page module item carries its slug as pageURL; other item types do not, and the date overlay keeps it")
    func moduleItemPageSlug() {
        let json = #"""
        [{"name": "Week 1", "items": [
          {"id": 1, "title": "Syllabus page", "type": "Page", "page_url": "syllabus-page"},
          {"id": 2, "title": "Slides", "type": "File", "content_id": 77, "page_url": "stray"},
          {"id": 3, "title": "Quiz", "type": "Quiz", "content_id": 9}
        ]}]
        """#
        let items = CanvasModulesClient.moduleItems(fromPages: [Data(json.utf8)])
        #expect(items.map(\.pageURL) == ["syllabus-page", nil, nil])

        let planner = [PlannerDatedItem(plannableType: "wiki_page", plannableID: "1", plannedAt: date("2026-09-20T12:00:00Z"), title: "Syllabus page")]
        let overlaid = CanvasModulesClient.overlayDates(items, planner: planner)
        #expect(overlaid.first?.dueAt != nil)
        #expect(overlaid.first?.pageURL == "syllabus-page")
    }
}
