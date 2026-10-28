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

    /// What a read of the file found: the knowledge base, and how much of the
    /// file it could not use.
    public struct LoadReport: Sendable {
        public let knowledge: CourseKnowledgeBase
        /// Elements (documents, courses, catalog entries, grading profiles)
        /// that were in the file and could not be decoded. Zero for a clean
        /// file and for a missing one.
        public let droppedCount: Int
        /// Where the original file was set aside, when it was damaged. `nil`
        /// for a clean or missing file.
        public let quarantinedTo: URL?
    }

    public func load() -> CourseKnowledgeBase {
        loadReport().knowledge
    }

    /// Reads the file, losing only the elements that are wrong.
    ///
    /// The file used to be all-or-nothing: any element that failed to decode
    /// made `load()` return `.empty`, and the next `save` wrote that empty
    /// base over the file, so one bad document cost the student every
    /// document and course they had synced (until the next full sync, and
    /// the Ed posts only came back if Ed's own pass ran). Now:
    ///
    /// - A file that decodes with some elements wrong keeps the rest, and the
    ///   count of what was lost is on the report. The original bytes are
    ///   copied to `course-knowledge.json.corrupt-<unix time>` first, and
    ///   only then is the cleaned base written back over the file, so the
    ///   same damage is neither re-reported on every read nor lost.
    /// - A file that cannot be read as a knowledge base at all is moved to
    ///   that name rather than overwritten, and `.empty` is returned.
    ///
    /// A missing file, or one that cannot be read off the disk (an I/O
    /// error, not a decode error), is left exactly where it is. Nothing here
    /// is the student's own record, every byte can be re-fetched, but a
    /// file that is merely unreadable today is not one to rename away.
    ///
    /// The wrong fix is to default the failing field at the decode site: it
    /// would hide that a store was damaged, and the sync, which retires
    /// documents Canvas no longer lists, has to know a course read back
    /// short of what was written (`CourseKnowledgeCollector` counts a
    /// dropped element as a course error for that reason).
    public func loadReport(now: Date = Date()) -> LoadReport {
        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadReport(knowledge: .empty, droppedCount: 0, quarantinedTo: nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let tally = LossyDecodeTally()
        decoder.userInfo[LossyDecodeTally.userInfoKey] = tally
        guard let knowledge = try? decoder.decode(CourseKnowledgeBase.self, from: data) else {
            let moved = setAside(now: now, move: true)
            return LoadReport(knowledge: .empty, droppedCount: 0, quarantinedTo: moved)
        }
        let dropped = tally.droppedCount
        guard dropped > 0 else {
            return LoadReport(knowledge: knowledge, droppedCount: 0, quarantinedTo: nil)
        }
        // Copy, not move: if the copy fails the original stays where it is
        // and is not overwritten, and the next read tries again.
        let copied = setAside(now: now, move: false)
        if copied != nil { try? save(knowledge) }
        return LoadReport(knowledge: knowledge, droppedCount: dropped, quarantinedTo: copied)
    }

    /// `course-knowledge.json.corrupt-<unix time>`, with a counter appended if
    /// that name is taken (two reads in one second).
    private func setAside(now: Date, move: Bool) -> URL? {
        let fileManager = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        var destination = fileURL.appendingPathExtension("corrupt-\(stamp)")
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = fileURL.appendingPathExtension("corrupt-\(stamp)-\(attempt)")
        }
        do {
            if move {
                try fileManager.moveItem(at: fileURL, to: destination)
            } else {
                try fileManager.copyItem(at: fileURL, to: destination)
            }
            return destination
        } catch {
            return nil
        }
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
