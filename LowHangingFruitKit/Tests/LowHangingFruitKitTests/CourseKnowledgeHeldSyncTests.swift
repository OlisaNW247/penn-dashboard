import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The course-material sync is held on `AppState` so a view task's
/// cancellation cannot abort it, and a failed manifest says why in the
/// persisted summary. Marco's phone, 2026-11-10: the server logged both
/// manifest calls as 200, the phone logged "manifest failed", and the pages
/// fetches after it failed too, the shape of a cancelled task
/// (`docs/MANIFEST_FAILURE_2026-11-10.md` on the backend session's branch).
@Suite("Course-material sync: held on AppState, manifest failure kind")
struct CourseKnowledgeHeldSyncTests {

    @Test("a cancelled caller reads cancelled, not transport")
    func cancelledFirst() {
        #expect(AppState.manifestErrorKindForSummary(BackendError.transport, cancelled: true, decodingDetail: nil) == "cancelled")
        #expect(AppState.manifestErrorKindForSummary(CancellationError(), cancelled: false, decodingDetail: nil) == "cancelled")
    }

    @Test("otherwise the backend case, with a decode failure's path")
    func backendKinds() {
        #expect(AppState.manifestErrorKindForSummary(BackendError.transport, cancelled: false, decodingDetail: nil) == "transport")
        #expect(AppState.manifestErrorKindForSummary(BackendError.http(500), cancelled: false, decodingDetail: nil) == "http 500")
        let kind = AppState.manifestErrorKindForSummary(
            BackendError.decoding, cancelled: false,
            decodingDetail: "sync: keyNotFound at catalog.0.components (6108 bytes)")
        #expect(kind.hasPrefix("decoding (sync: keyNotFound at catalog.0.components"))
        // A transport error never carries the decode slot's leftover detail.
        #expect(AppState.manifestErrorKindForSummary(BackendError.transport, cancelled: false,
                                                    decodingDetail: "sync: stale") == "transport")
    }

    @Test("the sync runs in a task AppState holds, and a second caller joins it")
    func heldOnAppState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/LowHangingFruitUI/AppState+CourseKnowledge.swift")
        try #require(FileManager.default.fileExists(atPath: url.path))
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try #require(source.range(of: "func refreshCourseKnowledge(cookies: [HTTPCookie], force: Bool = false) async {"))
        let end = try #require(source.range(of: "private func performCourseKnowledgeRefresh(", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        #expect(body.contains("if let pending = pendingCourseKnowledgeSync"))
        #expect(body.contains("await pending.value"))
        #expect(body.contains("let task = Task { @MainActor"))
        #expect(body.contains("pendingCourseKnowledgeSync = task"))
        #expect(body.contains("await task.value"))
        // The run itself is not reachable from outside except through the hold.
        #expect(!source.contains("await performCourseKnowledgeRefresh(") || body.contains("await self?.performCourseKnowledgeRefresh("))
        #expect(source.contains("\"failed\" + (trace.manifestErrorKind.map"))
    }
}
