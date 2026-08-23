import Foundation
import SwiftData

/// Durable, reconciling home for assignments — the fix for "I lost my previous
/// assignments". Where the app used to do `canvasItems = fetched` (a wholesale
/// replace, so the list was only ever as good as the single most recent fetch),
/// a sync now *reconciles into* this ledger: new items are upserted, vanished
/// items are recorded as gone (never deleted), and a suspiciously empty fetch is
/// refused outright. The dashboard reads the union back, so a rolling Canvas
/// feed, a professor moving an item, or one flaky sync can't erase work.
///
/// Everything downstream keeps consuming the value-type `Assignment`; this class
/// is the only new seam. Lives in `LowHangingFruitKit` (not the UI module) so a
/// future widget can read the same App Group store directly.
@MainActor
public final class AssignmentStore {
    /// Shared App Group container id — matches the widget's, so the ledger lands
    /// in the same place the widget can later read.
    /// `nonisolated` for the same reason `goneGracePeriod` is: non-main-actor
    /// callers (the widget's ledger read, `SharedDefaults`) need the one
    /// canonical group id rather than their own copy of the string.
    public nonisolated static let appGroupID = "group.com.lhf.lowhangingfruit"

    /// How long a gone-from-feed item is kept visible past its due date before it
    /// ages out. Generous on purpose: the design brief says a lingering
    /// already-removed item is far better than losing real work. Undated items
    /// and anything still in the feed never age out at all.
    /// `nonisolated` so the widget extension's off-main-actor ledger read
    /// (`LedgerWidgetReader`) applies the identical rule instead of hardcoding
    /// its own copy of the number.
    public nonisolated static let goneGracePeriod: TimeInterval = 14 * 86_400

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// False when the ledger is the in-memory fallback — i.e. nothing is
    /// actually surviving a relaunch. Surfaced in Settings because "persistence
    /// is silently not persisting" is otherwise indistinguishable from working.
    public let isPersistent: Bool

    /// Why the ledger is running in memory, when it is. Nil on a healthy
    /// persistent store. Surfaced in Settings so "not saving" is legible.
    public let storageFailureReason: String?

    /// The most recent failed write, and how many have failed this session.
    /// `isPersistent` only says the container opened on disk; it says nothing
    /// about whether saves are landing. A full disk, or protected data being
    /// unavailable before first unlock, fails every save while the store still
    /// reports itself persistent.
    public private(set) var lastSaveError: String?
    public private(set) var failedSaveCount: Int = 0

    public struct ReconcileResult: Sendable {
        /// The current active set for the reconciled source — what the caller
        /// should assign to `canvasItems` / `gradescopeItems`.
        public let items: [Assignment]
        /// True when the fetch was refused as a suspected partial/failed refresh
        /// (empty result for a source that previously had items). The prior data
        /// was kept; the caller may want to surface a soft "couldn't refresh".
        public let wasSuspectedPartial: Bool
    }

    // MARK: Construction

    /// Every container the app builds goes through the versioned schema and the
    /// migration plan, so a future model change is a migration rather than a
    /// throw-and-silently-forget. See `LedgerSchema.swift`.
    private static func makeContainer(_ config: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: LedgerSchemaV1.self),
            migrationPlan: LedgerMigrationPlan.self,
            configurations: config
        )
    }

    public init(inMemory: Bool = false, storageFailureReason: String? = nil) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        self.container = try Self.makeContainer(config)
        self.isPersistent = !inMemory
        self.storageFailureReason = inMemory ? storageFailureReason : nil
        rowsByID()
    }

    public init(url: URL) throws {
        let config = ModelConfiguration(url: url)
        self.container = try Self.makeContainer(config)
        self.isPersistent = true
        self.storageFailureReason = nil
        // Sweep at load. Whatever is on disk was not necessarily written by this
        // build of the app — a restored backup or a future CloudKit merge can
        // put two rows for one assignment there, and the very first read
        // (`currentAssignments()` seeding the dashboard) must not show both.
        rowsByID()
    }

    /// The store the real app uses: a persistent SwiftData store in the shared
    /// App Group container when the app is entitled for it, and a hermetic
    /// in-memory store otherwise. In unit tests and previews there's no App Group
    /// entitlement, so `containerURL(...)` returns nil and each caller gets its
    /// own fresh in-memory store — nothing touches disk or leaks between tests.
    /// Returns nil only if even the in-memory store can't be created, in which
    /// case the app degrades to its old non-persistent behavior instead of
    /// crashing.
    public static func makeDefault() -> AssignmentStore? {
        var failure: String?
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let url = groupURL.appending(path: "Assignments.store")
            do {
                return try AssignmentStore(url: url)
            } catch {
                // The one case worth spelling out: the on-disk store exists but
                // could not be opened (a schema the migration plan can't reach,
                // a corrupt file, no free space). Falling back to memory is the
                // right move — losing the session beats refusing to launch — but
                // doing it silently is how a wiped ledger looks exactly like a
                // working one.
                failure = "Saved assignments couldn't be opened (\(error.localizedDescription)). "
                    + "This session is being kept in memory only."
            }
        } else {
            failure = "The app isn't entitled for its shared App Group container, "
                + "so assignments can't be saved to disk."
        }
        return try? AssignmentStore(inMemory: true, storageFailureReason: failure)
    }

    // MARK: Durability

    /// Saves pending changes, keeping the failure instead of discarding it.
    ///
    /// Replaces the `try? context.save()` this class used everywhere. A
    /// swallowed write failure is indistinguishable from a successful one at
    /// every call site, which meant a ledger that had stopped persisting kept
    /// reporting itself healthy right up until the user relaunched and found
    /// their work gone.
    @discardableResult
    func saveChanges(_ operation: String = #function) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            lastSaveError = nil
            return true
        } catch {
            failedSaveCount += 1
            lastSaveError = "\(operation) — \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Reconciliation

    /// Merges a freshly-fetched set for one source into the ledger and returns
    /// the current active union for that source. Never deletes: items missing
    /// from `fetched` are flagged `isGoneFromFeed`, not removed.
    public func reconcile(
        _ fetched: [Assignment],
        source: Assignment.Source,
        now: Date = Date()
    ) -> ReconcileResult {
        // One id-keyed view of the *whole* ledger, duplicates already collapsed.
        // Every lookup below goes through it, because it is now the only thing
        // keeping one assignment to one row.
        var byID = rowsByID()
        let existing = byID.values.filter { $0.sourceRaw == source.rawValue }

        // Partial-fetch guard: a source that previously had items suddenly
        // returning nothing is far more likely a network blip or an expired
        // session than every assignment vanishing at once. Keep the prior data
        // untouched rather than flagging it all gone.
        // Completion-only rows don't count as "this source previously had
        // items" — they're bookkeeping, and letting them arm the guard would
        // refuse a legitimately empty first sync for a migrated user.
        if fetched.isEmpty && existing.contains(where: { !$0.isCompletionOnly }) {
            return ReconcileResult(
                items: activeAssignments(source: source, now: now),
                wasSuspectedPartial: true
            )
        }

        let seenIDs = Set(fetched.map(\.id))

        for item in fetched {
            if let row = byID[item.id] {
                row.refresh(from: item, now: now)
            } else {
                let row = StoredAssignment.make(from: item, now: now)
                context.insert(row)
                // Record it in the map immediately. A feed that lists the same
                // id twice in one batch — a cross-listed course, two merged
                // section calendars, a repeated ICS UID — would otherwise miss
                // the lookup on the second copy and insert a twin. The database
                // used to absorb that; nothing does now except this line.
                byID[item.id] = row
            }
        }
        for row in existing where !seenIDs.contains(row.id) {
            row.isGoneFromFeed = true
        }
        saveChanges()

        // Sync is the natural place to collect: the rows dropped here are ones
        // this very reconcile just confirmed are both gone from the feed and
        // long past due.
        pruneAgedOut(now: now)

        return ReconcileResult(
            items: activeAssignments(source: source, now: now),
            wasSuspectedPartial: false
        )
    }

    /// The whole active ledger across sources, for seeding `canvasItems` /
    /// `gradescopeItems` at launch — so the class list and dashboard are
    /// populated from the first frame, before any network call returns.
    public func currentAssignments(now: Date = Date()) -> [Assignment] {
        rowsByID().values.filter { isVisible($0, now: now) }.map(\.assignment)
    }

    /// Deletes every ledger row for a source — used when the user disconnects
    /// that service, so its assignments don't linger on-device or silently
    /// reappear from the ledger on reconnect.
    public func purge(source: Assignment.Source) {
        for row in rows(source: source) { context.delete(row) }
        saveChanges()
    }

    /// Deletes rows that `isAgedOut` already hides from every read.
    ///
    /// Aging used to be filter-only: an abandoned item stopped being *shown*
    /// but its row lived on for the life of the install, so the store grew
    /// without bound and `stats()` counted rows the user had no way to see.
    /// Pruning is deliberately the same predicate as the read filter, so this
    /// can never remove something still reachable — and `isAgedOut` exempts
    /// finished work outright, so the Done archive is untouchable here.
    @discardableResult
    public func pruneAgedOut(now: Date = Date()) -> Int {
        let doomed = allRows().filter { isAgedOut($0, now: now) }
        guard !doomed.isEmpty else { return 0 }
        for row in doomed { context.delete(row) }
        saveChanges()
        return doomed.count
    }

    // MARK: Identity — uniqueness is enforced here, not by the database

    /// Every row keyed by `id`, with any duplicate ids collapsed on the spot.
    ///
    /// `StoredAssignment.id` used to carry `@Attribute(.unique)`, so the store
    /// itself refused a second row for the same assignment. CloudKit does not
    /// support unique constraints, so that guarantee had to move into code
    /// before sync can ever be switched on. This is where it now lives: every
    /// read and every write path resolves rows through this map, so an insert
    /// can only ever happen for an id nothing on the ledger already holds.
    ///
    /// Deliberately spans **all** sources rather than the one being reconciled.
    /// `id` already encodes the source, so a same-id row filed under a
    /// different `sourceRaw` ought to be impossible — but "ought to be
    /// impossible" is exactly the assumption a merge from another device
    /// breaks, and a narrower lookup is precisely what would let it insert a
    /// twin. Scanning the whole table on each call is affordable at a
    /// student's few hundred rows, and a duplicated assignment is not.
    @discardableResult
    private func rowsByID() -> [String: StoredAssignment] {
        var byID: [String: StoredAssignment] = [:]
        var doomed: [StoredAssignment] = []

        for row in allRows() {
            guard let kept = byID[row.id] else {
                byID[row.id] = row
                continue
            }
            // The copy seen in the feed most recently carries the current
            // title/date/URL, so it survives and supplies the display fields;
            // everything worth keeping from the other is merged into it.
            let survivor = row.lastSeenInFeed > kept.lastSeenInFeed ? row : kept
            let absorbed = survivor === row ? kept : row
            survivor.absorb(absorbed)
            byID[row.id] = survivor
            doomed.append(absorbed)
        }

        if !doomed.isEmpty {
            for row in doomed { context.delete(row) }
            saveChanges()
        }
        return byID
    }

    // MARK: Queries

    /// Rows for one source, resolved through `rowsByID()` so no caller can ever
    /// see — or write to — one of two copies of the same assignment. This is a
    /// filter over the full table rather than the `#Predicate` fetch it used to
    /// be; the swap is what buys that guarantee, and the row counts involved
    /// make the cost irrelevant.
    private func rows(source: Assignment.Source) -> [StoredAssignment] {
        let raw = source.rawValue
        return rowsByID().values.filter { $0.sourceRaw == raw }
    }

    /// The raw table, duplicates and all. Only `rowsByID()` (which resolves
    /// them) and the diagnostics in `stats()` (which count them) may use this —
    /// everything else goes through a deduplicated view.
    private func allRows() -> [StoredAssignment] {
        (try? context.fetch(FetchDescriptor<StoredAssignment>())) ?? []
    }

    private func activeAssignments(source: Assignment.Source, now: Date) -> [Assignment] {
        rows(source: source).filter { isVisible($0, now: now) }.map(\.assignment)
    }

    /// Whether a row represents an assignment the app should show. Excludes
    /// aged-out rows and completion-only bookkeeping rows, which carry no
    /// trustworthy title or course and must never reach a list.
    private func isVisible(_ row: StoredAssignment, now: Date) -> Bool {
        !row.isCompletionOnly && !isAgedOut(row, now: now)
    }

    /// An item ages out only once it's BOTH gone from the feed AND overdue past
    /// the grace period. Still in the feed, or undated, or not yet overdue → kept.
    ///
    /// Finished work is exempt outright. Aging exists to stop *abandoned* items
    /// accumulating, and a completed or submitted assignment is the opposite of
    /// abandoned — it's the archive the Done tab is built on. Without this an
    /// assignment you turned in would quietly vanish from your own record two
    /// weeks after it rolled off the Canvas feed.
    private func isAgedOut(_ row: StoredAssignment, now: Date) -> Bool {
        guard !row.isFinished else { return false }
        guard row.isGoneFromFeed, let due = row.dueAt else { return false }
        return due < now.addingTimeInterval(-Self.goneGracePeriod)
    }

    // MARK: User-created work

    /// Upserts rows for work that doesn't come from a feed — the user's own
    /// manual assignments, and any generated occurrence they interact with.
    ///
    /// Manual work used to live only as a JSON blob in UserDefaults, which
    /// meant the thing the app could least afford to lose — the assignment
    /// Canvas doesn't know about, that exists nowhere else — was the one thing
    /// with no durable record, no archive, and no presence in the widget.
    ///
    /// `reconcile` only ever runs for `.canvas` / `.gradescope`, so these rows
    /// are never marked gone, and `isAgedOut` requires `isGoneFromFeed` — user
    /// work therefore never ages out. That's deliberate: aging exists to clear
    /// abandoned *feed* items, and nothing about a manual assignment is
    /// abandoned just because it's old.
    @discardableResult
    public func upsert(_ assignments: [Assignment], now: Date = Date()) -> Int {
        guard !assignments.isEmpty else { return 0 }
        let existing = Dictionary(allRows().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var created = 0
        for item in assignments {
            if let row = existing[item.id] {
                row.refresh(from: item, now: now)
            } else {
                context.insert(StoredAssignment.make(from: item, now: now))
                created += 1
            }
        }
        saveChanges()
        return created
    }

    /// The active rows for one source, as value types. Projects manual work
    /// back out of the ledger for the UI to edit.
    public func assignments(source: Assignment.Source, now: Date = Date()) -> [Assignment] {
        activeAssignments(source: source, now: now)
    }

    /// Deletes specific rows outright.
    ///
    /// The only place in this class where removing a row is the *correct*
    /// outcome rather than the bug it was built to prevent: the user deleted
    /// their own item and means it. Feed items still never take this path —
    /// they go gone-from-feed and age out.
    public func delete(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for row in allRows() where ids.contains(row.id) { context.delete(row) }
        saveChanges()
    }

    // MARK: Completion & submission truth

    /// Every id the ledger records as ticked off by the user, and the timestamp
    /// where one is known.
    ///
    /// This is what makes the ledger *authoritative* for completion rather than
    /// a mirror of it: `AppState.completedAssignmentIDs` and `.completionDates`
    /// are derived from this call instead of being persisted a second time as
    /// UserDefaults blobs that could drift out of step with these rows.
    ///
    /// An id appears in `ids` with no entry in `dates` when the completion is
    /// known to have happened but not when — see `StoredAssignment.completedAt`.
    public struct CompletionRecord: Sendable, Equatable {
        public let ids: Set<String>
        public let dates: [String: Date]

        public static let empty = CompletionRecord(ids: [], dates: [:])
    }

    public func completionRecord() -> CompletionRecord {
        var ids: Set<String> = []
        var dates: [String: Date] = [:]
        for row in rowsByID().values where row.isCompletedByUser {
            ids.insert(row.id)
            if let completedAt = row.completedAt { dates[row.id] = completedAt }
        }
        return CompletionRecord(ids: ids, dates: dates)
    }

    /// Records manual completion on the ledger so Done survives both a relaunch
    /// and the feed dropping the item. `clearing` un-completes rows (the
    /// markActive path); both sets are applied in one save.
    ///
    /// An id with no row yet still gets recorded, via a hidden completion-only
    /// row (`StoredAssignment.completionOnly`). That covers the two cases where
    /// silently dropping the write would lose the user's tick: manual and
    /// recurring tasks, which no feed ever reconciles into the ledger, and a
    /// cross-platform `linkedID` counterpart whose own row hasn't been synced.
    /// `prototypes` supplies the full value type where the caller has it so the
    /// row isn't blank; it is looked up by id and is optional.
    ///
    /// Un-completing deletes any row that existed *only* to hold the completion,
    /// so toggling an item on and off leaves the ledger exactly as it found it.
    public func setCompleted(
        ids: Set<String>,
        at date: Date?,
        clearing: Set<String> = [],
        prototypes: [Assignment] = [],
        now: Date = Date()
    ) {
        guard !ids.isEmpty || !clearing.isEmpty else { return }
        var unrecorded = ids
        for row in rowsByID().values {
            if ids.contains(row.id) {
                row.markCompleted(at: date ?? now)
                unrecorded.remove(row.id)
            } else if clearing.contains(row.id) {
                if row.isCompletionOnly {
                    context.delete(row)
                } else {
                    row.clearCompletion()
                }
            }
        }

        let prototypesByID = Dictionary(prototypes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in unrecorded {
            guard let row = StoredAssignment.completionOnly(
                id: id,
                prototype: prototypesByID[id],
                completedAt: date ?? now,
                now: now
            ) else { continue }
            context.insert(row)
        }
        saveChanges()
    }

    /// Completion as a plain id-to-date map.
    ///
    /// A narrower read of `completionRecord()`, which is the authoritative one —
    /// this exists because most callers only ever want the dates and reading
    /// `.dates` off a record they immediately discard says less than it costs.
    /// Both are projections of the ledger, never a second copy of the truth:
    /// completion used to be persisted independently in UserDefaults *and*
    /// mirrored onto rows, and when the two drifted the Done tab and the aging
    /// exemption disagreed about what was finished — with that exemption being
    /// the only thing standing between completed work and deletion.
    public func completionDates() -> [String: Date] {
        completionRecord().dates
    }

    /// One-time import of the pre-ledger completion state — the
    /// `completedAssignmentIDs` array and `completionDates` JSON map that used
    /// to live in UserDefaults. Returns how many ids were recorded.
    ///
    /// Two rules keep it safe to run against a ledger that already knows things:
    /// a row already marked completed is left alone (the ledger's own record is
    /// never older than the blob's), and an id with no row is held as a
    /// completion-only row until its feed arrives, rather than being dropped.
    /// An id present in `ids` but absent from `dates` is recorded *without* a
    /// timestamp, preserving the "completed, when unknown" state the Done tab
    /// and the weekly ring both treat specially.
    @discardableResult
    public func importLegacyCompletions(
        ids: Set<String>,
        dates: [String: Date],
        now: Date = Date()
    ) -> Int {
        guard !ids.isEmpty else { return 0 }
        var pending = ids
        var recorded = 0
        for row in rowsByID().values where pending.contains(row.id) {
            pending.remove(row.id)
            guard !row.isCompletedByUser else { continue }
            row.markCompleted(at: dates[row.id])
            recorded += 1
        }
        for id in pending {
            guard let row = StoredAssignment.completionOnly(
                id: id,
                completedAt: dates[id],
                now: now
            ) else { continue }
            context.insert(row)
            recorded += 1
        }
        saveChanges()
        return recorded
    }

    /// Writes Grade Watcher's Canvas submission side-channel and per-assignment
    /// scores onto the ledger, keyed by Canvas assignment id.
    ///
    /// Deliberately a full **replace** of the Canvas flag, not a merge: a
    /// retracted or TA-cleared submission has to be able to go back to
    /// unsubmitted, which is exactly why the in-memory set was recomputed from
    /// scratch each refresh. Persisting it keeps that self-healing property
    /// while also surviving a launch with no Canvas session — the case where the
    /// app previously knew nothing at all about what you'd turned in.
    /// A grade that appeared or moved between two refreshes. `previous == nil`
    /// means this is the first score the ledger has ever held for the item —
    /// i.e. the grade just posted.
    public struct ScoreChange: Sendable, Equatable {
        public let assignmentID: String
        public let course: String
        public let title: String
        public let previous: Double?
        public let earned: Double
        public let max: Double?

        /// True for a freshly-posted grade, false for a regrade.
        public var isNewlyGraded: Bool { previous == nil }
    }

    /// Writes this refresh's Canvas submission flags and scores onto the ledger.
    ///
    /// `observedCanvasAssignmentIDs` is what separates the two things a caller
    /// hands over here. The submitted set is deliberately allowed to be wider
    /// than this refresh — callers merge in what the ledger already knew, so a
    /// course that 401'd mid-loop doesn't get its finished work erased — but a
    /// carried-over id is *not* something Canvas answered for just now, and
    /// dating it as though it were would turn a stale record into a
    /// confident-looking fresh one. Pass the ids this pass genuinely covered and
    /// only those get a new observation date; the rest keep the date they had,
    /// which is the honest answer and the one `hasFreshSubmissionState` needs.
    ///
    /// Nil means "everything on the ledger was covered" — the whole-refresh
    /// case, and the behaviour before partial refreshes were handled.
    @discardableResult
    public func applySubmissionState(
        submittedCanvasAssignmentIDs: Set<String>,
        scores: [String: (earned: Double?, max: Double?)],
        observedCanvasAssignmentIDs: Set<String>? = nil,
        now: Date = Date()
    ) -> [ScoreChange] {
        var changes: [ScoreChange] = []
        for row in rows(source: .canvas) {
            guard let canvasID = row.canvasAssignmentID else { continue }
            row.canvasSubmitted = submittedCanvasAssignmentIDs.contains(canvasID)
            // Canvas answered for this item — either way. Absence of a
            // submission is a real observation too, and it is the one most worth
            // timestamping: it is what the app shows when it tells a student
            // they still owe work.
            if observedCanvasAssignmentIDs?.contains(canvasID) ?? true {
                row.canvasSubmissionObservedAt = now
            }
            guard let score = scores[canvasID] else { continue }

            // Only a real number counts as a grade. Canvas reports ungraded work
            // as a null score, and a null must never read as "your grade changed".
            if let earned = score.earned, row.scoreEarned != earned {
                changes.append(ScoreChange(
                    assignmentID: canvasID,
                    course: row.course,
                    title: row.title,
                    previous: row.scoreEarned,
                    earned: earned,
                    max: score.max ?? row.scoreMax
                ))
            }
            row.scoreEarned = score.earned
            row.scoreMax = score.max
        }
        saveChanges()
        return changes
    }

    // MARK: Cross-platform pairings

    /// Every Canvas↔Gradescope pairing the ledger has recorded, for seeding the
    /// deduplicator so a merge outlives the heuristic that first found it.
    public func confirmedPairings() -> [AssignmentDeduplicator.Match] {
        rows(source: .canvas).compactMap { row in
            guard let linked = row.linkedID else { return nil }
            return AssignmentDeduplicator.Match(canvasID: row.id, gradescopeID: linked)
        }
    }

    /// Writes this rebuild's pairings onto the ledger. Recorded on both rows so
    /// either side can find its counterpart, and stamped with the time so a
    /// future policy could expire a pairing that stops re-matching.
    ///
    /// Pairings are only ever added here, never cleared: dropping one because
    /// the live heuristic stopped agreeing is precisely the failure this is
    /// meant to prevent. `purge(source:)` is what clears them, on disconnect.
    public func recordPairings(_ matches: [AssignmentDeduplicator.Match], now: Date = Date()) {
        guard !matches.isEmpty else { return }
        let gradescopeByID = Dictionary(
            rows(source: .gradescope).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let canvasByID = Dictionary(
            rows(source: .canvas).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var changed = false
        for match in matches {
            if let row = canvasByID[match.canvasID], row.linkedID != match.gradescopeID {
                row.linkedID = match.gradescopeID
                row.pairingConfirmedAt = now
                changed = true
            }
            if let row = gradescopeByID[match.gradescopeID], row.linkedID != match.canvasID {
                row.linkedID = match.canvasID
                row.pairingConfirmedAt = now
                changed = true
            }
        }
        if changed { saveChanges() }
    }

    /// The persisted Canvas submission set, for seeding `AppState` at launch
    /// before (or without) any grade refresh.
    public func submittedCanvasAssignmentIDs() -> Set<String> {
        var ids: Set<String> = []
        for row in rows(source: .canvas) where row.canvasSubmitted {
            if let canvasID = row.canvasAssignmentID { ids.insert(canvasID) }
        }
        return ids
    }

    // MARK: Test/diagnostic access

    /// Total rows on the ledger (including aged/gone), for tests and diagnostics.
    public func rowCount() -> Int { allRows().count }

    /// The ledger's rows, duplicates already collapsed, for tests that need to
    /// assert on stored fields the value-type `Assignment` doesn't carry —
    /// submission observation dates in particular.
    public func allRowsForTesting() -> [StoredAssignment] { Array(rowsByID().values) }

    /// A snapshot of what the ledger is actually holding. Backs the Settings →
    /// Storage panel: without it, "the database is working" and "the database
    /// silently fell back to memory and you'll lose everything on quit" look
    /// exactly the same from inside the app.
    public struct LedgerStats: Sendable, Equatable {
        public let isPersistent: Bool
        /// Why the ledger fell back to memory, when it did. Nil when healthy.
        public let storageFailureReason: String?
        /// Most recent failed write this session, and the running count.
        public let lastSaveError: String?
        public let failedSaveCount: Int

        /// True only when the ledger is on disk *and* its writes are landing.
        /// Settings should key off this rather than `isPersistent` alone — a
        /// store can be perfectly persistent and still be failing every save.
        public var isHealthy: Bool {
            isPersistent && storageFailureReason == nil && failedSaveCount == 0
        }
        public let total: Int
        public let canvas: Int
        public let gradescope: Int
        /// Retained but no longer published by the source feed.
        public let goneFromFeed: Int
        /// Ticked off, or reported submitted by either platform — the rows that
        /// are now exempt from aging.
        public let finished: Int
        public let withScores: Int
        /// Ids the ledger is holding more than one row for. Uniqueness is a
        /// code invariant now that the database no longer enforces it, so this
        /// is the number that says whether the invariant is actually holding.
        /// Anything but zero is a bug.
        public let duplicateIDs: Int
        /// When the ledger first saw anything: how far back the archive reaches.
        public let earliestFirstSeen: Date?
        public let latestSeenInFeed: Date?
    }

    /// Completion-only rows are excluded: the panel answers "what is the ledger
    /// holding for me", and a hidden bookkeeping row is not an assignment.
    public func stats() -> LedgerStats {
        let rows = allRows().filter { !$0.isCompletionOnly }
        return LedgerStats(
            isPersistent: isPersistent,
            storageFailureReason: storageFailureReason,
            lastSaveError: lastSaveError,
            failedSaveCount: failedSaveCount,
            total: rows.count,
            canvas: rows.filter { $0.sourceRaw == Assignment.Source.canvas.rawValue }.count,
            gradescope: rows.filter { $0.sourceRaw == Assignment.Source.gradescope.rawValue }.count,
            goneFromFeed: rows.filter(\.isGoneFromFeed).count,
            finished: rows.filter(\.isFinished).count,
            withScores: rows.filter { $0.scoreEarned != nil }.count,
            duplicateIDs: rows.count - Set(rows.map(\.id)).count,
            earliestFirstSeen: rows.map(\.firstSeen).min(),
            latestSeenInFeed: rows.map(\.lastSeenInFeed).max()
        )
    }
}
