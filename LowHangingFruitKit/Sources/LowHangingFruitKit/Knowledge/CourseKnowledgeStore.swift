import Foundation

/// On-device persistence for the course knowledge base: one JSON file in the
/// app's own Application Support directory.
///
/// This is deliberately none of the three storage tiers `CLAUDE.md` names.
/// It is not the ledger (nothing here is the student's own record — every
/// byte can be re-fetched from Canvas), not a preference, and not a
/// credential. It is a cache of course text, so a plain file the app can
/// throw away and rebuild is the right weight. It is app-private rather than
/// in the App Group on purpose: the widget has no use for syllabus prose, and
/// keeping it out of the shared container means the macOS sandbox question
/// that bit the ledger (see the 2026-08-29 decision) never arises here.
public struct CourseKnowledgeStore: Sendable {
    public let fileURL: URL

    /// The app's store, under Application Support/LowHangingFruit/.
    public static func `default`() -> CourseKnowledgeStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return CourseKnowledgeStore(directory: base.appendingPathComponent("LowHangingFruit", isDirectory: true))
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("course-knowledge.json")
    }

    public func load() -> CourseKnowledgeBase {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CourseKnowledgeBase.self, from: data)) ?? .empty
    }

    public func save(_ knowledge: CourseKnowledgeBase) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(knowledge)
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
