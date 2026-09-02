import Foundation
import SwiftData

// MARK: - CloudKit-compliance defaults
//
// CloudKit-mirrored SwiftData rejects a schema where any non-optional stored
// property lacks a default value — its private-database mirroring can write a
// record field-by-field, so every attribute must be constructible on its own
// rather than only through this type's designated init. Every non-optional
// property below therefore now carries a neutral default (`""`, `false`, or
// the epoch for the two lifecycle dates); optional properties (`dueAt`,
// `urlString`, `termYear`, `termSeasonRaw`, `completedAt`, `scoreEarned`,
// `scoreMax`, `linkedID`, `pairingConfirmedAt`) already satisfy the
// requirement with their implicit `nil` and are unchanged.
//
// These defaults are never actually reached on a real row: the designated
// `init(...)` below still assigns every property explicitly, so any row this
// app itself creates is fully populated on write, same as before. They exist
// solely so the CloudKit schema validation at container-open time accepts the
// model, and so that a record arriving from another device mid-sync (one
// field at a time) always has *something* typed in every column rather than
// leaving SwiftData with no value to put there. A row that is momentarily
// all-defaults reads exactly like the hidden `isCompletionOnly` bookkeeping
// rows this type already produces (see `completionOnly(...)` below) — nothing
// downstream trusts a row's display fields without also checking it isn't one
// of those, so a half-synced record cannot leak into a list before its real
// fields arrive.
//
// `Date(timeIntervalSince1970: 0)` (not `Date()`) is deliberate: it makes the
// default itself deterministic, which matters because it becomes part of the
// static schema SwiftData validates and hashes — not because any real row is
// ever expected to carry it.

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
///
/// **This schema is not CloudKit-eligible yet, despite the note above and the
/// one on `userCompleted`.** Removing `.unique` cleared one of two blockers,
/// and every property added since has been optional-or-defaulted — but eleven
/// properties predating that decision are still non-optional with no default:
/// `id`, `sourceRaw`, `sourceID`, `kindRaw`, `course`, `title`, `firstSeen`,
/// `lastSeenInFeed`, `isGoneFromFeed`, `canvasSubmitted`, `gradescopeSubmitted`.
/// CloudKit requires a default on every property, because it has to be able to
/// materialize a record a peer wrote without the field. Each needs one before
/// `ModelConfiguration(cloudKitDatabase:)` can be set.
///
/// Recorded here rather than only in `docs/database-explained.md` §5 because
/// this file is where someone stands when they decide to turn sync on, and the
/// failure without it is a launch-time crash rather than a compile error.
/// `StoredGradeObservation` is already clean.
@Model
public final class StoredAssignment {
    /// `"source:sourceID"` — the same stable identity as `Assignment.id`.
    /// Unique by invariant, not by constraint (see the type's note).
    public var id: String = ""

    // MARK: Feed-supplied identity & display (refreshed on every sync)
    public var sourceRaw: String = ""
    public var sourceID: String = ""
    public var kindRaw: String = ""
    public var course: String = ""
    public var title: String = ""
    public var dueAt: Date?
    public var urlString: String?
    /// Persisted as the `YYYYTT` term code (see `Term`); nil when unknown.
    public var termYear: Int?
    public var termSeasonRaw: Int?

    // MARK: Lifecycle — the heart of "don't lose things"
    /// First time this item was ever seen in any feed. Never overwritten.
    public var firstSeen: Date = Date(timeIntervalSince1970: 0)
    /// Refreshed to "now" on every sync the item is present in.
    public var lastSeenInFeed: Date = Date(timeIntervalSince1970: 0)
    /// Set true once a sync no longer returns it. The item is retained (visible
    /// until the deliberate aging rule fires), not deleted — a professor moving
    /// or briefly hiding an item, or a partial fetch, must never lose it.
    public var isGoneFromFeed: Bool = false

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
    public var canvasSubmitted: Bool = false
    /// Gradescope's scraped submitted status.
    public var gradescopeSubmitted: Bool = false

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

    // MARK: Semester archival — the deliberate way work leaves the dashboard
    /// The term a semester rollover filed this row under, or nil while it is
    /// still live. Written only when the student confirms the rollover card.
    ///
    /// **Why this is on the row and not only on the course.**
    /// `CoursePreferences.archivedTerm` records that a *class* is off the
    /// roster, which is the right shape for the class list — but it cannot
    /// decide this question, for two independent reasons.
    ///
    /// The first is that `courseKey` carries no term. `CourseCode.parse` pulls
    /// `202610` out into its own field and the code it returns is bare
    /// ("CIS 1200"), so a course-level flag cannot tell last spring's CIS 1200
    /// from the CIS 1200 the student is retaking this fall; archiving one would
    /// hide the other.
    ///
    /// The second is the bug this whole feature exists to fix. The value type
    /// `Assignment` carries `term` and `dueAt` and nothing else that dates it,
    /// and `AppState.withinTermCap` lets an item through when both are absent —
    /// that clause is precisely what keeps showing a student last semester's
    /// work. No predicate over an `Assignment` can do better, because the
    /// evidence isn't there. The *row* has `firstSeen`: the moment the app first
    /// laid eyes on the item, which is the only surviving record of when an
    /// undated, termless item entered this student's life. `effectiveTerm`
    /// spends it, and this field records the answer so the guess is made once,
    /// under the student's eye, rather than re-derived on every dashboard
    /// rebuild from data that cannot support it.
    ///
    /// Two optional `Int`s rather than a `Term`, matching `termYear` /
    /// `termSeasonRaw` directly above: SwiftData stores what it can describe,
    /// and both halves are optional so this is a lightweight migration on a
    /// store that already exists and stays CloudKit-eligible
    /// (`docs/persistence-explained.md` §4 step 1).
    public var archivedTermYear: Int?
    public var archivedTermSeasonRaw: Int?

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
        archivedTermYear: Int? = nil,
        archivedTermSeasonRaw: Int? = nil,
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
        self.archivedTermYear = archivedTermYear
        self.archivedTermSeasonRaw = archivedTermSeasonRaw
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

    /// The term the feed told us about, rebuilt from the two stored halves.
    var term: Term? {
        guard let termYear, let termSeasonRaw,
              let season = Term.Season(rawValue: termSeasonRaw) else { return nil }
        return Term(year: termYear, season: season)
    }

    /// The term a rollover filed this row under, or nil while it is live.
    public var archivedTerm: Term? {
        guard let archivedTermYear, let archivedTermSeasonRaw,
              let season = Term.Season(rawValue: archivedTermSeasonRaw) else { return nil }
        return Term(year: archivedTermYear, season: season)
    }

    /// Whether a rollover has put this row away.
    public var isArchived: Bool { archivedTerm != nil }

    /// Which semester this row *belongs to*, on the best evidence the row has.
    ///
    /// The precedence is the whole feature, so it is worth stating why it runs
    /// in this order rather than any other:
    ///
    /// 1. **The term Canvas stamped on the course code.** Exact, and immune to
    ///    the fuzzy month→season boundary `Term(date:)` has to guess at. When
    ///    it's there, nothing else gets a vote.
    /// 2. **The due date.** Nearly as good: an assignment due in March is
    ///    Spring work whatever else is true about it.
    /// 3. **`firstSeen` — when the app first saw the item.** This is the clause
    ///    that fixes the reported bug. An undated, termless row is exactly what
    ///    slips through `AppState.withinTermCap`'s "undated items always pass",
    ///    and it is the reason last spring's reminders are still firing. The
    ///    ledger cannot say when such an item was *due*, but it has always known
    ///    when it first turned up, and an item the app met in February is
    ///    Spring work.
    ///
    /// Clause 3 is a judgement, not a fact, which is exactly why nothing acts on
    /// it unprompted: it feeds a count the student is shown and confirms.
    func effectiveTerm(calendar: Calendar = .current) -> Term? {
        if let term { return term }
        if let dueAt { return Term(date: dueAt, calendar: calendar) }
        return Term(date: firstSeen, calendar: calendar)
    }

    /// The row reduced to what the rollover detector needs.
    func rolloverItem(calendar: Calendar = .current) -> SemesterRollover.Item {
        SemesterRollover.Item(
            id: id,
            course: course,
            term: effectiveTerm(calendar: calendar),
            isArchived: isArchived
        )
    }

    /// Files this row under `term`, or brings it back when `term` is nil.
    func setArchivedTerm(_ term: Term?) {
        archivedTermYear = term?.year
        archivedTermSeasonRaw = term?.season.rawValue
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
        // `archivedTermYear` / `archivedTermSeasonRaw` are deliberately absent
        // from this method, and that absence is load-bearing. Archival is
        // ledger-owned, not feed-owned (`docs/persistence-explained.md` §4 step
        // 1 draws exactly this line). Canvas keeps publishing a concluded
        // course's calendar for weeks after a term ends, so refreshing the flag
        // from the feed would un-archive last semester on the very next sync and
        // silently undo a decision the student was asked to make. Coming back
        // from the archive is an explicit act — `AssignmentStore.unarchive`.
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
        // Live beats archived, which is the same direction `isGoneFromFeed`
        // resolves just above and for the same reason. The two mistakes are not
        // symmetric: a row wrongly left live is clutter on the dashboard, a row
        // wrongly archived is work that has *disappeared* from it — and this
        // method's whole rule is to resolve toward whatever the student would
        // notice missing. They can always archive again; they cannot notice
        // something that isn't shown.
        if other.archivedTerm == nil { setArchivedTerm(nil) }
        // Same for a confirmed cross-platform pairing: keep the one that exists.
        if linkedID == nil, let linked = other.linkedID {
            linkedID = linked
            pairingConfirmedAt = other.pairingConfirmedAt
        }
    }

    /// A fresh ledger row for a never-before-seen assignment.
    ///
    /// Never born archived — the archival fields simply take their nil default.
    /// An item arriving in a feed *now* is current work by construction, and a
    /// row that came back after its term was archived is a new sighting the
    /// student can archive again if they meant to.
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
