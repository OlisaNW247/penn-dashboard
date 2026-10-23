import Foundation
import Testing
@testable import LowHangingFruitKit

/// The Canvas collector must not delete a student's stored Ed Discussion
/// posts (2026-10-23). It merges each re-fetched course with its own list as
/// that course's complete set, and its list never holds an Ed post (Ed's pass
/// produces those, afterwards), so it used to drop every re-fetched course's
/// Ed posts and save the result to disk. Ed's pass restored them from memory
/// only if it ran to the end; an app suspended in the gap, or an Ed step that
/// never started, left a store with none, and the next run had nothing to
/// restore from.
///
/// These run the real `run`, with every Canvas request answered by an empty
/// list (a stateless `URLProtocol`, so no serialization is needed), so the
/// course counts as fully re-synced: the exact condition under which the old
/// merge dropped the Ed posts. The assertion that matters reads the file back
/// from the store's directory, not the report.
@Suite("Course knowledge collector keeps Ed posts")
struct CourseKnowledgeCollectorEdTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let before = Date(timeIntervalSince1970: 1_799_000_000)

    private static let course = CourseSummary(
        courseID: "1234",
        code: "CIS 2620",
        name: "CIS 2620 Automata",
        url: URL(string: "https://canvas.upenn.edu/courses/1234")
    )

    /// Answers every request with an empty JSON list, so each per-course
    /// endpoint succeeds and returns nothing.
    private final class EmptyListURLProtocol: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeCollector() -> (collector: CourseKnowledgeCollector, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("collector-ed-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmptyListURLProtocol.self]
        let collector = CourseKnowledgeCollector(
            cookies: [],
            store: CourseKnowledgeStore(directory: directory),
            session: URLSession(configuration: configuration)
        )
        return (collector, directory)
    }

    private func document(_ courseID: String, kind: CourseDocument.Kind, id: String) -> CourseDocument {
        CourseDocument(
            courseID: courseID, course: "CIS \(courseID)", kind: kind, sourceID: id,
            title: "Doc \(id)", url: nil, text: "text \(id)", fetchedAt: Self.before
        )
    }

    @Test("a run that fully re-syncs a course leaves its Ed posts on disk, and still drops its vanished pages")
    func edPostsSurviveOnDisk() async throws {
        let (collector, directory) = makeCollector()
        defer { try? FileManager.default.removeItem(at: directory) }

        // What an earlier Ed read left in the store: Ed posts for the course
        // being re-fetched, one for a course this run does not touch, and a
        // page Canvas no longer lists.
        let seeded = CourseKnowledgeBase(
            courses: [Self.course],
            documents: [
                document("1234", kind: .ed, id: "900"),
                document("1234", kind: .ed, id: "901"),
                document("1234", kind: .page, id: "deleted-page"),
                document("5678", kind: .ed, id: "910"),
            ],
            lastSyncedAt: Self.before
        )
        try CourseKnowledgeStore(directory: directory).save(seeded)

        let report = try await collector.run(courses: [Self.course], now: Self.now)

        // The precondition that makes this a regression test: the course
        // counted as fully re-synced, the condition under which the old
        // merge treated the run's list as the course's complete set.
        #expect(report.fullyFetchedCourseIDs == ["1234"])

        // Read back from a fresh store over the same directory: the bytes a
        // suspended app would be left with.
        let onDisk = CourseKnowledgeStore(directory: directory).load()
        #expect(Set(onDisk.documents.map(\.id)) == ["ed:1234:900", "ed:1234:901", "ed:5678:910"])
        #expect(onDisk.documents.first { $0.id == "ed:1234:900" }?.fetchedAt == Self.before)
        #expect(onDisk.documents.contains { $0.id == "page:1234:deleted-page" } == false)

        // The report the caller hands to Ed's pass carries them too.
        #expect(Set(report.knowledge.documents.filter { $0.kind == .ed }.map(\.id)) == ["ed:1234:900", "ed:1234:901", "ed:5678:910"])
    }
}
