import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Assignment attachment wiring")
struct AssignmentAttachmentWiringTests {
    private func uiSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/LowHangingFruitUI/\(name)")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("refreshCourseKnowledge runs the pass after its upload, once")
    func afterUpload() throws {
        let src = try uiSource("AppState+CourseKnowledge.swift")
        guard !src.isEmpty else { return }
        let start = try #require(src.range(of: "func refreshCourseKnowledge("))
        let end = try #require(src.range(of: "private func mergeEdDiscussion", range: start.upperBound..<src.endIndex))
        let body = String(src[start.upperBound..<end.lowerBound])
        let upload = try #require(body.range(of: "client.syncUpload(batch)"))
        let pass = try #require(body.range(of: "await attachmentPass(cookies: cookies)"))
        #expect(upload.upperBound <= pass.lowerBound)
        #expect(src.components(separatedBy: "attachmentPass(").count == 2)
    }

    @Test("the background wake never runs it")
    func notInBackground() throws {
        let src = try uiSource("BackgroundRefresh.swift")
        #expect(!src.contains("attachmentPass"))
    }

    @Test("the pass keeps its guards and its two keys")
    func guards() throws {
        let src = try uiSource("AppState+AssignmentAttachments.swift")
        guard !src.isEmpty else { return }
        #expect(src.contains("renewalContext != .background"))
        #expect(src.contains("!isUsingFixtureData"))
        #expect(src.contains("!cookies.isEmpty"))
        #expect(src.contains("\"attachmentAttemptsV1\""))
        #expect(src.contains("\"lastAttachmentSyncSummaryV1\""))
    }

    @Test("a failed save leaves the published knowledge alone")
    func saveFailureGuard() throws {
        let src = try uiSource("AppState+AssignmentAttachments.swift")
        guard !src.isEmpty else { return }
        let save = try #require(src.range(of: "try CourseKnowledgeStore.default().save(knowledge)"))
        let publish = try #require(src.range(of: "courseKnowledge = knowledge"))
        #expect(save.upperBound <= publish.lowerBound)
        #expect(!src.contains("try? CourseKnowledgeStore"))
    }

    @Test("attempts older than seven days are pruned on load")
    func prune() {
        let now = Date()
        let saved = UserDefaults.lhf.object(forKey: AppState.attachmentAttemptsKey)
        defer {
            if let saved { UserDefaults.lhf.set(saved, forKey: AppState.attachmentAttemptsKey) }
            else { UserDefaults.lhf.removeObject(forKey: AppState.attachmentAttemptsKey) }
        }
        UserDefaults.lhf.set([
            "old": now.addingTimeInterval(-8 * 86_400).timeIntervalSince1970,
            "new": now.addingTimeInterval(-3_600).timeIntervalSince1970,
            "nt": AssignmentAttachmentAttempt(date: now.addingTimeInterval(-3_600), kind: .noText).encoded,
        ] as [String: Any], forKey: AppState.attachmentAttemptsKey)
        let loaded = AppState.loadAttachmentAttempts(now: now)
        #expect(Set(loaded.keys) == ["new", "nt"])
        #expect(loaded["new"]?.kind == .failed)
        #expect(loaded["nt"]?.kind == .noText)
    }
}
