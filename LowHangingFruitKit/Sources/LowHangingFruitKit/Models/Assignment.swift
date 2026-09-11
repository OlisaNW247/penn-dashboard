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
        /// Extracted from a Canvas course announcement's text
        /// (`CanvasAnnouncementsClient` + `AnnouncementAssignmentExtractor`,
        /// the heuristic or Claude backend) rather than any structured Canvas
        /// feed. Kept distinct from `.canvas`/`.canvasModules` for the same
        /// partitioning reason those two are distinct from each other: an
        /// announcement-derived row must never be marked gone by an ICS or
        /// Modules reconcile that never touched it, and a stale announcement
        /// extraction must never be marked gone by a fresh one for a
        /// different announcement. It's also its own case because
        /// provenance and dedup policy differ from every other source — a
        /// student needs to be able to see "this came from an announcement"
        /// (it's a guess an extractor made, not something Canvas itself
        /// structured) and delete it if the extraction was wrong, and
        /// `AppState.filteringAnnouncementDuplicates` dedupes these against
        /// real Canvas/Gradescope items before they ever reach the ledger,
        /// which is a different policy from how `.canvas` and `.gradescope`
        /// dedupe against each other (`AssignmentDeduplicator`).
        case canvasAnnouncement
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
    /// (which Canvas keys by that id).
    ///
    /// Ground truth is Canvas's own ICS generator (`app/models/calendar_event.rb`,
    /// `to_ics`). The NORMAL case emits `UID: event-assignment-<id>@…` and
    /// `URL: https://<host>/calendar?include_contexts=course_<courseID>&month=…
    /// &year=…#assignment_<id>` — the id lives in the URL's `#assignment_<id>`
    /// FRAGMENT, not its path; there is no `/assignments/<id>` path on the
    /// calendar-context URL at all. `#assignment_<id>` is still enough, and we
    /// also accept a genuine `/assignments/<id>` path (e.g. from
    /// `CanvasModulesClient`, which links straight at the assignment) as a
    /// stronger, unambiguous signal, tried first.
    ///
    /// The case this exists for is the OVERRIDE branch: when a section due-date
    /// override applies to the student, Canvas's generator instead emits
    /// `UID: event-assignment-override-<overrideID>@…` and
    /// `SUMMARY: "<title> (<section title>) [<course code>]"`, and — per that
    /// method's own `# TODO: event.url` comment — never sets `URL` for the
    /// override branch differently from the normal one, so the fragment still
    /// carries `#assignment_<id>`. On an override row the fragment is the ONLY
    /// carrier of the real assignment id: the UID's `<overrideID>` is a
    /// section-override id, a completely different id space Canvas hands out
    /// per override rather than per assignment, and several override rows (one
    /// per section) share one `#assignment_<id>` fragment but each have a
    /// distinct, unrelated override id. The wrong fix — the one that looks
    /// plausible from just reading a sample UID — is parsing the trailing
    /// number out of `event-assignment-override-<overrideID>` as if it were
    /// the assignment id; it silently joins the row to a different assignment's
    /// submission data (or to no assignment at all), which is worse than not
    /// joining. So the UID is only ever used for the *non-override* `assignment-
    /// <id>` shape below, and matching requires the exact `assignment-` prefix
    /// (not `assignment-override-`), which already excludes it structurally.
    ///
    /// Because it's an ICS URL fragment, not a path segment, `#assignment_5`
    /// must be matched with a literal `#` anchor immediately before
    /// `assignment_` — `#sub_assignment_5` (a sub-assignment / checkpoint) and
    /// `#quiz_5` must NOT match, since both use different id spaces than a
    /// plain assignment.
    ///
    /// Nil for non-Canvas items and for quizzes/discussions/events (their URLs
    /// use a different id space), so auto-detection is scoped to true
    /// assignments and never mis-joins.
    ///
    /// `.canvasModules` rows are included too — a module-imported Assignment
    /// item is the same Canvas assignment as the one the ICS feed would have
    /// described, just reached through the Modules JSON API instead
    /// (`CanvasModulesClient`), and it deserves the same join to Grade
    /// Watcher's submission side-channel so it can read as submitted. But only
    /// the URL (path OR fragment) is trusted for that source, never the
    /// sourceID fallback: a modules row's sourceID is `module-item-<id>`,
    /// where `<id>` is Canvas's *module item* id — a wrapper object one layer
    /// removed from the assignment itself, drawn from a completely different
    /// id space. Running the `assignment-(\d+)` sourceID pattern against it
    /// (or against any numeric suffix it happens to contain) would
    /// coincidentally "match" a digit that names the wrong assignment, and a
    /// mis-join here is not a cosmetic bug — it silently reports someone
    /// else's submission status as this student's own.
    public var canvasAssignmentID: String? {
        guard source == .canvas || source == .canvasModules else { return nil }
        if let url {
            if let id = Self.firstMatch(#"/assignments/(\d+)"#, in: url.absoluteString) {
                return id
            }
            if let id = Self.firstMatch(#"#assignment_(\d+)"#, in: url.absoluteString) {
                return id
            }
        }
        guard source == .canvas else { return nil }
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
