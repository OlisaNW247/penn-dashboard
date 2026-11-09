import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// What is stored was read from Degree Works endpoints that are UNVERIFIED
// against Penn's live system.

public struct DegreeSnapshot: Codable, Sendable, Equatable {
    public var current: DegreeAudit?
    /// Most recent first, at most 5 (the store enforces it on save).
    public var whatIfs: [DegreeAudit]
    public var catalog: DegreeGoalCatalog?
    /// DEBUG key shape of the last audit: key names only, never values.
    public var lastShape: [String]

    public init(current: DegreeAudit? = nil, whatIfs: [DegreeAudit] = [], catalog: DegreeGoalCatalog? = nil, lastShape: [String] = []) {
        self.current = current
        self.whatIfs = whatIfs
        self.catalog = catalog
        self.lastShape = lastShape
    }

    public static let empty = DegreeSnapshot()
}

/// One JSON file in Application Support, the `CourseKnowledgeStore` pattern:
/// not the ledger (every byte can be read again from Degree Works), not a
/// preference, not a credential (those are in the Keychain). It holds the
/// student's academic record, so on iOS it is protected until first unlock.
/// It is never put in iCloud, the App Group, the laptop sync or the backend.
public struct DegreeAuditStore: Sendable {
    public static let maxWhatIfs = 5
    private static let fileName = "degree-audit.json"

    public let fileURL: URL

    public static func `default`() -> DegreeAuditStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DegreeAuditStore(directory: base.appendingPathComponent("LowHangingFruit", isDirectory: true))
    }

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// A missing or unreadable-off-disk file is `.empty` and left alone. A
    /// file that is there but does not decode is moved aside to
    /// `degree-audit.json.corrupt-<unix>` (never overwritten, so a bad write
    /// can be looked at) and `.empty` is returned; the audit is re-read from
    /// Degree Works on the next refresh.
    public func load(now: Date = Date()) -> DegreeSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(DegreeSnapshot.self, from: data) { return snapshot }
        let fileManager = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        var destination = fileURL.appendingPathExtension("corrupt-\(stamp)")
        var attempt = 1
        while fileManager.fileExists(atPath: destination.path) {
            attempt += 1
            destination = fileURL.appendingPathExtension("corrupt-\(stamp)-\(attempt)")
        }
        try? fileManager.moveItem(at: fileURL, to: destination)
        return .empty
    }

    public func save(_ snapshot: DegreeSnapshot) throws {
        var trimmed = snapshot
        if trimmed.whatIfs.count > Self.maxWhatIfs {
            trimmed.whatIfs = Array(trimmed.whatIfs.prefix(Self.maxWhatIfs))
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(trimmed)
        try data.write(to: fileURL, options: .atomic)
        // The record is re-fetchable from Degree Works and belongs to this one
        // phone, so it stays out of iCloud and device backups.
        var excluded = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
        #endif
    }

    /// Removes the file and any quarantined copies; disconnecting Canvas
    /// calls this, and a quarantined copy is still the student's record.
    public func clear() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        let prefix = Self.fileName + ".corrupt-"
        if let names = try? fileManager.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix(prefix) {
                try? fileManager.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
