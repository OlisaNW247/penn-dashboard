import Foundation

// Client-side wire types for the LHF backend (`backend/PROTOCOL.md`). This
// file only defines the shapes the protocol names and the pure conversions
// to/from the on-device `CourseDocument`/`CourseSummary` models; it does not
// perform any network I/O (that belongs to a future `SyncCoordinator` in the
// UI module, which will use `SyncPlanner` alongside these types).
//
// Two protocol principles shape every type here:
//   1. Canvas credentials never appear on the wire — only already-extracted
//      course material and the anonymous Supabase bearer token (handled
//      elsewhere, not part of this file).
//   2. Only course-level material is shared. `CourseDocument.submitted` is
//      the student's own submission state, so `CourseDocumentWire` has no
//      field for it at all — there is no way to accidentally serialize it,
//      because the property doesn't exist on the wire type.

/// A course as sent in the `sync` manifest request. Deliberately narrower
/// than `CourseSummary`: no local ledger fields, just what the server needs
/// to upsert `courses` and record the enrollment.
public struct CourseSummaryWire: Codable, Sendable, Equatable {
    public let courseID: String
    public let code: String
    public let name: String
    public let url: String?
    public let term: String?
    public let sectionIDs: [String]?

    public init(courseID: String, code: String, name: String, url: String?, term: String? = nil, sectionIDs: [String]? = nil) {
        self.courseID = courseID
        self.code = code
        self.name = name
        self.url = url
        self.term = term
        self.sectionIDs = sectionIDs
    }

    /// `term` and `sectionIDs` aren't tracked on `CourseSummary` today (the
    /// protocol notes sections are recorded for future scoping only), so
    /// they're separate parameters rather than derived from the model.
    public init(summary: CourseSummary, term: String? = nil, sectionIDs: [String]? = nil) {
        self.courseID = summary.courseID
        self.code = summary.code
        self.name = summary.name
        self.url = summary.url?.absoluteString
        self.term = term
        self.sectionIDs = sectionIDs
    }
}

/// The identity + hash pair the manifest exchange trades in both directions:
/// the client lists what it already has, and the server lists what it
/// already has, and each side only sends over what the other doesn't.
public struct DocumentStub: Codable, Sendable, Hashable {
    public let id: String
    public let contentHash: String

    public init(id: String, contentHash: String) {
        self.id = id
        self.contentHash = contentHash
    }

    public init(document: CourseDocument) {
        self.id = document.id
        self.contentHash = document.contentHash
    }
}

/// The wire form of `CourseDocument`. Field-for-field identical except for
/// `submitted`, which is simply absent — see the file header. `url` is a
/// plain `String` rather than `URL` because the wire format has no native
/// URL type and a malformed string should be a soft failure (a missing
/// link), not a decode failure for the whole document.
public struct CourseDocumentWire: Codable, Sendable, Equatable {
    public let id: String
    public let courseID: String
    public let course: String
    public let kind: String
    public let sourceID: String
    public let title: String
    public let url: String?
    public let text: String
    public let updatedAt: Date?
    public let fetchedAt: Date
    public let contentHash: String
    public let dueAt: Date?
    public let pointsPossible: Double?

    public init(
        id: String,
        courseID: String,
        course: String,
        kind: String,
        sourceID: String,
        title: String,
        url: String? = nil,
        text: String,
        updatedAt: Date? = nil,
        fetchedAt: Date,
        contentHash: String,
        dueAt: Date? = nil,
        pointsPossible: Double? = nil
    ) {
        self.id = id
        self.courseID = courseID
        self.course = course
        self.kind = kind
        self.sourceID = sourceID
        self.title = title
        self.url = url
        self.text = text
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
        self.contentHash = contentHash
        self.dueAt = dueAt
        self.pointsPossible = pointsPossible
    }

    public init(document: CourseDocument) {
        self.id = document.id
        self.courseID = document.courseID
        self.course = document.course
        self.kind = document.kind.rawValue
        self.sourceID = document.sourceID
        self.title = document.title
        self.url = document.url?.absoluteString
        self.text = document.text
        self.updatedAt = document.updatedAt
        self.fetchedAt = document.fetchedAt
        self.contentHash = document.contentHash
        self.dueAt = document.dueAt
        self.pointsPossible = document.pointsPossible
    }

    /// Converts back to the on-device model, or `nil` if the wire payload
    /// isn't one this client can trust: an unrecognized `kind` (a future
    /// server enum case an older client doesn't know about yet) or an `id`
    /// that doesn't match `"{kind}:{courseID}:{sourceID}"` (a corrupted or
    /// tampered manifest entry — `CourseDocument.id` is computed from those
    /// three fields, so an `id` that disagrees with them can never happen
    /// from a document built normally).
    ///
    /// `contentHash` is not recomputed here — `CourseDocument.init` always
    /// derives it from `title` + `text`, and since `CourseDocumentWire.init(document:)`
    /// is the only thing that ever puts a `contentHash` on the wire, and it
    /// reads that hash straight off the same `CourseDocument.contentHash`
    /// property, the two are the same computation by construction. There is
    /// no code path here that trusts a hash the content doesn't back up.
    public func document() -> CourseDocument? {
        guard let resolvedKind = CourseDocument.Kind(rawValue: kind) else { return nil }
        guard id == "\(resolvedKind.rawValue):\(courseID):\(sourceID)" else { return nil }
        return CourseDocument(
            courseID: courseID,
            course: course,
            kind: resolvedKind,
            sourceID: sourceID,
            title: title,
            url: url.flatMap { URL(string: $0) },
            text: text,
            updatedAt: updatedAt,
            fetchedAt: fetchedAt,
            dueAt: dueAt,
            pointsPossible: pointsPossible,
            submitted: nil
        )
    }
}

/// One course the client fully fetched from Canvas this sync, with every
/// document id it now holds — the server uses the difference between this
/// list and its own live rows to mark vanished documents gone.
public struct FullySyncedCourse: Codable, Sendable, Equatable {
    public let courseID: String
    public let documentIDs: [String]

    public init(courseID: String, documentIDs: [String]) {
        self.courseID = courseID
        self.documentIDs = documentIDs
    }
}

/// Step 1 of `sync`: what the client has, so the server can say what's
/// missing. `action` is a fixed literal, not a caller-supplied value — it
/// exists only so the server's single sync endpoint can tell manifest and
/// upload requests apart.
public struct SyncManifestRequest: Encodable, Sendable, Equatable {
    public let action: String = "manifest"
    public let courses: [CourseSummaryWire]
    public let documents: [DocumentStub]

    public init(courses: [CourseSummaryWire], documents: [DocumentStub]) {
        self.courses = courses
        self.documents = documents
    }
}

/// The server's answer to a manifest request. Every field defaults to empty
/// when the key is absent from the payload rather than failing to decode —
/// a server that has nothing to say about freshness, its own manifest, or
/// downloads (e.g. brand-new courses) is a normal, common response, not a
/// malformed one.
public struct SyncManifestResponse: Decodable, Sendable, Equatable {
    public let coursesFresh: [String]
    public let serverManifest: [DocumentStub]
    public let download: [CourseDocumentWire]

    public init(coursesFresh: [String] = [], serverManifest: [DocumentStub] = [], download: [CourseDocumentWire] = []) {
        self.coursesFresh = coursesFresh
        self.serverManifest = serverManifest
        self.download = download
    }

    private enum CodingKeys: String, CodingKey {
        case coursesFresh, serverManifest, download
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        coursesFresh = try container.decodeIfPresent([String].self, forKey: .coursesFresh) ?? []
        serverManifest = try container.decodeIfPresent([DocumentStub].self, forKey: .serverManifest) ?? []
        download = try container.decodeIfPresent([CourseDocumentWire].self, forKey: .download) ?? []
    }
}

/// Step 2 of `sync`: what the client is adding, and which courses it can
/// now vouch for completely.
public struct SyncUploadRequest: Encodable, Sendable, Equatable {
    public let action: String = "upload"
    public let documents: [CourseDocumentWire]
    public let fullySyncedCourses: [FullySyncedCourse]

    public init(documents: [CourseDocumentWire], fullySyncedCourses: [FullySyncedCourse]) {
        self.documents = documents
        self.fullySyncedCourses = fullySyncedCourses
    }
}

/// The server's answer to an upload. `profileStale` defaults to empty for
/// the same reason as `SyncManifestResponse`'s fields: "nothing changed" is
/// the common case, not an error.
public struct SyncUploadResponse: Decodable, Sendable, Equatable {
    public let accepted: Int
    public let profileStale: [String]

    public init(accepted: Int, profileStale: [String] = []) {
        self.accepted = accepted
        self.profileStale = profileStale
    }

    private enum CodingKeys: String, CodingKey {
        case accepted, profileStale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decode(Int.self, forKey: .accepted)
        profileStale = try container.decodeIfPresent([String].self, forKey: .profileStale) ?? []
    }
}

/// One turn of prior conversation sent with an `ask` request.
public struct AskTurn: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Request body for the streamed `ask` function.
public struct AskRequest: Encodable, Sendable, Equatable {
    public let question: String
    public let contextDocument: String
    public let excerpts: String
    public let askedAt: Date
    public let courseIDs: [String]
    public let history: [AskTurn]

    public init(question: String, contextDocument: String, excerpts: String, askedAt: Date, courseIDs: [String], history: [AskTurn]) {
        self.question = question
        self.contextDocument = contextDocument
        self.excerpts = excerpts
        self.askedAt = askedAt
        self.courseIDs = courseIDs
        self.history = history
    }
}

/// One parsed line of the `ask` server-sent-events stream. This is
/// deliberately not `Codable` — the wire shape is a `type` discriminator
/// plus type-specific fields inside one flat JSON object per line, which
/// doesn't map onto Swift's enum-with-associated-values `Codable` synthesis
/// without a hand-rolled `init(from:)` that would just duplicate `parse`.
/// `parse` is the single source of truth instead.
public enum AskStreamEvent: Equatable, Sendable {
    case delta(String)
    case done(promptTokens: Int, completionTokens: Int, cachedTokens: Int)
    case error(code: String, message: String)

    /// The shape of one decoded event line, before it becomes an
    /// `AskStreamEvent`. Kept private: nothing outside `parse` should ever
    /// need the raw, partially-optional wire shape.
    private struct Raw: Decodable {
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            let cachedTokens: Int?
        }

        let type: String
        let text: String?
        let usage: Usage?
        let code: String?
        let message: String?
    }

    /// Parses one raw line of the SSE stream. Returns `nil` for anything
    /// that isn't a usable event: blank lines, SSE comment lines (`:` per
    /// the SSE spec, used for keepalives), lines that aren't a `data:`
    /// field at all, payloads that aren't valid JSON, and JSON with a
    /// `type` this client doesn't recognize (a forward-compatible no-op
    /// rather than an error, since a future server could add event types an
    /// older client should just ignore). Pure and synchronous — no network,
    /// so it's trivially testable against fixture strings.
    public static func parse(line: String) -> AskStreamEvent? {
        guard !line.isEmpty, line.hasPrefix("data:") else { return nil }
        var payload = String(line.dropFirst("data:".count))
        if payload.hasPrefix(" ") { payload.removeFirst() }
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }

        switch raw.type {
        case "delta":
            guard let text = raw.text else { return nil }
            return .delta(text)
        case "done":
            let usage = raw.usage
            return .done(
                promptTokens: usage?.promptTokens ?? 0,
                completionTokens: usage?.completionTokens ?? 0,
                cachedTokens: usage?.cachedTokens ?? 0
            )
        case "error":
            guard let code = raw.code, let message = raw.message else { return nil }
            return .error(code: code, message: message)
        default:
            return nil
        }
    }
}

/// Request body for `extract-announcement`, replacing the user-key
/// `ClaudeAnnouncementExtractor` path.
public struct ExtractAnnouncementRequest: Encodable, Sendable, Equatable {
    public let announcementID: String
    public let courseCode: String
    public let title: String
    public let message: String
    public let postedAt: Date?
    public let now: Date

    public init(announcementID: String, courseCode: String, title: String, message: String, postedAt: Date?, now: Date) {
        self.announcementID = announcementID
        self.courseCode = courseCode
        self.title = title
        self.message = message
        self.postedAt = postedAt
        self.now = now
    }
}

/// One assignment the model extracted from an announcement's text.
public struct ExtractedAssignmentWire: Codable, Sendable, Equatable {
    public let title: String
    public let dueAt: Date?

    public init(title: String, dueAt: Date?) {
        self.title = title
        self.dueAt = dueAt
    }
}

public struct ExtractAnnouncementResponse: Decodable, Sendable, Equatable {
    public let assignments: [ExtractedAssignmentWire]

    public init(assignments: [ExtractedAssignmentWire]) {
        self.assignments = assignments
    }
}

/// Request body for `extract-profile`. The server does the filtering
/// (enrollment + `profile_stale`); the client just names which courses it
/// cares about right now.
public struct ExtractProfileRequest: Encodable, Sendable, Equatable {
    public let courseIDs: [String]

    public init(courseIDs: [String]) {
        self.courseIDs = courseIDs
    }
}

/// Shared JSON encoding/decoding for every backend wire type, mirroring
/// `CourseContentAPI.decoder()`/`parseDate` in `CanvasCourseContentClient.swift`:
/// dates are ISO 8601, accepted with or without fractional seconds on the
/// way in, always written with fractional seconds on the way out (the
/// protocol's own example, `2026-09-07T14:03:00Z`, uses whole seconds, but
/// fractional is also explicitly allowed, and emitting it uniformly avoids a
/// branch on whether a given `Date` happens to fall on a whole second).
/// Formatters are built fresh per call rather than shared statics —
/// `ISO8601DateFormatter` isn't `Sendable`, and one instance per call is
/// cheap enough that sharing isn't worth the concurrency question.
public enum BackendJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFraction.date(from: raw) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized backend date \(raw)")
        }
        return decoder
    }
}
