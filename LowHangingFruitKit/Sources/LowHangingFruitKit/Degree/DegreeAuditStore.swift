import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// What is stored is what Path@Penn's own page returned through the hidden
// WebView (shape observed 2026-11-10): the student's degrees, the audit
// decoded from the page's response, and Penn's public program catalogue.

/// The audit and what-ifs of a degree that is not the selected one, kept so a
/// chip tap can show them at once. Switching chips used to discard the other
/// degree's audit and force a 30-second read of something that had not
/// changed since the last registration or grade posting.
public struct DegreeShelf: Codable, Sendable, Equatable {
    public var audit: DegreeAudit?
    public var whatIfs: [DegreeAudit]

    public init(audit: DegreeAudit? = nil, whatIfs: [DegreeAudit] = []) {
        self.audit = audit
        self.whatIfs = whatIfs
    }
}

public struct DegreeSnapshot: Codable, Sendable, Equatable {
    public var current: DegreeAudit?
    /// Most recent first, at most 5 (the store enforces it on save).
    public var whatIfs: [DegreeAudit]
    /// The student's own curriculum entries, from the page's record.
    public var degrees: [StudentDegree]
    /// `StudentDegree.id` of the one being audited; nil means the first.
    public var selectedDegreeID: String?
    /// Penn's public program catalogue (code and title), cached because it is
    /// about a thousand rows and never personal.
    public var programs: [PathProgramListing]
    public var dictionaries: PathDictionaries?
    /// DEBUG key shape of the last audit: key names only, never values.
    public var lastShape: [String]
    /// Term code ("202630") -> the course codes taken, being taken or
    /// registered in that term, in Penn's order. Penn's audit names no term for
    /// a course, so the timeline table reads its past and current columns from
    /// here. Empty until something fills it.
    public var history: [String: [String]]
    /// The audits of the degrees that are not selected, by `StudentDegree.id`.
    /// The selected degree's audit lives in `current`, never here.
    public var shelved: [String: DegreeShelf]

    public init(
        current: DegreeAudit? = nil,
        whatIfs: [DegreeAudit] = [],
        degrees: [StudentDegree] = [],
        selectedDegreeID: String? = nil,
        programs: [PathProgramListing] = [],
        dictionaries: PathDictionaries? = nil,
        lastShape: [String] = [],
        history: [String: [String]] = [:],
        shelved: [String: DegreeShelf] = [:]
    ) {
        self.current = current
        self.whatIfs = whatIfs
        self.degrees = degrees
        self.selectedDegreeID = selectedDegreeID
        self.programs = programs
        self.dictionaries = dictionaries
        self.lastShape = lastShape
        self.history = history
        self.shelved = shelved
    }

    /// Moves the snapshot to another degree without losing the one it leaves:
    /// the current audit and what-ifs go on the shelf under `oldID`, and the
    /// shelf for `id` (if any) becomes `current` and `whatIfs`. A degree with
    /// no shelf shows nothing until it is read. The wrong fix for the slow
    /// switch was hiding the "reading" line; the blank screen and the sign-in
    /// to Penn behind it would still have happened every time.
    public func selecting(_ id: String, from oldID: String?) -> DegreeSnapshot {
        if oldID == id { return self }
        var next = self
        if let oldID, current != nil || !whatIfs.isEmpty {
            next.shelved[oldID] = DegreeShelf(audit: current, whatIfs: whatIfs)
        }
        let restored = next.shelved.removeValue(forKey: id)
        next.current = restored?.audit
        next.whatIfs = restored?.whatIfs ?? []
        next.selectedDegreeID = id
        return next
    }

    /// Drops shelves for degrees the record no longer lists, and the shelf for
    /// the selected degree, whose audit is `current`: a shelf under that id
    /// would be a stale second copy.
    public func pruningShelves(keeping ids: [String], selected: String?) -> DegreeSnapshot {
        var next = self
        next.shelved = shelved.filter { ids.contains($0.key) && $0.key != selected }
        return next
    }

    public static let empty = DegreeSnapshot()

    private enum CodingKeys: String, CodingKey {
        case current, whatIfs, degrees, selectedDegreeID, programs, dictionaries, lastShape, history, shelved
    }

    /// Lenient on purpose: a file written before the Path@Penn rewrite has a
    /// `catalog` key and none of the new ones. A strict decode would fail, the
    /// store would quarantine the file, and the student's last audit would
    /// vanish for nothing. Unknown keys (that `catalog`) are ignored by default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.current = try container.decodeIfPresent(DegreeAudit.self, forKey: .current)
        self.whatIfs = try container.decodeIfPresent([DegreeAudit].self, forKey: .whatIfs) ?? []
        self.degrees = try container.decodeIfPresent([StudentDegree].self, forKey: .degrees) ?? []
        self.selectedDegreeID = try container.decodeIfPresent(String.self, forKey: .selectedDegreeID)
        self.programs = try container.decodeIfPresent([PathProgramListing].self, forKey: .programs) ?? []
        self.dictionaries = try container.decodeIfPresent(PathDictionaries.self, forKey: .dictionaries)
        self.lastShape = try container.decodeIfPresent([String].self, forKey: .lastShape) ?? []
        self.history = try container.decodeIfPresent([String: [String]].self, forKey: .history) ?? [:]
        self.shelved = try container.decodeIfPresent([String: DegreeShelf].self, forKey: .shelved) ?? [:]
    }
}

/// One JSON file in Application Support, the `CourseKnowledgeStore` pattern:
/// not the ledger (every byte can be read again from Path@Penn), not a
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
    /// Path@Penn on the next refresh.
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
        for (key, shelf) in trimmed.shelved where shelf.whatIfs.count > Self.maxWhatIfs {
            trimmed.shelved[key]?.whatIfs = Array(shelf.whatIfs.prefix(Self.maxWhatIfs))
        }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(trimmed)
        try data.write(to: fileURL, options: .atomic)
        // The record is re-fetchable from Path@Penn and belongs to this one
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
