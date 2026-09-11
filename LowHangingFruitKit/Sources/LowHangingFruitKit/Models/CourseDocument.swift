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
    /// The registrar section token (`CourseCode.Parsed.section`) off this
    /// site's own Canvas descriptor, kept so more than one Canvas site can
    /// share one `code` — Penn's PHYS 0151 lecture and lab are two separate
    /// sites, "PHYS 0151-151 …" and "PHYS 0151-401 …", that both parse to
    /// the code "PHYS 0151" — and something downstream can still tell which
    /// site is which (`DocumentComponent.component(of:in:)`). `nil` for any
    /// course summary written before this field existed, or whose
    /// descriptor never carried a dash-section; every call site that reads
    /// it must treat that as "unknown," not "not split." Declared last with
    /// a default so every existing `CourseSummary(...)` call in this Kit,
    /// the UI module, and every fixture in both test targets keeps
    /// compiling unchanged.
    public let section: String?

    public init(courseID: String, code: String, name: String, url: URL?, section: String? = nil) {
        self.courseID = courseID
        self.code = code
        self.name = name
        self.url = url
        self.section = section
    }

    /// Synthesized `Codable` would in fact `decodeIfPresent` an optional
    /// stored property automatically and treat a missing `section` key as
    /// `nil` — verified against the Swift Evolution `Codable` synthesis
    /// rules (SE-0166): a property of `Optional` type gets a
    /// `decodeIfPresent`, not a `decode`, in the compiler-generated
    /// `init(from:)`. So a `CourseKnowledgeStore` file written before this
    /// field existed decodes cleanly with `section == nil`, same as
    /// `CourseKnowledgeBase.catalog`'s hand-written `init(from:)` achieves
    /// deliberately elsewhere in this file. No custom `init(from:)` is
    /// needed here; this comment exists so a future reader doesn't wonder
    /// why `CourseSummary` skipped the treatment `CourseKnowledgeBase` got.
}

/// Everything the chatbot can draw on, as one persisted snapshot.
public struct CourseKnowledgeBase: Codable, Sendable, Hashable {
    public var courses: [CourseSummary]
    public var documents: [CourseDocument]
    public var lastSyncedAt: Date?
    /// The registrar-derived course catalog (`CourseCatalogEntry`, one per
    /// course), synced down alongside `documents` so
    /// `HeuristicAnnouncementExtractor` can resolve "before class" phrasing
    /// to an actual clock time. Decoded with `decodeIfPresent` in this
    /// type's custom `init(from:)` below rather than through ordinary
    /// `Codable` synthesis, because — unlike `documents`/`courses`, which
    /// have always been present in every `CourseKnowledgeStore` file this
    /// app has ever written — `catalog` is new. Every knowledge-base JSON
    /// already sitting on a student's disk predates it, and a struct
    /// decoded through synthesis would fail outright on a key that simply
    /// never existed until now. A failed decode here doesn't surface as "no
    /// catalog data" — `CourseKnowledgeStore.load()` treats a decode failure
    /// as "nothing synced yet" and falls back to `.empty`, silently
    /// discarding every document and course the student already had. This
    /// custom `init(from:)` is what stands between adding this field and
    /// that data loss.
    public var catalog: [CourseCatalogEntry]
    /// The server's syllabus-derived grading extraction, one per course,
    /// synced down alongside `catalog` so Grade Watcher can offer a
    /// suggested scheme without the device re-parsing a syllabus it already
    /// holds. Decoded with `decodeIfPresent` in this type's custom
    /// `init(from:)`, for exactly the reason `catalog`'s doc comment gives:
    /// this field is newer than `documents`/`courses`, so every
    /// knowledge-base file already on a student's disk predates it, and a
    /// key that's simply never existed until now must not fail the decode
    /// and fall back to `.empty` — that would silently discard every
    /// document and course the student already had, not just the new field.
    public var gradingProfiles: [CourseGradingProfile]

    public init(
        courses: [CourseSummary] = [],
        documents: [CourseDocument] = [],
        lastSyncedAt: Date? = nil,
        catalog: [CourseCatalogEntry] = [],
        gradingProfiles: [CourseGradingProfile] = []
    ) {
        self.courses = courses
        self.documents = documents
        self.lastSyncedAt = lastSyncedAt
        self.catalog = catalog
        self.gradingProfiles = gradingProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case courses, documents, lastSyncedAt, catalog, gradingProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courses = try container.decode([CourseSummary].self, forKey: .courses)
        documents = try container.decode([CourseDocument].self, forKey: .documents)
        lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        catalog = try container.decodeIfPresent([CourseCatalogEntry].self, forKey: .catalog) ?? []
        gradingProfiles = try container.decodeIfPresent([CourseGradingProfile].self, forKey: .gradingProfiles) ?? []
    }

    public static let empty = CourseKnowledgeBase()

    public var isEmpty: Bool { documents.isEmpty }

    public func documents(for courseID: String) -> [CourseDocument] {
        documents.filter { $0.courseID == courseID }
    }

    public func documents(ofKind kind: CourseDocument.Kind) -> [CourseDocument] {
        documents.filter { $0.kind == kind }
    }

    /// Every Canvas `courseID` whose `CourseSummary.code` names the same
    /// course as `code` — the fix for PHYS 0151's lecture and lab (and any
    /// other course split the same way) collapsing to one display code but
    /// remaining two separate Canvas sites with two separate document sets.
    /// Everything that used to resolve "the one `courseID` for this code"
    /// (materials sync, retrieval scoping) needs every site now, not
    /// whichever one happened to win a dictionary upsert first. Matched
    /// with `CourseMatcher.sameCourse` rather than a direct string compare
    /// so this agrees with every other place in the Kit that decides two
    /// course strings name the same class.
    public func courseIDs(forCode code: String) -> Set<String> {
        Set(courses.filter { CourseMatcher.sameCourse(code, as: $0) }.map(\.courseID))
    }

    /// The `CourseSummary` for one Canvas site, or `nil` if this knowledge
    /// base has never synced that `courseID`.
    public func summary(forCourseID courseID: String) -> CourseSummary? {
        courses.first { $0.courseID == courseID }
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

    /// Upserts catalog entries by `courseID`. Never removes an entry this
    /// call wasn't told about, unlike `merge(courses:documents:...)`'s
    /// `resyncedCourseIDs` path: a catalog fetch scoped to "the course the
    /// student is looking at right now" is normal, and a partial fetch like
    /// that must never be read as "every other course's catalog entry is
    /// now stale and should go" — the same "add or update, never wholesale
    /// replace" rule the file header on `AssignmentStore.reconcile`
    /// describes for the ledger.
    public mutating func mergeCatalog(_ entries: [CourseCatalogEntry]) {
        guard !entries.isEmpty else { return }
        var byCourseID = Dictionary(catalog.map { ($0.courseID, $0) }, uniquingKeysWith: { _, last in last })
        for entry in entries { byCourseID[entry.courseID] = entry }
        catalog = byCourseID.values.sorted { $0.courseID < $1.courseID }
    }

    /// Looks up a catalog entry by the display course code
    /// (`CourseCode.parse`'s output, e.g. "PHYS 151"). Tries `courses` first
    /// — the code → Canvas `courseID` mapping the sync already resolved,
    /// which is exact — and only falls back to matching `catalogCode`
    /// directly, with spaces and dashes stripped on both sides, since the
    /// registrar's own code spelling ("PHYS-151") doesn't necessarily agree
    /// with Canvas's ("PHYS 151") and a caller with no `courses` entry yet
    /// (a course discovered this launch, before its first course-summary
    /// sync) shouldn't lose catalog data it could otherwise find.
    public func catalogEntry(forCourseCode code: String) -> CourseCatalogEntry? {
        if let courseID = courses.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame })?.courseID,
           let entry = catalog.first(where: { $0.courseID == courseID }) {
            return entry
        }
        let normalizedTarget = Self.normalizedCourseCode(code)
        return catalog.first { Self.normalizedCourseCode($0.catalogCode) == normalizedTarget }
    }

    private static func normalizedCourseCode(_ code: String) -> String {
        code.lowercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Upserts grading profiles by `courseID`, mirroring `mergeCatalog`'s
    /// "add or update, never wholesale replace" rule — a profile sync
    /// scoped to one course (or a handful) must never be read as "every
    /// other course's suggested scheme is now gone."
    public mutating func mergeGradingProfiles(_ profiles: [CourseGradingProfile]) {
        guard !profiles.isEmpty else { return }
        var byCourseID = Dictionary(gradingProfiles.map { ($0.courseID, $0) }, uniquingKeysWith: { _, last in last })
        for profile in profiles { byCourseID[profile.courseID] = profile }
        gradingProfiles = byCourseID.values.sorted { $0.courseID < $1.courseID }
    }

    /// The server's suggested grading scheme for one course, if it's synced
    /// one yet.
    public func gradingProfile(forCourseID courseID: String) -> CourseGradingProfile? {
        gradingProfiles.first { $0.courseID == courseID }
    }

    /// The text of this course's synced syllabus document, if it has one —
    /// used so `SyllabusGradingScheme.from(profile:)`'s caller and
    /// `GradeSiteExclusion` can work from the syllabus text the app already
    /// holds rather than refetching it.
    public func syllabusText(forCourseID courseID: String) -> String? {
        documents.first { $0.courseID == courseID && $0.kind == .syllabus }?.text
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
