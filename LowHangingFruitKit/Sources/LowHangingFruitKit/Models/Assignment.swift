import Foundation

/// The unified shape a dashboard item takes once normalized from any source
/// (Canvas calendar feed, Canvas syllabus/announcement scan, user-created).
/// Source-agnostic by design.
public struct Assignment: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Codable, Hashable {
        case canvas
        case gradescope
        case manual
        case canvasSuggestion
    }

    /// What kind of thing this calendar entry represents. Canvas's ICS feed
    /// mixes graded assignments with lectures, office hours, etc. — `kind`
    /// lets the UI filter them apart.
    public enum Kind: String, Sendable, Codable, Hashable {
        case assignment
        case quiz
        case discussion
        case event       // lectures, office hours, exam dates without submission
        case other
    }

    /// Stable identity across sources: (source, sourceID).
    public var id: String { "\(source.rawValue):\(sourceID)" }

    public let source: Source
    public let sourceID: String
    public let kind: Kind
    /// Clean display course code, e.g. "FNAR 3230" (see `CourseCode`). Doubles as
    /// the grouping key for the class picker.
    public let course: String
    public let title: String
    public let dueAt: Date?
    public let url: URL?
    /// The academic term this item belongs to, when it could be parsed from the
    /// Canvas course descriptor. Used to scope the dashboard to the current term.
    public let term: Term?
    public let submitted: Bool
    /// The graded score Gradescope already shows (e.g. the "87.5" in
    /// "87.5 / 100"), when the assignment's status string carries one. Nil
    /// when ungraded or the source isn't Gradescope. Feeds the Grade Watcher
    /// early-score overlay (docs/grades.md §4) — never used to imply
    /// "submitted" on its own; see `GradescopeHTMLParser.isCompletedStatus`.
    public let scoreEarned: Double?
    /// The denominator alongside `scoreEarned` (the "100" in "87.5 / 100").
    /// Always nil exactly when `scoreEarned` is nil.
    public let scoreMax: Double?

    public var isAssignment: Bool {
        kind == .assignment
    }

    public init(
        source: Source,
        sourceID: String,
        kind: Kind,
        course: String,
        title: String,
        dueAt: Date?,
        url: URL?,
        term: Term? = nil,
        submitted: Bool = false,
        scoreEarned: Double? = nil,
        scoreMax: Double? = nil
    ) {
        self.source = source
        self.sourceID = sourceID
        self.kind = kind
        self.course = course
        self.title = title
        self.dueAt = dueAt
        self.url = url
        self.term = term
        self.submitted = submitted
        self.scoreEarned = scoreEarned
        self.scoreMax = scoreMax
    }
}
