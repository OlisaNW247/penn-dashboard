import Foundation

/// One Canvas announcement, normalized to the plain-text shape both
/// extraction backends need. `Canvas/` is responsible for turning whatever
/// Canvas's announcements API returns into this — HTML stripping, course-code
/// resolution and everything else specific to *fetching* an announcement
/// happens upstream of this type, deliberately, so the extraction layer (this
/// file and its two implementations) never has to know Canvas exists at all
/// and can be exercised with hand-written fixtures.
public struct AnnouncementSourceText: Sendable, Equatable {
    /// The Canvas announcement's own id, kept as a string (not `Int`) for the
    /// same reason `Assignment.sourceID` is a string: Canvas ids are large
    /// enough to be a JSON-number-precision trap, and nothing here does
    /// arithmetic on them — they're only ever compared and stored.
    public let announcementID: String
    /// Clean display course code, e.g. "ACCT 1010" — the same `CourseCode`
    /// key `Assignment.course` uses, so an extracted assignment can be
    /// attached to the right course without a second lookup.
    public let courseCode: String
    public let title: String
    /// Plain text. HTML stripping is the fetch layer's job, not this one's —
    /// an extractor that had to also be an HTML parser would be harder to
    /// unit test and harder to reason about when it inevitably gets an
    /// extraction wrong.
    public let body: String
    /// When Canvas says the announcement was posted. Optional because not
    /// every path that can produce an `AnnouncementSourceText` (tests,
    /// hand-entered fixtures) necessarily has it, and the Claude backend only
    /// uses it as context, not as a hard requirement.
    public let postedAt: Date?

    public init(
        announcementID: String,
        courseCode: String,
        title: String,
        body: String,
        postedAt: Date?
    ) {
        self.announcementID = announcementID
        self.courseCode = courseCode
        self.title = title
        self.body = body
        self.postedAt = postedAt
    }
}

/// A candidate assignment an extractor believes an announcement describes.
///
/// Deliberately *not* `Assignment` — this is a proposal, not a ledger row.
/// Whatever calls an extractor (not built here; that's the sync-layer's job)
/// decides how a run of `ExtractedAssignment`s becomes `Assignment.Source
/// .canvasSuggestion` rows, whether they need user confirmation, and how they
/// dedupe against assignments the ICS feed or Modules API already produced.
/// Keeping this struct minimal keeps that decision out of the extraction
/// layer, where it doesn't belong.
public struct ExtractedAssignment: Sendable, Equatable {
    public let title: String
    /// Nil when no extractor could pin down a date. Undated items are legal
    /// throughout LHF (see `AssignmentStore.reconcile` in CLAUDE.md) — an
    /// extractor that refused to emit anything without a date would silently
    /// drop real, useful "there's a reading, no clue when it's due" signal.
    public let dueAt: Date?

    public init(title: String, dueAt: Date?) {
        self.title = title
        self.dueAt = dueAt
    }
}

/// The contract both extraction backends satisfy: given one announcement and
/// the caller's notion of "now" (never `Date()` read internally — see
/// `HeuristicAnnouncementExtractor`'s doc comment for why that matters for
/// weekday/relative-date math and for tests), produce zero or more candidate
/// assignments.
///
/// `async throws` even though the heuristic backend never actually suspends
/// or throws: the Claude backend does both (network I/O, HTTP/decoding
/// errors), and a caller that wants to swap backends behind a single call
/// site — which is the entire point of this being a protocol — needs one
/// signature that already accounts for the more demanding implementation.
/// `Sendable` because both backends are meant to be constructed once and
/// reused from whatever actor drives the announcement sync.
public protocol AnnouncementAssignmentExtractor: Sendable {
    func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment]
}
