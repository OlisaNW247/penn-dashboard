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
        /// Imported from a course's Modules pages via Canvas's JSON API
        /// (`CanvasModulesClient`, docs/READINGS_COURSES_PLAN.md) rather than
        /// the ICS calendar feed. Kept distinct from `.canvas` so
        /// `AssignmentStore.reconcile(_:source:)` — which partitions existing
        /// rows by source before flagging anything missing from a fresh fetch
        /// as gone — never marks a module-imported reading gone during an ICS
        /// sync, or an ICS-synced assignment gone during a modules sync.
        case canvasModules
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
    /// The `id` of this item's matched counterpart on the OTHER platform, when
    /// `AssignmentDeduplicator` has determined the professor posted the same
    /// assignment on both Canvas and Gradescope (e.g. a Canvas item whose
    /// `linkedID` is `"gradescope:…"`). Nil for everything else — most items
    /// never have a cross-platform twin. Set only by `AssignmentDeduplicator
    /// .merge`, never by the raw source clients. Lets completion (see
    /// `AppState.markCompleted`) propagate to both identities so the pair
    /// stays consistent if a later sync no longer matches them.
    public let linkedID: String?

    public var isAssignment: Bool {
        kind == .assignment
    }

    /// The numeric Canvas assignment id, when this is a Canvas assignment whose
    /// identity can be recovered — the join key to `AssignmentSubmissionInfo`
    /// (which Canvas keys by that id). Canvas's ICS feed embeds it in both the
    /// event URL (`/assignments/12345`) and the UID (`event-assignment-12345@…`);
    /// we prefer the URL and fall back to the UID. Nil for non-Canvas items and
    /// for quizzes/discussions/events (their URLs use a different id space), so
    /// auto-detection is scoped to true assignments and never mis-joins.
    public var canvasAssignmentID: String? {
        guard source == .canvas else { return nil }
        if let url, let id = Self.firstMatch(#"/assignments/(\d+)"#, in: url.absoluteString) {
            return id
        }
        return Self.firstMatch(#"assignment-(\d+)"#, in: sourceID)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
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
        scoreMax: Double? = nil,
        linkedID: String? = nil
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
        self.linkedID = linkedID
    }
}
