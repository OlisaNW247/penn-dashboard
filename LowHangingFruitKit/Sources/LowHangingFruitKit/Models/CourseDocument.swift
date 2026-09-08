import Foundation

/// One piece of course material collected from Canvas, normalized to plain text
/// so it can be indexed and searched on-device. Everything the class chatbot
/// knows comes from these documents plus the calendar-feed `Assignment`s.
public struct CourseDocument: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case home
        case syllabus
        case assignment
        case announcement
        case module
        case page
        /// Crawled from an external course website the instructor linked
        /// from Canvas (a page, assignment description, module item, or the
        /// syllabus) — discovered and fetched server-side (see
        /// `backend/PROTOCOL.md`'s `discover-websites`), not by this client.
        case website

        /// Human label used in source cards ("From the CIS 2400 syllabus").
        public var label: String {
            switch self {
            case .home:         return "course home"
            case .syllabus:     return "syllabus"
            case .assignment:   return "assignment"
            case .announcement: return "announcement"
            case .module:       return "module"
            case .page:         return "page"
            case .website:      return "course website"
            }
        }
    }

    /// Stable identity across syncs: kind + course + Canvas object id.
    public var id: String { "\(kind.rawValue):\(courseID):\(sourceID)" }

    public let courseID: String
    /// Display name for the course, ideally the short code ("CIS 2400").
    public let course: String
    public let kind: Kind
    public let sourceID: String
    public let title: String
    public let url: URL?
    /// Plain text body (HTML already stripped).
    public let text: String
    /// When Canvas last changed the item, if known.
    public let updatedAt: Date?
    /// When the app fetched this version.
    public let fetchedAt: Date
    /// Hash of `title` + `text`, used to skip re-indexing unchanged content.
    public let contentHash: String

    // Assignment-only metadata (nil for other kinds).
    public let dueAt: Date?
    public let pointsPossible: Double?
    /// The student's own submission state, when Canvas reports it.
    public let submitted: Bool?

    public init(
        courseID: String,
        course: String,
        kind: Kind,
        sourceID: String,
        title: String,
        url: URL?,
        text: String,
        updatedAt: Date? = nil,
        fetchedAt: Date = Date(),
        dueAt: Date? = nil,
        pointsPossible: Double? = nil,
        submitted: Bool? = nil
    ) {
        self.courseID = courseID
        self.course = course
        self.kind = kind
        self.sourceID = sourceID
        self.title = title
        self.url = url
        self.text = text
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
        self.contentHash = ContentHash.fnv1a(title + "\u{1F}" + text)
        self.dueAt = dueAt
        self.pointsPossible = pointsPossible
        self.submitted = submitted
    }

    /// Rough word count, used to budget what fits in a small model context.
    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// A course the student is enrolled in, as discovered from Canvas.
public struct CourseSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String { courseID }
    public let courseID: String
    /// Short code ("CIS 2400") when Canvas provides one, else the full name.
    public let code: String
    public let name: String
    public let url: URL?

    public init(courseID: String, code: String, name: String, url: URL?) {
        self.courseID = courseID
        self.code = code
        self.name = name
        self.url = url
    }
}

/// Everything the chatbot can draw on, as one persisted snapshot.
public struct CourseKnowledgeBase: Codable, Sendable, Hashable {
    public var courses: [CourseSummary]
    public var documents: [CourseDocument]
    public var lastSyncedAt: Date?

    public init(courses: [CourseSummary] = [], documents: [CourseDocument] = [], lastSyncedAt: Date? = nil) {
        self.courses = courses
        self.documents = documents
        self.lastSyncedAt = lastSyncedAt
    }

    public static let empty = CourseKnowledgeBase()

    public var isEmpty: Bool { documents.isEmpty }

    public func documents(for courseID: String) -> [CourseDocument] {
        documents.filter { $0.courseID == courseID }
    }

    public func documents(ofKind kind: CourseDocument.Kind) -> [CourseDocument] {
        documents.filter { $0.kind == kind }
    }

    /// Merges freshly fetched documents in. Unchanged documents keep their
    /// original `fetchedAt` so "last changed" stays meaningful; documents that
    /// disappeared from Canvas for a re-synced course are dropped.
    public mutating func merge(
        courses newCourses: [CourseSummary],
        documents newDocuments: [CourseDocument],
        resyncedCourseIDs: Set<String>,
        syncedAt: Date
    ) {
        var byCourse = Dictionary(self.courses.map { ($0.courseID, $0) }, uniquingKeysWith: { _, last in last })
        for course in newCourses { byCourse[course.courseID] = course }
        courses = byCourse.values.sorted { $0.code.localizedCaseInsensitiveCompare($1.code) == .orderedAscending }

        let existing = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var merged: [String: CourseDocument] = existing.filter { !resyncedCourseIDs.contains($0.value.courseID) }
        for doc in newDocuments {
            if let old = existing[doc.id], old.contentHash == doc.contentHash {
                merged[doc.id] = old
            } else {
                merged[doc.id] = doc
            }
        }
        documents = merged.values.sorted { lhs, rhs in
            if lhs.courseID != rhs.courseID { return lhs.courseID < rhs.courseID }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        lastSyncedAt = syncedAt
    }
}

/// Dependency-free content hashing (CryptoKit is Apple-only, and the Kit's
/// pure-Foundation parts are meant to build anywhere).
public enum ContentHash {
    /// 64-bit FNV-1a, hex encoded.
    public static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
