import Foundation
import SwiftData

/// The durable, on-disk record of an assignment the app has ever seen from a
/// feed. This is the ledger row behind `AssignmentStore`: the app is no longer a
/// live view of "whatever the last fetch returned" but a database that fetches
/// *edit*. That's what stops a rolling Canvas feed (or one flaky sync) from
/// making previously-seen assignments — and completed work — disappear.
///
/// Keyed by `id` (`"source:sourceID"`, identical to `Assignment.id`) so a row
/// maps 1:1 to the value-type `Assignment` the rest of the app consumes. The
/// lifecycle fields (`firstSeen` / `lastSeenInFeed` / `isGoneFromFeed`) are the
/// point of the whole thing: an item leaving the feed is *recorded*, never
/// silently dropped.
///
/// **`id` is not a database constraint.** It used to carry
/// `@Attribute(.unique)`, which is unsupported by CloudKit and would make
/// `ModelConfiguration(cloudKitDatabase:)` impossible to enable. Uniqueness now
/// lives in `AssignmentStore` — see `rowsByID()`, which every read and write
/// goes through — and `absorb(_:)` below is what a collision resolves to.
/// Removing the attribute also fixed a quieter bug: SwiftData enforced
/// `.unique` as a last-write-wins *overwrite*, so a collapsed duplicate
/// silently discarded the older row's `firstSeen`, `completedAt` and pairing.
/// The merge here keeps them.
@Model
public final class StoredAssignment {
    /// `"source:sourceID"` — the same stable identity as `Assignment.id`.
    /// Unique by invariant, not by constraint (see the type's note).
    public var id: String

    // MARK: Feed-supplied identity & display (refreshed on every sync)
    public var sourceRaw: String
    public var sourceID: String
    public var kindRaw: String
    public var course: String
    public var title: String
    public var dueAt: Date?
    public var urlString: String?
    /// Persisted as the `YYYYTT` term code (see `Term`); nil when unknown.
    public var termYear: Int?
    public var termSeasonRaw: Int?

    // MARK: Lifecycle — the heart of "don't lose things"
    /// First time this item was ever seen in any feed. Never overwritten.
    public var firstSeen: Date
    /// Refreshed to "now" on every sync the item is present in.
    public var lastSeenInFeed: Date
    /// Set true once a sync no longer returns it. The item is retained (visible
    /// until the deliberate aging rule fires), not deleted — a professor moving
    /// or briefly hiding an item, or a partial fetch, must never lose it.
    public var isGoneFromFeed: Bool

    // MARK: Completion — the ledger IS the record, not a mirror of one
    /// When the user ticked this item off (or its cross-platform counterpart).
    /// Nil means either "not completed" or "completed at an unknown time":
    /// `userCompleted` is the authoritative flag, this is the optional *when*.
    ///
    /// The distinction is not academic. Completions carried over from the
    /// pre-ledger `completedAssignmentIDs` set predate the app tracking
    /// timestamps at all, and the Done tab deliberately places a dateless
    /// completion by its due date while the weekly ring skips it. Folding a
    /// synthetic timestamp in here would silently move those cards and inflate
    /// the ring.
    public var completedAt: Date?

    /// True once the user has ticked this item off. Defaulted (CloudKit) and
    /// deliberately separate from `completedAt` — see above.
    ///
    /// Rows written before this flag existed recorded completion by setting
    /// `completedAt` alone, so read completion through `isCompletedByUser`,
    /// never off either field directly.
    public var userCompleted: Bool = false

    /// True when this row exists *only* to remember a completion — the user
    /// ticked off something no feed reconciles into the ledger (a manual or
    /// recurring task), or a completion was migrated out of the old
    /// UserDefaults set before that item's feed had ever been synced.
    ///
    /// Nothing but the identity is trustworthy on such a row, so it is hidden
    /// from every read of "assignments the app knows about" — the dashboard
    /// seed, the Done pool, the widget, the stats panel. `refresh(from:now:)`
    /// clears the flag the instant a real feed item with that id arrives,
    /// promoting the row in place and keeping the completion that was waiting
    /// on it. That promotion is the whole point: it is what lets a student
    /// upgrading from a pre-ledger build keep work they had already ticked off.
    public var isCompletionOnly: Bool = false

    // MARK: Submission / grade truth (persisted, not recomputed from scratch)
    /// Canvas's own submission signal (from Grade Watcher's `workflow_state`),
    /// stored so it survives launches instead of being blank until a live grade
    /// refresh lands. Keyed for the dashboard join via `canvasAssignmentID`.
    public var canvasSubmitted: Bool
    /// Gradescope's scraped submitted status.
    public var gradescopeSubmitted: Bool

    // MARK: How current the submission signals are
    /// When Canvas last *told us something* about this item — submitted or not.
    ///
    /// Not the same as when it was submitted: it is when the app last had a
    /// trustworthy answer. The flag alone cannot distinguish "not submitted,
    /// confirmed a minute ago" from "not submitted, as far as we knew last
    /// Tuesday before the session expired", and those mean very different
    /// things to someone deciding what to work on tonight.
    ///
    /// Optional and defaulted: rows written before this existed have no
    /// observation date, which reads correctly as "we don't know how fresh
    /// this is" rather than as a fabricated timestamp.
    public var canvasSubmissionObservedAt: Date?

    /// The same, for Gradescope's scraped status. Written whenever a feed item
    /// carries the flag, since that scrape *is* the observation.
    public var gradescopeSubmissionObservedAt: Date?
    public var scoreEarned: Double?
    public var scoreMax: Double?

    // MARK: Cross-platform pairing (persisted so it survives a later date move)
    /// The `Assignment.id` of a confirmed counterpart on the other platform.
    /// Reserved for persisted-pairing dedup; nil until a pairing is confirmed.
    public var linkedID: String?
    public var pairingConfirmedAt: Date?

    public init(
        id: String,
        sourceRaw: String,
        sourceID: String,
        kindRaw: String,
        course: String,
        title: String,
        dueAt: Date?,
        urlString: String?,
        termYear: Int?,
        termSeasonRaw: Int?,
        firstSeen: Date,
        lastSeenInFeed: Date,
        isGoneFromFeed: Bool = false,
        completedAt: Date? = nil,
        userCompleted: Bool = false,
        isCompletionOnly: Bool = false,
        canvasSubmitted: Bool = false,
        gradescopeSubmitted: Bool = false,
        canvasSubmissionObservedAt: Date? = nil,
        gradescopeSubmissionObservedAt: Date? = nil,
        scoreEarned: Double? = nil,
        scoreMax: Double? = nil,
        linkedID: String? = nil,
        pairingConfirmedAt: Date? = nil
    ) {
        self.id = id
        self.sourceRaw = sourceRaw
        self.sourceID = sourceID
        self.kindRaw = kindRaw
        self.course = course
        self.title = title
        self.dueAt = dueAt
        self.urlString = urlString
        self.termYear = termYear
        self.termSeasonRaw = termSeasonRaw
        self.firstSeen = firstSeen
        self.lastSeenInFeed = lastSeenInFeed
        self.isGoneFromFeed = isGoneFromFeed
        self.completedAt = completedAt
        self.userCompleted = userCompleted
        self.isCompletionOnly = isCompletionOnly
        self.canvasSubmitted = canvasSubmitted
        self.gradescopeSubmitted = gradescopeSubmitted
        self.canvasSubmissionObservedAt = canvasSubmissionObservedAt
        self.gradescopeSubmissionObservedAt = gradescopeSubmissionObservedAt
        self.scoreEarned = scoreEarned
        self.scoreMax = scoreMax
        self.linkedID = linkedID
        self.pairingConfirmedAt = pairingConfirmedAt
    }
}

// MARK: - Mapping to/from the value-type Assignment

extension StoredAssignment {
    /// Rebuild the value-type the rest of the app consumes. `submitted` reflects
    /// the row's own source (Gradescope carries a real flag; Canvas's ICS
    /// `submitted` is always false and its truth flows via the separate
    /// `submittedCanvasAssignmentIDs` side-channel, so it isn't folded in here).
    public var assignment: Assignment {
        let source = Assignment.Source(rawValue: sourceRaw) ?? .canvas
        let term: Term? = {
            guard let termYear, let termSeasonRaw,
                  let season = Term.Season(rawValue: termSeasonRaw) else { return nil }
            return Term(year: termYear, season: season)
        }()
        return Assignment(
            source: source,
            sourceID: sourceID,
            kind: Assignment.Kind(rawValue: kindRaw) ?? .other,
            course: course,
            title: title,
            dueAt: dueAt,
            url: urlString.flatMap(URL.init(string:)),
            term: term,
            submitted: source == .gradescope ? gradescopeSubmitted : false,
            scoreEarned: scoreEarned,
            scoreMax: scoreMax,
            linkedID: linkedID
        )
    }

    /// Work the student actually finished — ticked off, or reported turned in by
    /// either platform. The ledger treats this as archive material: it is exempt
    /// from aging, because losing a completed assignment silently rewrites the
    /// student's own record of what they did.
    var isFinished: Bool {
        isCompletedByUser || canvasSubmitted || gradescopeSubmitted
    }

    /// Whether the user has ticked this item off, however the row recorded it.
    /// The `completedAt != nil` half keeps rows written by earlier builds (which
    /// had no `userCompleted` flag) reading as completed, so the flag's arrival
    /// can't quietly un-finish anyone's work even if a migration never runs.
    public var isCompletedByUser: Bool {
        userCompleted || completedAt != nil
    }

    /// Marks the row completed. `date` may be nil for a completion whose
    /// timestamp is genuinely unknown (a pre-timestamp migration); the flag
    /// still records that it happened.
    func markCompleted(at date: Date?) {
        userCompleted = true
        completedAt = date
    }

    /// Clears completion entirely — both the flag and the timestamp, so a row
    /// written by an older build can actually be un-completed.
    func clearCompletion() {
        userCompleted = false
        completedAt = nil
    }

    /// The Canvas assignment id this row joins to Grade Watcher's submission
    /// side-channel on — the same derivation the value type uses, so the two
    /// can't drift apart.
    var canvasAssignmentID: String? { assignment.canvasAssignmentID }

    /// Copies the feed-supplied fields of `assignment` onto this row, preserving
    /// everything the ledger owns (`firstSeen`, submission flags, pairing). Used
    /// on the upsert path when an item is seen again.
    func refresh(from assignment: Assignment, now: Date) {
        sourceRaw = assignment.source.rawValue
        sourceID = assignment.sourceID
        kindRaw = assignment.kind.rawValue
        course = assignment.course
        title = assignment.title
        dueAt = assignment.dueAt
        urlString = assignment.url?.absoluteString
        termYear = assignment.term?.year
        termSeasonRaw = assignment.term?.season.rawValue
        lastSeenInFeed = now
        isGoneFromFeed = false
        // A real feed item just arrived for an id we were only holding a
        // completion against: this is now a full row, and the completion rides
        // along untouched.
        isCompletionOnly = false
        // Gradescope's submitted flag rides along with its feed items; fold it in
        // so a scraped completion is retained.
        if assignment.source == .gradescope {
            gradescopeSubmitted = assignment.submitted
            gradescopeSubmissionObservedAt = now
        }
        if let earned = assignment.scoreEarned { scoreEarned = earned }
        if let max = assignment.scoreMax { scoreMax = max }
    }

    /// Folds a second row carrying this row's `id` back into this one, ahead of
    /// deleting it. Nothing the app does can create that second row — but a
    /// restored backup, an interrupted save, or (the whole reason `.unique` had
    /// to go) a CloudKit merge of two devices that each created the row
    /// independently can, and the database no longer refuses it.
    ///
    /// Every rule below resolves the same way: toward keeping what the student
    /// would notice missing. A collapse is already a surprise; it must not also
    /// be the thing that loses a completion tick or a recorded grade.
    ///
    /// Display fields are deliberately untouched — the caller absorbs *into*
    /// whichever copy was seen in the feed most recently, so those are already
    /// the freshest ones available.
    func absorb(_ other: StoredAssignment) {
        // The archive reaches back as far as the earlier sighting, and aging is
        // measured from the later one. Both directions favor retention.
        firstSeen = min(firstSeen, other.firstSeen)
        lastSeenInFeed = max(lastSeenInFeed, other.lastSeenInFeed)
        // Still in the feed on either copy means still in the feed: a retained
        // item can always age out later, an aged-out one is simply gone.
        isGoneFromFeed = isGoneFromFeed && other.isGoneFromFeed
        // Any evidence of finished work counts, dated from the earlier tick —
        // that's when the student actually finished it.
        completedAt = [completedAt, other.completedAt].compactMap { $0 }.min()
        canvasSubmitted = canvasSubmitted || other.canvasSubmitted
        gradescopeSubmitted = gradescopeSubmitted || other.gradescopeSubmitted
        // A known score beats no score. Earned and max move together so a
        // half-merged fraction can't be displayed.
        if scoreEarned == nil, let earned = other.scoreEarned {
            scoreEarned = earned
            scoreMax = other.scoreMax ?? scoreMax
        } else if scoreMax == nil {
            scoreMax = other.scoreMax
        }
        // Same for a confirmed cross-platform pairing: keep the one that exists.
        if linkedID == nil, let linked = other.linkedID {
            linkedID = linked
            pairingConfirmedAt = other.pairingConfirmedAt
        }
    }

    /// A fresh ledger row for a never-before-seen assignment.
    static func make(from assignment: Assignment, now: Date) -> StoredAssignment {
        StoredAssignment(
            id: assignment.id,
            sourceRaw: assignment.source.rawValue,
            sourceID: assignment.sourceID,
            kindRaw: assignment.kind.rawValue,
            course: assignment.course,
            title: assignment.title,
            dueAt: assignment.dueAt,
            urlString: assignment.url?.absoluteString,
            termYear: assignment.term?.year,
            termSeasonRaw: assignment.term?.season.rawValue,
            firstSeen: now,
            lastSeenInFeed: now,
            gradescopeSubmitted: assignment.source == .gradescope ? assignment.submitted : false,
            // A first sighting is as much an observation as a re-sighting;
            // `refresh(from:now:)` records the same thing on later passes.
            gradescopeSubmissionObservedAt: assignment.source == .gradescope ? now : nil,
            scoreEarned: assignment.scoreEarned,
            scoreMax: assignment.scoreMax,
            linkedID: assignment.linkedID
        )
    }
}

// MARK: - Rows that exist only to carry a completion

extension StoredAssignment {
    /// Splits an `Assignment.id` back into its `(source, sourceID)` halves.
    /// Only the *first* colon separates them — Canvas UIDs contain colons of
    /// their own, so a naive split would mangle them.
    static func decompose(id: String) -> (source: Assignment.Source, sourceID: String)? {
        guard let separator = id.firstIndex(of: ":") else { return nil }
        let rawSource = String(id[id.startIndex..<separator])
        let sourceID = String(id[id.index(after: separator)...])
        guard let source = Assignment.Source(rawValue: rawSource), !sourceID.isEmpty else { return nil }
        return (source, sourceID)
    }

    /// A row whose only job is to remember that `id` was completed.
    ///
    /// Used on two paths that both used to lose data: ticking off a manual or
    /// recurring task (nothing ever reconciles those into the ledger, so there
    /// is no row to write completion onto), and migrating a completion for an
    /// assignment whose feed hasn't been synced into the ledger yet. When a
    /// `prototype` is available its display fields are kept — they cost nothing
    /// and make the row legible in diagnostics — but the row stays hidden until
    /// a feed promotes it either way.
    ///
    /// Returns nil for an id that can't be decomposed, so a corrupt or
    /// hand-edited defaults blob can't seed junk rows.
    static func completionOnly(
        id: String,
        prototype: Assignment? = nil,
        completedAt: Date?,
        now: Date
    ) -> StoredAssignment? {
        guard let parts = decompose(id: id) else { return nil }
        return StoredAssignment(
            id: id,
            sourceRaw: parts.source.rawValue,
            sourceID: parts.sourceID,
            kindRaw: (prototype?.kind ?? .assignment).rawValue,
            course: prototype?.course ?? "",
            title: prototype?.title ?? "",
            dueAt: prototype?.dueAt,
            urlString: prototype?.url?.absoluteString,
            termYear: prototype?.term?.year,
            termSeasonRaw: prototype?.term?.season.rawValue,
            firstSeen: now,
            lastSeenInFeed: now,
            completedAt: completedAt,
            userCompleted: true,
            isCompletionOnly: true
        )
    }
}

// MARK: - Submission freshness

public extension StoredAssignment {
    /// The most recent moment any platform told us about this item's submission
    /// state, or nil if none ever has.
    ///
    /// Deliberately the newest of the two rather than per-source: the question
    /// a caller is asking is "how much should I trust what I'm about to show",
    /// and the freshest signal is the honest answer to that.
    var submissionObservedAt: Date? {
        switch (canvasSubmissionObservedAt, gradescopeSubmissionObservedAt) {
        case let (canvas?, gradescope?): return max(canvas, gradescope)
        case let (canvas?, nil): return canvas
        case let (nil, gradescope?): return gradescope
        case (nil, nil): return nil
        }
    }

    /// Whether the submission state was confirmed within `window` of `now`.
    ///
    /// A row that has never been observed is *not* stale — it is unknown, which
    /// is a different thing and must not be shown as "last checked ages ago".
    /// Callers distinguish the two by checking `submissionObservedAt` for nil.
    func hasFreshSubmissionState(now: Date = Date(), within window: TimeInterval) -> Bool {
        guard let observed = submissionObservedAt else { return false }
        return now.timeIntervalSince(observed) <= window
    }
}
