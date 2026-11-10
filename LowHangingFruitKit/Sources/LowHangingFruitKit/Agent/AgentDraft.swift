import Foundation

/// One draft an agent proposed through `propose_submission`, as
/// `agent-snapshot`'s `drafts` action answers it (`backend/PROTOCOL.md`, "The
/// agent connection" → `agent-snapshot`). The wire is snake_case and the rest
/// of this backend's wire is camelCase, so the keys are spelled out here
/// rather than reaching for a decoder strategy that would also rename every
/// other type decoded with the same decoder.
///
/// Everything is optional except the id, the assignment and the kind, and
/// decoding is lenient field by field: a draft whose `created_at` comes back
/// in a shape the parser does not know still shows on the card. The one
/// thing that must not be lenient is `kind`: a kind this build does not know
/// decodes as `.unknown`, which the submitter refuses, so a future server
/// kind can never be sent to Canvas as text by accident.
///
/// Drafts live on `AppState` in memory and, stripped of their content, in a
/// small `UserDefaults.lhf` cache (`AgentDraftCache`). Never in the ledger:
/// a draft is the agent's proposal, not the student's work, and the ledger's
/// schema is not where an experiment goes (CLAUDE.md, Traps).
public struct AgentDraft: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text, url, file, unknown
        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// The server's state machine: proposed → seen → declined | submitted |
    /// failed. The `drafts` list only ever carries the first two; the rest
    /// are what the phone writes back.
    public enum Status: String, Codable, Sendable {
        case proposed, seen, declined, submitted, failed, unknown
        public init(from decoder: Decoder) throws {
            let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
            self = Status(rawValue: raw) ?? .unknown
        }
        public var isOpen: Bool { self == .proposed || self == .seen }
    }

    public var id: String
    /// The snapshot work item's id, which is the dashboard item's id
    /// (`syncWorkList` uses `Assignment.id`), so matching is an equality.
    public var assignmentID: String
    public var kind: Kind
    public var body: String?
    public var url: String?
    public var fileName: String?
    public var mimeType: String?
    public var fileBytes: Int?
    public var note: String?
    public var clientName: String?
    public var status: Status
    public var createdAt: String?
    /// A 120-second Storage signed URL, for `file` drafts only. A bearer
    /// link while it lives: never logged, never cached.
    public var fileURL: String?
    /// "markdown" or "text" when the server ever says what `body` is; absent
    /// today. Decoded leniently: any other shape is nil and detection decides
    /// (`DraftDocumentRenderer`).
    public var format: String?

    public init(id: String, assignmentID: String, kind: Kind, body: String? = nil, url: String? = nil,
                fileName: String? = nil, mimeType: String? = nil, fileBytes: Int? = nil,
                note: String? = nil, clientName: String? = nil, status: Status = .proposed,
                createdAt: String? = nil, fileURL: String? = nil, format: String? = nil) {
        self.id = id; self.assignmentID = assignmentID; self.kind = kind; self.body = body
        self.url = url; self.fileName = fileName; self.mimeType = mimeType; self.fileBytes = fileBytes
        self.note = note; self.clientName = clientName; self.status = status
        self.createdAt = createdAt; self.fileURL = fileURL; self.format = format
    }

    enum CodingKeys: String, CodingKey {
        case id
        case assignmentID = "assignment_id"
        case kind, body, url
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileBytes = "file_bytes"
        case note
        case clientName = "client_name"
        case status
        case createdAt = "created_at"
        case fileURL = "file_url"
        case format
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        assignmentID = try c.decode(String.self, forKey: .assignmentID)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .unknown
        body = try? c.decodeIfPresent(String.self, forKey: .body)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
        mimeType = try? c.decodeIfPresent(String.self, forKey: .mimeType)
        fileBytes = try? c.decodeIfPresent(Int.self, forKey: .fileBytes)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        clientName = try? c.decodeIfPresent(String.self, forKey: .clientName)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .unknown
        createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
        fileURL = try? c.decodeIfPresent(String.self, forKey: .fileURL)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
    }

    /// The name the card and the sheet print. The server stores the client's
    /// self-declared name; "claude" when it sent none, since Claude is the
    /// only client this has been tested with.
    public var agentName: String {
        let trimmed = (clientName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Claude" : String(trimmed.prefix(40))
    }

    public var createdDate: Date? { createdAt.flatMap(BackendJSON.parseDate) }

    /// The same draft with nothing an agent wrote in it: what the cache keeps.
    /// The chip on a card needs the id, the assignment, the kind, the agent's
    /// name and the file's name and size; the body, the link, the note and the
    /// signed URL wait for the next poll, so none of them sits in defaults.
    public var strippedForCache: AgentDraft {
        AgentDraft(id: id, assignmentID: assignmentID, kind: kind, fileName: fileName,
                   mimeType: mimeType, fileBytes: fileBytes, clientName: clientName,
                   status: status, createdAt: createdAt)
    }

    /// The opened card's few lines: the body's first lines, the link, or the
    /// file's name and size. Nil when the content has not arrived yet (a
    /// cached draft before the first poll).
    public func preview(maxLines: Int = 3, maxCharacters: Int = 240) -> String? {
        switch kind {
        case .text:
            guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let lines = body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(maxLines)
            var text = lines.joined(separator: "\n")
            if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) + "\u{2026}" }
            return text
        case .url:
            return url
        case .file:
            guard let fileName else { return nil }
            return fileBytes.map { "\(fileName) \u{00B7} \(Self.byteText($0))" } ?? fileName
        case .unknown:
            return nil
        }
    }

    /// "48 KB", "1.2 MB": the size a person reads.
    public static func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// The content-free copy of the open drafts kept in `UserDefaults.lhf`, so a
/// relaunch draws the chip on the card before the first poll answers. Pure
/// encode and decode; the caller owns the defaults domain (tests pass their
/// own, which is the shared-defaults trap in CLAUDE.md).
public enum AgentDraftCache {
    public static let key = "agentDraftsCacheV1"
    public static let maxEntries = 50

    public static func encode(_ drafts: [AgentDraft]) -> Data? {
        let stripped = drafts.filter { $0.status.isOpen }.prefix(maxEntries).map(\.strippedForCache)
        return try? JSONEncoder().encode(Array(stripped))
    }

    public static func decode(_ data: Data?) -> [AgentDraft] {
        guard let data, let drafts = try? JSONDecoder().decode([AgentDraft].self, from: data) else { return [] }
        return drafts.filter { $0.status.isOpen }
    }

    public static func load(from defaults: UserDefaults) -> [AgentDraft] {
        decode(defaults.data(forKey: key))
    }

    public static func save(_ drafts: [AgentDraft], to defaults: UserDefaults) {
        if drafts.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = encode(drafts) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Which drafts deserve a "Claude drafted …" notification: open, matched to a
/// card the dashboard shows, and never announced before. Pure, so the "once
/// per draft" rule is a test, not a hope.
public enum AgentDraftNotices {
    public static let notifiedKey = "agentDraftsNotifiedV1"
    /// The remembered set is bounded: a draft id older than the newest 200 is
    /// long decided, and the server never lists it again.
    public static let maxRemembered = 200

    public struct Notice: Equatable, Sendable {
        public let draftID: String
        public let title: String
        public let body: String
    }

    /// `titleFor` answers the dashboard item's title, or nil when no card
    /// shows that assignment (nothing to open, so nothing to announce; the
    /// draft is still remembered so it never announces late).
    public static func plan(
        drafts: [AgentDraft],
        alreadyNotified: [String],
        titleFor: (String) -> String?
    ) -> (notices: [Notice], remembered: [String]) {
        var remembered = alreadyNotified
        let known = Set(alreadyNotified)
        var notices: [Notice] = []
        for draft in drafts where draft.status.isOpen && !known.contains(draft.id) {
            remembered.append(draft.id)
            guard let title = titleFor(draft.assignmentID) else { continue }
            notices.append(Notice(draftID: draft.id, title: "\(draft.agentName) drafted \(title)", body: ""))
        }
        if remembered.count > maxRemembered { remembered = Array(remembered.suffix(maxRemembered)) }
        return (notices, remembered)
    }
}
