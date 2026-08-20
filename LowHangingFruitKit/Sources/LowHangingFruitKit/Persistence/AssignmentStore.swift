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
    }

    public init(url: URL) throws {
        let config = ModelConfiguration(url: url)
        self.container = try Self.makeContainer(config)
        self.isPersistent = true
        self.storageFailureReason = nil
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
        let existing = rows(source: source)

        // Partial-fetch guard: a source that previously had items suddenly
        // returning nothing is far more likely a network blip or an expired
        // session than every assignment vanishing at once. Keep the prior data
        // untouched rather than flagging it all gone.
        if fetched.isEmpty && !existing.isEmpty {
            return ReconcileResult(
                items: activeAssignments(source: source, now: now),
                wasSuspectedPartial: true
            )
        }

        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let seenIDs = Set(fetched.map(\.id))

        for item in fetched {
            if let row = existingByID[item.id] {
                row.refresh(from: item, now: now)
            } else {
                context.insert(StoredAssignment.make(from: item, now: now))
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
        allRows().filter { !isAgedOut($0, now: now) }.map(\.assignment)
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

    // MARK: Queries

    private func rows(source: Assignment.Source) -> [StoredAssignment] {
        let raw = source.rawValue
        let descriptor = FetchDescriptor<StoredAssignment>(
            predicate: #Predicate { $0.sourceRaw == raw }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func allRows() -> [StoredAssignment] {
        (try? context.fetch(FetchDescriptor<StoredAssignment>())) ?? []
    }

    private func activeAssignments(source: Assignment.Source, now: Date) -> [Assignment] {
        rows(source: source).filter { !isAgedOut($0, now: now) }.map(\.assignment)
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

    // MARK: Completion & submission truth

    /// Records manual completion on the ledger so Done survives both a relaunch
    /// and the feed dropping the item. `clearing` un-completes rows (the
    /// markActive path); both sets are applied in one save.
    public func setCompleted(ids: Set<String>, at date: Date?, clearing: Set<String> = []) {
        guard !ids.isEmpty || !clearing.isEmpty else { return }
        for row in allRows() {
            if ids.contains(row.id) {
                row.completedAt = date ?? Date()
            } else if clearing.contains(row.id) {
                row.completedAt = nil
            }
        }
        saveChanges()
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

    @discardableResult
    public func applySubmissionState(
        submittedCanvasAssignmentIDs: Set<String>,
        scores: [String: (earned: Double?, max: Double?)]
    ) -> [ScoreChange] {
        var changes: [ScoreChange] = []
        for row in rows(source: .canvas) {
            guard let canvasID = row.canvasAssignmentID else { continue }
            row.canvasSubmitted = submittedCanvasAssignmentIDs.contains(canvasID)
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
        /// When the ledger first saw anything: how far back the archive reaches.
        public let earliestFirstSeen: Date?
        public let latestSeenInFeed: Date?
    }

    public func stats() -> LedgerStats {
        let rows = allRows()
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
            earliestFirstSeen: rows.map(\.firstSeen).min(),
            latestSeenInFeed: rows.map(\.lastSeenInFeed).max()
        )
    }
}
