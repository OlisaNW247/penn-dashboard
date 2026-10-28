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
    /// in the same place the widget can later read. Read through `WidgetSharing`
    /// rather than repeating the literal: on macOS the usable id depends on
    /// whether the process is sandboxed, and a second copy of the string is a
    /// second answer to that question.
    public static let appGroupID = WidgetSharing.appGroupID

    /// The private CloudKit database container the ledger mirrors into when
    /// sync is turned on. Opt-in only — see `init(cloudKitGroupURL:)` and
    /// `makeDefault(syncEnabled:)` — and otherwise unused.
    public static let cloudContainerID = "iCloud.com.lhf.lowhangingfruit"

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

    /// The due dates the student edited by hand, `[assignment id: Date]`, handed
    /// in by `AppState` (which owns them; they live in defaults, not the
    /// ledger) so the aging rule can see them. Empty until `AppState` says
    /// otherwise, which is the old behaviour exactly.
    ///
    /// A property rather than a parameter on `reconcile`, `pruneAgedOut` and
    /// every read, because the aging predicate runs on all of them
    /// (`isVisible` guards `currentAssignments`, `assignments(source:)` and the
    /// `reconcile` result, and `reconcile` prunes through it), and a path that
    /// forgot to pass the dates would quietly hide, or delete, exactly what the
    /// rule is here to keep. `AppState` pushes the dictionary on every change
    /// and before the first read at launch. See `isAgedOut`.
    public var editedDueDates: [String: Date] = [:]

    /// False when the ledger is the in-memory fallback — i.e. nothing is
    /// actually surviving a relaunch. Surfaced in Settings because "persistence
    /// is silently not persisting" is otherwise indistinguishable from working.
    public let isPersistent: Bool

    /// Why the ledger is running in memory, when it is. Nil on a healthy
    /// persistent store.
    public let storageFailureReason: String?

    /// The most recent failed write, and how many failed this session.
    /// `isPersistent` only says the container opened on disk; it says nothing
    /// about whether saves are landing. A full disk, or protected data being
    /// unavailable before first unlock, fails every save while the store still
    /// reports itself persistent.
    public private(set) var lastSaveError: String?
    public private(set) var failedSaveCount: Int = 0

    /// The read-side counterpart of the two properties above: the most recent
    /// failed fetch of the ledger, and how many failed this session.
    ///
    /// A fetch that throws is not an empty ledger, and for a long time the
    /// store treated it as one (`allRows` returned `[]`): a sync read "nothing
    /// here", flagged nothing, refused or inserted accordingly, and the next
    /// read, a second later, might see everything. The two callers that decide
    /// something from the answer abort instead (`reconcile`, `completionRecord`,
    /// `holdsFeedRows`), and every failure, whoever handles it, is counted here
    /// so `StorageHealth` can say the ledger could not be read, which is a
    /// different fact from "nothing is being saved". Cleared by the next fetch
    /// that succeeds, like `lastSaveError`.
    public private(set) var lastReadError: String?
    public private(set) var failedReadCount: Int = 0

    /// Test seam: how many fetches succeed before `readFailureForTesting` takes
    /// effect, for the case that matters to `reconcile`: a pass whose first
    /// fetch works and whose next one does not. Zero, the default, fails from
    /// the first.
    var readsBeforeFailureForTesting = 0

    /// Test seam: while set, every fetch of the ledger throws this instead of
    /// reading. A closed or corrupted container fails in ways a test cannot
    /// arrange on demand, and the interesting behaviour is what the callers do
    /// when the answer is an error. Never set outside tests.
    var readFailureForTesting: (any Error)?

    /// Test seam, the write-side twin of `readFailureForTesting`: while set,
    /// every save that has something to save fails with this instead of
    /// writing. The pending changes stay in the context, exactly as after a real
    /// failed save, so the next save that works carries them. Never set outside
    /// tests.
    var saveFailureForTesting: (any Error)?

    public struct ReconcileResult: Sendable {
        /// The current active set for the reconciled source — what the caller
        /// should assign to `canvasItems` / `gradescopeItems`.
        public let items: [Assignment]
        /// True when the fetch was refused as a suspected partial/failed refresh
        /// (empty result for a source that previously had items). The prior data
        /// was kept; the caller may want to surface a soft "couldn't refresh".
        public let wasSuspectedPartial: Bool
        /// True when the ledger could not be read, so nothing was reconciled:
        /// nothing written, nothing flagged gone, nothing aged out, and no
        /// verdict on whether the fetch looked suspiciously empty (the guard
        /// compares the fetch with what the ledger holds, and the ledger could
        /// not say). `items` is empty and means nothing in that case. The
        /// caller must keep the pool it already has, not replace it with
        /// `items`, or a read error becomes a wiped dashboard.
        public let readFailed: Bool
        /// False when the reconcile's changes are in memory but the save that
        /// should have made them durable failed. The dashboard still shows them,
        /// and they are written by the next save that works; a caller that is
        /// about to forget something because "it is on disk now" must not
        /// forget it on this.
        public let saved: Bool

        init(items: [Assignment], wasSuspectedPartial: Bool, readFailed: Bool = false, saved: Bool = true) {
            self.items = items
            self.wasSuspectedPartial = wasSuspectedPartial
            self.readFailed = readFailed
            self.saved = saved
        }
    }

    // MARK: Construction

    /// Every container goes through the versioned schema and the migration
    /// plan, so a future model change is a migration rather than a throw the
    /// caller turns into a silent in-memory fallback. See `LedgerSchema.swift`.
    ///
    /// Through `LedgerContainer`, the one door, and not a `ModelContainer`
    /// built here: the door is what takes the pre-migration copy and keeps the
    /// schema-version marker, and the app is the only process that is allowed
    /// to migrate (the widget refuses a store that is older than its schema).
    /// A container built here instead would migrate with no copy and no marker,
    /// and the widget, seeing no marker, would then copy the already-migrated
    /// file as the "pre-migration" backup.
    private static func makeContainer(_ config: ModelConfiguration) throws -> ModelContainer {
        try LedgerContainer.make(config)
    }

    public init(inMemory: Bool = false, storageFailureReason: String? = nil) throws {
        // cloudKitDatabase MUST be pinned to .none on every non-cloud path:
        // the parameter defaults to .automatic, which adopts the first
        // container in the app's entitlements — and the app now carries an
        // iCloud container entitlement (Tier 2). Without the pin, plain
        // local stores would silently start mirroring to CloudKit for every
        // user, ignoring the sync toggle entirely.
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        self.container = try Self.makeContainer(config)
        self.isPersistent = !inMemory
        self.storageFailureReason = inMemory ? storageFailureReason : nil
        rowsByID()
    }

    /// - Parameter storageFailureReason: Normally nil — a plain local store is
    ///   fully healthy. Non-nil only on the `makeDefault(syncEnabled: true)`
    ///   fallback path, where CloudKit mirroring failed to start but the local
    ///   ledger opened fine: the store is genuinely persistent (`isPersistent`
    ///   is still `true`), it just isn't syncing, and Settings' storage panel
    ///   has no other way to say so. Existing call sites all take the default
    ///   and are byte-for-byte unaffected.
    public init(url: URL, storageFailureReason: String? = nil) throws {
        // .none pinned for the same reason as init(inMemory:) above — the
        // .automatic default would adopt the newly-entitled iCloud container.
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        self.container = try Self.makeContainer(config)
        self.isPersistent = true
        self.storageFailureReason = storageFailureReason
        // Sweep at load. Whatever is on disk was not necessarily written by this
        // build of the app — a restored backup or a future CloudKit merge can
        // put two rows for one assignment there, and the very first read
        // (`currentAssignments()` seeding the dashboard) must not show both.
        rowsByID()
    }

    /// Cloud-backed variant of `init(url:)`. `groupURL` is the App Group
    /// container URL itself (as returned by `FileManager.default
    /// .containerURL(forSecurityApplicationGroupIdentifier:)`), not the final
    /// store file — this appends `"Assignments.store"` itself, the exact same
    /// filename `init(url:)` and `LedgerWidgetReader.snapshot()` use, so
    /// turning sync on does not move the ledger out from under the widget's
    /// read path.
    ///
    /// Deliberately built via the explicit-`url:` `ModelConfiguration`
    /// initializer plus `cloudKitDatabase:`, not the `groupContainer:`-based
    /// one: the `groupContainer:` initializer resolves its own file location
    /// inside the group container, which is not documented to produce
    /// `Assignments.store` and is exactly the kind of divergence that would
    /// silently strand the widget's fallback read on an empty/stale file.
    /// Pinning the URL ourselves — the same construction `makeDefault()`
    /// already uses for the local path — makes the two configurations
    /// (synced or not) agree on where the ledger lives by construction rather
    /// than by coincidence of an internal default.
    public init(cloudKitGroupURL groupURL: URL) throws {
        let url = groupURL.appending(path: "Assignments.store")
        let config = ModelConfiguration(
            url: url,
            cloudKitDatabase: .private(Self.cloudContainerID)
        )
        self.container = try Self.makeContainer(config)
        self.isPersistent = true
        self.storageFailureReason = nil
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
    ///
    /// - Parameter syncEnabled: Opt-in CloudKit mirroring (default `false`,
    ///   matching every existing caller — passing nothing is byte-for-byte
    ///   today's behavior). When `true`, tries `init(cloudKitGroupURL:)`
    ///   first; if that throws for any reason (no iCloud account, container
    ///   not provisioned, offline at first launch, whatever), it falls back
    ///   to the exact same local, non-cloud store the `false` path uses —
    ///   sync must never cost anyone their local ledger — and records why in
    ///   `storageFailureReason` even though the store is fully persistent, so
    ///   Settings can tell the student sync didn't start instead of just
    ///   quietly not syncing. Ignored under `SharedDefaults.isTestRunner`,
    ///   which always returns the in-memory store regardless.
    public static func makeDefault(syncEnabled: Bool = false) -> AssignmentStore? {
        // Test runners must NEVER open the real shared ledger. On macOS the
        // container URL below resolves even for unentitled, unsandboxed
        // processes — swift test included — so without this branch every
        // test that constructs a bare AppState() writes fixtures into the
        // developer's actual Mac app data (seen on device: DEDUPE 9999 rows
        // on the real dashboard). In-memory, no failure banner: this is the
        // hermetic path tests were always assumed to take.
        if SharedDefaults.isTestRunner {
            return try? AssignmentStore(inMemory: true)
        }
        var failure: String?
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            if syncEnabled {
                do {
                    return try AssignmentStore(cloudKitGroupURL: groupURL)
                } catch {
                    // Sync couldn't start — fall through to the same local,
                    // non-cloud store the syncEnabled: false path opens below,
                    // so the student keeps a working (if unsynced) ledger
                    // instead of losing the session over it.
                    failure = "Sync couldn't start (\(error.localizedDescription)). "
                        + "Assignments are being saved on this device only."
                }
            }
            let url = groupURL.appending(path: "Assignments.store")
            do {
                return try AssignmentStore(url: url, storageFailureReason: failure)
            } catch {
                // Falling back to memory is right — losing the session beats
                // refusing to launch — but doing it silently is how a wiped
                // ledger looks exactly like a working one.
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
    /// Replaces the `try? context.save()` that used to be at every call site,
    /// where a failed write was indistinguishable from a successful one.
    @discardableResult
    func saveChanges(_ operation: String = #function) -> Bool {
        guard context.hasChanges else { return true }
        do {
            if let injected = saveFailureForTesting { throw injected }
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
    ///
    /// - Parameter holdingEmptiedCourses: Gradescope's guard against a page
    ///   that quietly stopped parsing. The source-level guard below only fires
    ///   when the *whole* fetch is empty, so one course whose page changed
    ///   shape (a redesign, a half-loaded response) returned no rows while
    ///   every other course still did, and its rows were flagged gone and,
    ///   if long overdue, pruned in that same call. With this on, a course
    ///   the ledger shows work for, that is missing from `fetched` entirely,
    ///   is held (`heldCourses`): its rows are not flagged this call, nothing
    ///   is pruned, and the result reports `wasSuspectedPartial`. The refusal
    ///   of an entirely empty fetch gets the same patience
    ///   (`emptyFetchIsSuspect`). Off by default and for Canvas, whose feed
    ///   legitimately drops a whole course's events when a class ends.
    public func reconcile(
        _ fetched: [Assignment],
        source: Assignment.Source,
        now: Date = Date(),
        holdingEmptiedCourses: Bool = false
    ) -> ReconcileResult {
        // One id-keyed view of the *whole* ledger, duplicates already collapsed.
        // Every lookup below goes through it, because it is now the only thing
        // keeping one assignment to one row.
        //
        // If the ledger cannot be read, stop here. Treating the failure as an
        // empty ledger is the one reading that does damage, whichever way the
        // fetch went: an empty fetch would pass the guard below as a legitimate
        // first sync, and a non-empty one would insert a twin of every row the
        // student already has. The fetched data is refetchable on the next
        // sync; nothing it would have written is worth guessing at.
        var byID: [String: StoredAssignment]
        do {
            byID = try resolvedRowsByID()
        } catch {
            return ReconcileResult(items: [], wasSuspectedPartial: false, readFailed: true)
        }
        let existing = byID.values.filter { $0.sourceRaw == source.rawValue }

        // Partial-fetch guard: a source that previously had items suddenly
        // returning nothing is far more likely a network blip or an expired
        // session than every assignment vanishing at once. Keep the prior data
        // untouched rather than flagging it all gone.
        // Completion-only rows don't count as "this source previously had
        // items" — they're bookkeeping, and letting them arm the guard would
        // refuse a legitimately empty first sync for a migrated user.
        //
        // With `holdingEmptiedCourses` (Gradescope) the refusal has the same
        // 24-hour patience as the per-course hold (`emptyFetchIsSuspect`).
        // Without it, a student whose Gradescope really has no rows was shown
        // "couldn't refresh" on every sync, forever, now that the partial
        // result is surfaced. Past the patience, empty is real: the rows fall
        // through to the ordinary flagging and aging below, and the notice
        // stops. Canvas keeps the refusal indefinitely, as before.
        let listedRows = existing.filter { !$0.isCompletionOnly }
        if fetched.isEmpty && !listedRows.isEmpty
            && Self.emptyFetchIsSuspect(
                lastSeen: listedRows.map(\.lastSeenInFeed),
                now: now,
                withPatience: holdingEmptiedCourses
            ) {
            // Read off the rows already in hand, for the reason given at
            // `active` below: a fresh fetch that failed here would hand the
            // caller an empty list and a notice saying it is showing the
            // saved assignments.
            return ReconcileResult(
                items: existing.filter { isVisible($0, now: now) }.map(\.assignment),
                wasSuspectedPartial: true
            )
        }

        let seenIDs = Set(fetched.map(\.id))

        // Courses to leave untouched this call. Read before the loop below
        // refreshes any row, because it compares the ledger's labels with the
        // fetch's.
        let held: Set<String> = holdingEmptiedCourses
            ? Self.heldCourses(
                ledger: existing
                    .filter { !$0.isCompletionOnly && !$0.isFinished && !$0.isArchived && !$0.isGoneFromFeed }
                    .map { HeldCourseCandidate(id: $0.id, course: $0.course, lastSeenInFeed: $0.lastSeenInFeed) },
                fetchedIDs: seenIDs,
                fetchedCourses: Set(fetched.map(\.course)),
                now: now
            )
            : []

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
        for row in existing where !seenIDs.contains(row.id) && !held.contains(row.course) {
            row.isGoneFromFeed = true
        }
        let saved = saveChanges()

        // The answer is read off the map this pass already holds rather than
        // from a fresh fetch afterwards. A second fetch that failed here would
        // come back empty and hand the caller `items: []` with `readFailed`
        // false, which is a wiped dashboard by another route. Taken before the
        // prune below, which is safe: it deletes only what `isVisible` already
        // excludes.
        let active = byID.values
            .filter { $0.sourceRaw == source.rawValue && isVisible($0, now: now) }
            .map(\.assignment)

        // Sync is the natural place to collect: the rows dropped here are ones
        // this very reconcile just confirmed are both gone from the feed and
        // long past due. Completion-only rows are safe — they're finished by
        // definition, and `isAgedOut` exempts finished work.
        //
        // Not in a call that held a course back: that call is the one that
        // suspects the fetch, and a collection pass after a suspect fetch is
        // how a redesigned page used to cost the student rows for good.
        if held.isEmpty { pruneAgedOut(now: now) }

        return ReconcileResult(
            items: active,
            wasSuspectedPartial: !held.isEmpty,
            saved: saved
        )
    }

    /// One unfinished, still-listed ledger row, reduced to what the hold rule
    /// reads.
    struct HeldCourseCandidate: Equatable {
        let id: String
        let course: String
        let lastSeenInFeed: Date
    }

    /// How long a course may stay missing from a fetch before it is believed.
    /// A broken page or a flaky response mends within hours, so for a day a
    /// vanished course is a suspicion; after that it is a fact (the class
    /// ended, the student dropped it, the term rolled over and the account
    /// page stopped listing it) and ordinary flagging and aging take over.
    /// Without the limit a course that really left would be held forever and
    /// its work would sit in the overdue pile for good. Measured from the
    /// course's newest `lastSeenInFeed`, which only a sighting advances, so
    /// holding it does not extend its own patience.
    nonisolated static let heldCoursePatience: TimeInterval = 24 * 60 * 60

    /// Whether an entirely empty fetch for a source that has listed rows should
    /// still be refused as partial. `lastSeen` is each listed row's
    /// `lastSeenInFeed`; the source was last non-empty at the newest of them.
    /// Without patience (Canvas) the answer is always yes. With it
    /// (`holdingEmptiedCourses`) it is yes only until `heldCoursePatience` has
    /// passed since that sighting, and then the empty result is believed. Only
    /// a sighting advances `lastSeenInFeed`, so refusing does not extend its
    /// own patience, and the next non-empty fetch restarts it.
    nonisolated static func emptyFetchIsSuspect(lastSeen: [Date], now: Date, withPatience: Bool) -> Bool {
        guard let newest = lastSeen.max() else { return false }
        guard withPatience else { return true }
        return now.timeIntervalSince(newest) < heldCoursePatience
    }

    /// Pure rule behind `holdingEmptiedCourses`: which course labels to leave
    /// unflagged this call. A course is held when the ledger lists unfinished
    /// work for it, none of that work came back (`fetchedIDs`), nothing at all
    /// came back under its label (`fetchedCourses`, so a course whose work was
    /// replaced by new rows is an ordinary change, not an emptied page), and it
    /// was last seen within `heldCoursePatience`. Matched by id first, label
    /// second, because a course renamed on Gradescope keeps its assignment ids
    /// and changes its label: by label alone the ledger's old name would look
    /// emptied while every one of its rows was present.
    nonisolated static func heldCourses(
        ledger: [HeldCourseCandidate],
        fetchedIDs: Set<String>,
        fetchedCourses: Set<String>,
        now: Date
    ) -> Set<String> {
        var held: Set<String> = []
        for (course, rows) in Dictionary(grouping: ledger, by: \.course) {
            guard !course.isEmpty, !fetchedCourses.contains(course) else { continue }
            guard !rows.contains(where: { fetchedIDs.contains($0.id) }) else { continue }
            guard let newest = rows.map(\.lastSeenInFeed).max(),
                  now.timeIntervalSince(newest) < heldCoursePatience
            else { continue }
            held.insert(course)
        }
        return held
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
    /// Deletes rows that `isAgedOut` already hides from every read.
    ///
    /// Aging used to be filter-only: an abandoned item stopped being *shown* but
    /// its row lived on for the life of the install. Deliberately the same
    /// predicate as the read filter, so this can never remove something still
    /// reachable — and `isAgedOut` exempts finished work outright, so the Done
    /// archive is untouchable here.
    @discardableResult
    public func pruneAgedOut(now: Date = Date()) -> Int {
        let doomed = ((try? allRows()) ?? []).filter { isAgedOut($0, now: now) }
        guard !doomed.isEmpty else { return 0 }
        for row in doomed { context.delete(row) }
        saveChanges()
        return doomed.count
    }

    public func purge(source: Assignment.Source) {
        for row in rows(source: source) { context.delete(row) }
        saveChanges()
    }

    /// Disconnect's version of `purge(source:)`: removes the unfinished feed
    /// rows of a source and KEEPS every row that records something the student
    /// did, flagged `isGoneFromFeed` so nothing reads it as still listed.
    ///
    /// Kept: a row that is finished (`isFinished`: ticked off, or reported
    /// turned in by either platform) and a completion-only row (the
    /// bookkeeping row that carries a completion for an id the ledger never
    /// held a real row for). Removed: everything else, which is exactly the
    /// feed's own copy of work nobody finished, and which a reconnect fetches
    /// again.
    ///
    /// Why not `purge(source:)`. Disconnecting Canvas is also the only repair
    /// a student whose login is stuck can reach, and `purge` took their whole
    /// Done history and every completion with it, on a path whose
    /// confirmation never says so. CLAUDE.md's invariant is that nothing the
    /// student did is ever lost, and a tick is the clearest thing they did.
    /// The wrong fix is "keep finished rows but unflag them": an unflagged
    /// row with no session behind it reads as live, `isAgedOut` only ever
    /// considers rows that are gone from the feed, and a row the feed no
    /// longer lists is precisely what the flag says.
    ///
    /// **A row the student moved the date on is kept too** (`editedDueDates`,
    /// pushed in by `AppState`). The edit is the student's own work, kept in
    /// defaults beside the ledger, and it is only ever forgotten when its row
    /// has left the ledger (`AppState.pruneDueDateEdits`). Deleting an
    /// unfinished row whose date was edited therefore deleted the edit one
    /// relaunch later: the finished rows that survive load the Canvas family,
    /// the pruner sees the edited id missing from it, and forgets the edit. It
    /// never happened when `purge` left no Canvas rows at all, which is why
    /// the family check treated "no Canvas rows" as "nothing loaded". Such a
    /// row stays flagged gone from the feed; the aging rule retires it once
    /// both its dates are over a fortnight old. The cost is that an edited,
    /// unfinished item is on the dashboard again after a relaunch, with Canvas
    /// disconnected.
    ///
    /// Not `purgeIncomplete(source:)`, which has another job (re-deriving a
    /// source from scratch after an extractor change) and deletes a
    /// completion-only row that is not finished. Returns how many rows were
    /// removed.
    @discardableResult
    public func purgeKeepingStudentWork(source: Assignment.Source) -> Int {
        var removed = 0
        var flagged = false
        for row in rows(source: source) {
            if row.isFinished || row.isCompletionOnly || editedDueDates[row.id] != nil {
                if !row.isGoneFromFeed {
                    row.isGoneFromFeed = true
                    flagged = true
                }
            } else {
                context.delete(row)
                removed += 1
            }
        }
        if removed > 0 || flagged { saveChanges() }
        return removed
    }

    /// `purge(source:)`'s narrower sibling: deletes every row for a source
    /// EXCEPT ones the student has already finished (`isFinished` — ticked
    /// off, or reported turned in by either platform). Written for the
    /// announcement-extraction repair (`AppState`'s one-time bump past
    /// `announcementExtractionVersion`): the old heuristic extractor filed
    /// purely informational announcements as assignments, and the fix is to
    /// re-derive `.canvasAnnouncement` rows from scratch with the corrected
    /// extractor rather than patch what's already on disk — but a student who
    /// had already checked one of those rows off did real work marking it
    /// done, and wiping it out from under them on the next launch would be
    /// exactly the kind of silent data loss "the ledger is the point" exists
    /// to prevent. A wrong-but-completed row is a harmless leftover; a
    /// wrong-and-incomplete one is the actual bug being fixed.
    @discardableResult
    public func purgeIncomplete(source: Assignment.Source) -> Int {
        let doomed = rows(source: source).filter { !$0.isFinished }
        guard !doomed.isEmpty else { return 0 }
        for row in doomed { context.delete(row) }
        saveChanges()
        return doomed.count
    }

    // MARK: Targeted gone-from-feed flags

    /// Flags specific rows `isGoneFromFeed`, leaving every other field alone.
    ///
    /// `reconcile` flags a whole source's missing rows at once, which is the
    /// wrong tool for announcement-derived rows: `.canvasAnnouncement` rows are
    /// added by `upsert`, one announcement at a time, so no fetch ever holds
    /// "the complete set" to reconcile against. The caller (the announcement
    /// sync) knows exactly which posts Canvas stopped returning inside the
    /// window it asked for, and passes the rows of those posts here. The row,
    /// its completion and its place in the ledger stay: this is the same flag
    /// `reconcile` sets, but not the same consequences. `isAgedOut` exempts
    /// `.canvasAnnouncement` rows altogether, so a flagged announcement row is
    /// hidden by the readers and never deleted, and `markPresentInFeed` can
    /// always bring it back. (Until 2026-10-18 the comment here said "never
    /// deleted" while the aging rule deleted it 14 days after its date.)
    /// Ids with no row are ignored. Returns how many rows changed.
    @discardableResult
    public func markGoneFromFeed(ids: Set<String>) -> Int {
        guard !ids.isEmpty else { return 0 }
        var changed = 0
        for row in rowsByID().values where ids.contains(row.id) && !row.isGoneFromFeed {
            row.isGoneFromFeed = true
            changed += 1
        }
        if changed > 0 { saveChanges() }
        return changed
    }

    /// The inverse of `markGoneFromFeed`: the post is back (unpublished and
    /// republished, a flaky response that dropped it), so its rows count as
    /// seen again at `now`. `upsert` does the same through `refresh`, but only
    /// for a row it is handed; this is for rows whose post was seen again
    /// without being re-extracted. Returns how many rows changed.
    @discardableResult
    public func markPresentInFeed(ids: Set<String>, now: Date = Date()) -> Int {
        guard !ids.isEmpty else { return 0 }
        var changed = 0
        for row in rowsByID().values where ids.contains(row.id) && row.isGoneFromFeed {
            row.isGoneFromFeed = false
            row.lastSeenInFeed = now
            changed += 1
        }
        if changed > 0 { saveChanges() }
        return changed
    }

    /// Ids of `source`'s rows currently flagged gone from their feed, whether
    /// or not they are still visible. A read model for callers that show a
    /// source's rows (`assignments(source:)` returns them all, flag unseen).
    public func goneFromFeedIDs(source: Assignment.Source) -> Set<String> {
        Set(rows(source: source).filter(\.isGoneFromFeed).map(\.id))
    }

    /// When the app first saw each of `source`'s rows, by id. A read model, like
    /// `goneFromFeedIDs`: no write, no column.
    ///
    /// It exists for one question. A task found in an announcement carries no
    /// posted time (`Assignment` has none, and a column for it would be a
    /// schema change an older build answers with an empty ledger), so an
    /// undated one ages out of the dashboard seven days after its post
    /// (`AppState.isHiddenAnnouncementTask`). The post date comes from the
    /// announcement log or the Ed document when either still holds the post;
    /// when neither does (the log keeps 60 days and Ed's newest 100 threads),
    /// this is the next best thing, because the app reads a post when it
    /// arrives, within a sync or so of its posting. The wrong fallback is
    /// "unknown, so keep it forever", which is the stale card the rule exists
    /// to end.
    public func firstSeenDates(source: Assignment.Source) -> [String: Date] {
        Dictionary(rows(source: source).map { ($0.id, $0.firstSeen) }, uniquingKeysWith: { first, _ in first })
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
    ///
    /// This is the forgiving form: a ledger that cannot be read reads as empty,
    /// and the failure is counted (`failedReadCount`). That is right for the
    /// many callers whose worst outcome is doing nothing (a purge or a flag
    /// finds no rows), and wrong for the ones that decide something from the
    /// answer, which use `resolvedRowsByID()` and handle the throw themselves.
    @discardableResult
    private func rowsByID() -> [String: StoredAssignment] {
        (try? resolvedRowsByID()) ?? [:]
    }

    /// `rowsByID()` that says when the ledger could not be read.
    private func resolvedRowsByID() throws -> [String: StoredAssignment] {
        var byID: [String: StoredAssignment] = [:]
        var doomed: [StoredAssignment] = []

        for row in try allRows() {
            guard let kept = byID[row.id] else {
                byID[row.id] = row
                continue
            }
            // `outranks` picks the survivor: a real row over a bookkeeping
            // one, then the copy seen in the feed most recently (it carries the
            // current title/date/URL), then a content-derived tie-break that
            // does not depend on fetch order. Everything worth keeping from the
            // other is merged into it, display fields included when the other
            // is the one that ought to supply them (`StoredAssignment.absorb`).
            let survivor = row.outranks(kept) ? row : kept
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
    ///
    /// **Throws on a failed fetch; it used to return `[]`.** An empty ledger and
    /// an unreadable one are different facts, and the first was reported for
    /// both (hardening plan 2026-10-25, KCR-02 and DAT-10). Every failure is
    /// counted here, once, whether the caller aborts on it or carries on.
    private func allRows(_ operation: String = #function) throws -> [StoredAssignment] {
        do {
            if let injected = readFailureForTesting {
                if readsBeforeFailureForTesting > 0 { readsBeforeFailureForTesting -= 1 } else { throw injected }
            }
            let rows = try context.fetch(FetchDescriptor<StoredAssignment>())
            lastReadError = nil
            return rows
        } catch {
            failedReadCount += 1
            lastReadError = "\(operation) — \(error.localizedDescription)"
            throw error
        }
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
    ///
    /// Archived work is exempt for the same reason, and the exemption is not
    /// optional. `pruneAgedOut` **deletes** what this predicate matches, and an
    /// archived row is by definition old, usually gone from the feed, and quite
    /// possibly never finished — which is every clause below satisfied at once.
    /// Without this line, agreeing to "archive Spring 2026" would hand the
    /// student's spring to the pruner a fortnight later and take the Done
    /// history with it. Archiving is the *deliberate* removal that aging was
    /// only ever a crude stand-in for: the student said put it away, not throw
    /// it out.
    ///
    /// **Announcement rows never age (`.canvasAnnouncement`: Canvas, `ed-` and
    /// `syllabus-` alike).** The flag means something different for them. A
    /// feed item is gone because the feed stopped listing it, and a feed that
    /// lists it again restores it on the next fetch, so deleting a long-gone one
    /// loses nothing the feed cannot give back. An announcement row is flagged
    /// by `AppState.reconcileAnnouncementPresence` on the evidence of a *fetch
    /// window* that can be wrong (a truncated response, a class that returned
    /// nothing), the flag is meant to be reversible (`markPresentInFeed`), and
    /// the row cannot be re-derived: `processedAnnouncementIDs` records the
    /// post as already read, so the extractor will never produce it again. A
    /// pruned row is therefore a task lost for good, to a rule written for a
    /// different kind of row. The doc comment on `markGoneFromFeed` said
    /// "flagged, never deleted" while this predicate, which `reconcile` runs
    /// through `pruneAgedOut` on every Canvas sync, deleted every unfinished
    /// flagged row 14 days after its date. The wrong fix is to trust that
    /// comment (and the test that pinned the deletion as intended) instead of
    /// the predicate. An abandoned announcement row costs a few bytes and is
    /// hidden from every list by `AppState.announcementRowsToShow` and
    /// `isTooOld`; it does not need to be collected.
    ///
    /// **The student's own date counts (`editedDueDates`).** This used to read
    /// only `row.dueAt`, the feed's date. A student who was granted an
    /// extension and moved the card to next week had a row whose feed date was
    /// long past; once Canvas stopped listing it (which is what happens to a
    /// finished-looking old item) the row was "gone and 14 days overdue" and
    /// `pruneAgedOut` deleted it out from under a card the student could see
    /// was not due yet, after which `AppState.pruneDueDateEdits` found the id
    /// missing from the ledger and forgot the edit too, so nothing was left to
    /// show it had existed. An item now ages only when every date it has is
    /// old: the later of the feed's and the student's, so an edit that is
    /// still ahead keeps it, and an edit earlier than the feed's never makes
    /// it age sooner than it did. An undated row still never ages, edit or no
    /// edit, as before. The wrong fix is to age by the edited date alone,
    /// which would delete rows the feed still says are ahead.
    ///
    /// The widget's own copy of this rule (`LedgerWidgetReader.isAgedOut`) is
    /// not changed here; it only matters when there is no published snapshot,
    /// since the snapshot the app writes uses the edited dates.
    private func isAgedOut(_ row: StoredAssignment, now: Date) -> Bool {
        guard !row.isFinished, !row.isArchived else { return false }
        guard row.sourceRaw != Assignment.Source.canvasAnnouncement.rawValue else { return false }
        guard row.isGoneFromFeed, let feedDue = row.dueAt else { return false }
        let due = max(feedDue, editedDueDates[row.id] ?? feedDue)
        return due < now.addingTimeInterval(-Self.goneGracePeriod)
    }

    // MARK: Semester archival

    /// Everything `AppState` needs to know about archival, from one pass over
    /// the table.
    ///
    /// The three questions — what is archived, which terms hold archived work,
    /// and is there a boundary to offer — are each answerable on their own
    /// below, and `AppState` used to ask all three back to back on every
    /// dashboard rebuild. A rebuild runs on every sync *and* every completion
    /// toggle, and each of those calls resolves through `rowsByID()`, which
    /// scans the whole table and can write. Asking once is the same answer for a
    /// third of the work.
    public struct ArchiveState: Sendable, Equatable {
        public let archivedIDs: Set<String>
        /// Newest first.
        public let terms: [Term]
        public let offer: SemesterRollover.Offer?
    }

    public func archiveState(now: Date = Date()) -> ArchiveState {
        let rows = rowsByID().values.filter { !$0.isCompletionOnly }
        return ArchiveState(
            archivedIDs: Set(rows.filter(\.isArchived).map(\.id)),
            terms: Array(Set(rows.compactMap(\.archivedTerm))).sorted(by: >),
            offer: SemesterRollover.detect(rows.map { $0.rolloverItem() }, now: now)
        )
    }

    /// What a rollover would do, or nil when there is no boundary to offer.
    ///
    /// Reads the whole ledger, including rows the dashboard filters out —
    /// completion-only bookkeeping rows are the one exclusion, since they carry
    /// no trustworthy course or date and counting them would inflate the number
    /// the student is shown. The judgement itself lives in `SemesterRollover`;
    /// this is only the adapter that turns rows into a census.
    public func rolloverOffer(now: Date = Date()) -> SemesterRollover.Offer? {
        let items = rowsByID().values
            .filter { !$0.isCompletionOnly }
            .map { $0.rolloverItem() }
        return SemesterRollover.detect(items, now: now)
    }

    /// Every id a rollover has filed away, for `AppState` to filter the
    /// dashboard by. Returned as ids rather than rows so the uniqueness
    /// invariant can't leak out of the store (`docs/persistence-explained.md`
    /// §4 step 2).
    public func archivedAssignmentIDs() -> Set<String> {
        Set(rowsByID().values.filter(\.isArchived).map(\.id))
    }

    /// Files every row belonging to one of `terms` under that term. Returns how
    /// many rows were actually stamped.
    ///
    /// **This is the one operation in the app that hides a student's work, so
    /// read what it does and does not do.** It writes two optional integers per
    /// row and nothing else. It deletes nothing, it clears no completion, it
    /// touches no score and no pairing. Every archived row is still on disk,
    /// still returned by `currentAssignments()`, and still reachable in Done —
    /// what changes is that `AppState` stops putting it on the dashboard and
    /// stops feeding it to `reschedule()`, and the widget stops advertising it.
    ///
    /// A row is matched on `effectiveTerm`, whose precedence (course-code term,
    /// then due date, then `firstSeen`) is what lets this catch the undated,
    /// termless leftovers that no filter over the value-type `Assignment` can
    /// see. Rows already archived are skipped rather than re-stamped, so running
    /// this twice is a no-op and the returned count is honest.
    @discardableResult
    public func archive(terms: Set<Term>, now: Date = Date()) -> Int {
        guard !terms.isEmpty else { return 0 }
        var stamped = 0
        for row in rowsByID().values {
            guard !row.isArchived, !row.isCompletionOnly,
                  let term = row.effectiveTerm(), terms.contains(term)
            else { continue }
            row.setArchivedTerm(term)
            stamped += 1
        }
        if stamped > 0 { saveChanges() }
        return stamped
    }

    /// Brings archived terms back onto the dashboard. The way out of a rollover
    /// the student regrets, and the reason archiving is safe to offer at all —
    /// nothing here was destroyed, so undoing it is just clearing two fields.
    @discardableResult
    public func unarchive(terms: Set<Term>, now: Date = Date()) -> Int {
        guard !terms.isEmpty else { return 0 }
        var cleared = 0
        for row in rowsByID().values {
            guard let archived = row.archivedTerm, terms.contains(archived) else { continue }
            row.setArchivedTerm(nil)
            cleared += 1
        }
        if cleared > 0 { saveChanges() }
        return cleared
    }

    /// Terms that currently hold at least one archived row, newest first — the
    /// "you archived these" list, and what `unarchive` is offered against.
    public func archivedTerms() -> [Term] {
        Array(Set(rowsByID().values.compactMap(\.archivedTerm))).sorted(by: >)
    }

    // MARK: User-created work

    /// Upserts rows for work that doesn't come from a feed — the user's own
    /// manual assignments, and any generated occurrence they interact with.
    ///
    /// Manual work used to live only as a JSON blob in defaults, which meant
    /// the thing the app could least afford to lose — the assignment Canvas
    /// doesn't know about, that exists nowhere else — was the one thing with no
    /// durable record, no archive, and no presence in the widget.
    ///
    /// `reconcile` only ever runs for `.canvas` / `.gradescope`, so a manual
    /// row is never marked gone, and `isAgedOut` requires `isGoneFromFeed` —
    /// user work therefore never ages out. That's deliberate: aging exists to
    /// clear abandoned *feed* items, and nothing about a manual assignment is
    /// abandoned just because it's old.
    ///
    /// Announcement-derived rows also come in through here, and unlike manual
    /// work they *are* flagged gone (`markGoneFromFeed`). They are kept safe by
    /// name, not by that argument: `isAgedOut` exempts `.canvasAnnouncement`
    /// outright (see there for what the argument got wrong).
    ///
    /// Goes through `rowsByID()` rather than `allRows()` so the uniqueness
    /// invariant this class now enforces in code holds on this path too.
    ///
    /// The result says whether the rows are on disk (`saved`), not only how many
    /// were new. It used to return the count alone and swallow a failed save, so
    /// a caller that then forgot its source copy (the legacy manual-task blob)
    /// or recorded a post as read (an announcement id) did so for rows that
    /// were never written (hardening plan 2026-10-25, B5: DAT-07).
    ///
    /// Written even when the ledger cannot be read, which is deliberate: a row
    /// inserted blind can at worst become a twin, and twins fold together
    /// (`StoredAssignment.absorb`) when the ledger reads again, whereas
    /// refusing leaves the caller's data nowhere.
    @discardableResult
    public func upsert(_ assignments: [Assignment], now: Date = Date()) -> UpsertResult {
        guard !assignments.isEmpty else { return UpsertResult(created: 0, saved: true) }
        var byID = rowsByID()
        var created = 0
        for item in assignments {
            if let row = byID[item.id] {
                row.refresh(from: item, now: now)
            } else {
                let row = StoredAssignment.make(from: item, now: now)
                context.insert(row)
                byID[item.id] = row
                created += 1
            }
        }
        return UpsertResult(created: created, saved: saveChanges())
    }

    /// What `upsert` did: how many rows were new, and whether the save that
    /// makes them durable landed.
    public struct UpsertResult: Sendable, Equatable {
        public let created: Int
        public let saved: Bool
    }

    /// The active rows for one source, as value types. Projects manual work
    /// back out of the ledger for the UI to edit.
    public func assignments(source: Assignment.Source, now: Date = Date()) -> [Assignment] {
        activeAssignments(source: source, now: now)
    }

    /// Rewrites every row's `course` through `transform`, for migrating rows
    /// that were stored under a raw registrar descriptor (e.g.
    /// "BAN_CIS-2400-001 202630") back when the parser couldn't turn it into
    /// a clean code — so the same course stops appearing under two different
    /// strings just because some of its rows predate a parser fix.
    ///
    /// Goes through `rowsByID()`, not `allRows()`, for the same reason every
    /// other write path here does: it is the deduplicated view, and it is
    /// what keeps this from writing through one of two copies of a row while
    /// leaving the other stale.
    ///
    /// Deliberately takes the transform as a parameter rather than reaching
    /// for a parser itself — this file is Kit-layer plumbing and has no
    /// business knowing what a "clean" course code looks like; that policy
    /// belongs to whoever calls this (`AppState`, via `CourseCode.parse`).
    @discardableResult
    public func normalizeCourseNames(_ transform: (String) -> String) -> Int {
        var changed = 0
        for row in rowsByID().values {
            let normalized = transform(row.course)
            guard normalized != row.course else { continue }
            row.course = normalized
            changed += 1
        }
        if changed > 0 { saveChanges() }
        return changed
    }

    /// Deletes specific rows outright.
    ///
    /// The only place in this class where removing a row is the *correct*
    /// outcome rather than the bug it was built to prevent: the user deleted
    /// their own item and means it. Feed items still never take this path —
    /// they go gone-from-feed and age out.
    ///
    /// Returns whether the deletion is on disk: false when the ledger could not
    /// be read (nothing was found to delete) or the save failed. Nothing to do
    /// is a success.
    @discardableResult
    public func delete(ids: Set<String>) -> Bool {
        guard !ids.isEmpty else { return true }
        // Nothing to delete is found in a ledger that cannot be read, and
        // saving is then pointless; the failed read is already counted.
        guard let rows = try? allRows() else { return false }
        for row in rows where ids.contains(row.id) { context.delete(row) }
        return saveChanges()
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

    ///
    /// **Nil means the ledger could not be read, which is not "nothing is
    /// completed".** The caller that took `.empty` for that overwrote its
    /// in-memory record of what the student had finished with nothing, and
    /// every finished card went back to open on the next rebuild. A caller gets
    /// nil and keeps what it has (`AppState.reloadCompletionFromLedger`).
    public func completionRecord() -> CompletionRecord? {
        guard let rows = try? resolvedRowsByID() else { return nil }
        var ids: Set<String> = []
        var dates: [String: Date] = [:]
        for row in rows.values where row.isCompletedByUser {
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
    ///
    /// Returns whether the change is on disk. False when the save failed, and
    /// also when `clearing` could not be carried out because the ledger could
    /// not be read: an un-tick cannot find the row it is meant to clear. A tick
    /// on a ledger that cannot be read is still written, as a completion-only
    /// row, because that write only ever adds (the row folds into the real one
    /// when the ledger reads again, `StoredAssignment.absorb`) and refusing it
    /// would lose the one thing the student just did.
    @discardableResult
    public func setCompleted(
        ids: Set<String>,
        at date: Date?,
        clearing: Set<String> = [],
        prototypes: [Assignment] = [],
        now: Date = Date()
    ) -> Bool {
        guard !ids.isEmpty || !clearing.isEmpty else { return true }
        var unrecorded = ids
        let existing = try? resolvedRowsByID()
        if existing == nil, !clearing.isEmpty { return false }
        for row in (existing ?? [:]).values {
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
        return saveChanges()
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
    public func completionDates() -> [String: Date]? {
        completionRecord()?.dates
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
    ///
    /// `fallbackCanvasAssignmentIDs` (ledger row id → Canvas assignment id)
    /// covers `.canvasModules` rows whose own `canvasAssignmentID` is nil
    /// because the module item carried no `/assignments/<id>` URL —
    /// `SubmissionMatcher` fills the gap by title/due-date against Canvas's
    /// own grade snapshot. It's a fallback in the literal sense: a row's own
    /// derived id, when it has one, always wins.
    ///
    /// Both `.canvas` (ICS) and `.canvasModules` rows are joined here — a
    /// module-imported assignment is exactly as real a Canvas assignment as
    /// one the ICS feed described, and deserves the same submission truth
    /// rather than reading as permanently outstanding just because it arrived
    /// through the other API.
    @discardableResult
    public func applySubmissionState(
        submittedCanvasAssignmentIDs: Set<String>,
        scores: [String: (earned: Double?, max: Double?)],
        observedCanvasAssignmentIDs: Set<String>? = nil,
        fallbackCanvasAssignmentIDs: [String: String] = [:],
        now: Date = Date()
    ) -> [ScoreChange] {
        var changes: [ScoreChange] = []
        for row in rows(source: .canvas) + rows(source: .canvasModules) {
            guard let canvasID = row.canvasAssignmentID ?? fallbackCanvasAssignmentIDs[row.id] else { continue }
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
    ///
    /// Returns whether the pairings are on disk; nothing to record is a success.
    @discardableResult
    public func recordPairings(_ matches: [AssignmentDeduplicator.Match], now: Date = Date()) -> Bool {
        guard !matches.isEmpty else { return true }
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
        return changed ? saveChanges() : true
    }

    /// The persisted Canvas submission set, for seeding `AppState` at launch
    /// before (or without) any grade refresh. Covers `.canvasModules` rows
    /// too, for the same reason `applySubmissionState` does — a module-listed
    /// assignment is the same Canvas assignment the ICS feed would otherwise
    /// have described. This reads back only `canvasAssignmentID` (a row's own
    /// URL-derived id), never `fallbackCanvasAssignmentIDs` — that map isn't
    /// persisted, it's recomputed each refresh from a live grade snapshot, so
    /// there's nothing to read back here for a row that needed one.
    public func submittedCanvasAssignmentIDs() -> Set<String> {
        var ids: Set<String> = []
        for row in rows(source: .canvas) + rows(source: .canvasModules) where row.canvasSubmitted {
            if let canvasID = row.canvasAssignmentID { ids.insert(canvasID) }
        }
        return ids
    }

    /// The course keys the ledger has *ever*, on this device, gotten a real
    /// Canvas submission answer for — i.e. at least one `.canvas` row whose
    /// `canvasSubmissionObservedAt` is non-nil (see that property's doc comment
    /// for why "observed" and "submitted" are different questions). This is
    /// the durable half of the first-launch hold in `AppState`: a fresh
    /// install has an empty set here (nothing has ever been checked), so the
    /// dashboard knows not to trust "overdue" for a course until either this
    /// device's history or this launch's live grade fetch has actually looked.
    /// A relapse to memory-only storage (see `isPersistent`) makes this set
    /// empty every launch, which is the correct, conservative answer — an
    /// in-memory ledger has no history to report.
    public func coursesWithCanvasSubmissionObservation() -> Set<String> {
        Set(rows(source: .canvas).compactMap { $0.canvasSubmissionObservedAt != nil ? $0.course : nil })
    }

    /// Whether the ledger already holds any row that came from a feed
    /// (Canvas, Modules, Gradescope, announcements), aged, gone, finished or
    /// completion-only included. Read-only. This is the "is this an existing
    /// install?" question the sign-up backlog asks once, at launch, before
    /// anything in that launch has dashboarded a feed
    /// (`SignupBacklogStore.recordExistingInstallIfUndecided`).
    ///
    /// It deliberately counts *every* feed-sourced row, including the hidden
    /// completion-only ones: an install that has ever recorded a completion for
    /// feed work is not a new student, and the cost of mistaking an existing
    /// install for a new one (work they could see yesterday vanishes after an
    /// update) is far worse than the cost of the opposite mistake (a new student
    /// sees the old backlog, which is what every student saw before this rule).
    ///
    /// `ignoring` is for ids that are known not to be real: the preview mode's
    /// sample rows. Preview does not write the ledger today (the dashboard never
    /// forwards a sample item's completion to `AppState`), but "a student who
    /// previewed first is still a new student" must not depend on that staying
    /// true.
    ///
    /// **Nil means the ledger could not be read.** Answering `false` there says
    /// "this is a new student", which is the one conclusion the backlog rule
    /// must not draw from a failure: a student whose ledger is merely locked
    /// for a moment would then be classed as new when their first feed arrives,
    /// and their older work hidden. The caller leaves the decision for a launch
    /// that can read (`AppState.recordSignupBacklogForExistingInstallIfNeeded`).
    public func holdsFeedRows(ignoring ignoredIDs: Set<String> = []) -> Bool? {
        guard let rows = try? allRows() else { return nil }
        return rows.contains { row in
            guard let source = Assignment.Source(rawValue: row.sourceRaw),
                  SignupBacklog.isFeedSource(source)
            else { return false }
            return !ignoredIDs.contains(row.id)
        }
    }

    // MARK: Test/diagnostic access

    /// Total rows on the ledger (including aged/gone), for tests and diagnostics.
    public func rowCount() -> Int { ((try? allRows()) ?? []).count }

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
        /// The read-side counterpart: the most recent failed fetch this
        /// session, and the running count (`AssignmentStore.failedReadCount`).
        public let lastReadError: String?
        public let failedReadCount: Int

        /// True only when the ledger is on disk, its writes are landing *and*
        /// it can be read. Settings should key off this rather than
        /// `isPersistent` alone.
        public var isHealthy: Bool {
            isPersistent && storageFailureReason == nil && failedSaveCount == 0 && failedReadCount == 0
        }
        public let total: Int
        public let canvas: Int
        public let gradescope: Int
        /// Retained but no longer published by the source feed.
        public let goneFromFeed: Int
        /// Ticked off, or reported submitted by either platform — the rows that
        /// are now exempt from aging.
        public let finished: Int
        /// Rows a semester rollover has filed away. Worth its own number
        /// because an archived row is retained forever (it is exempt from
        /// aging), so this is the one count that explains a ledger that keeps
        /// growing while the dashboard stays short.
        public let archived: Int
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
        let rows = ((try? allRows()) ?? []).filter { !$0.isCompletionOnly }
        return LedgerStats(
            isPersistent: isPersistent,
            storageFailureReason: storageFailureReason,
            lastSaveError: lastSaveError,
            failedSaveCount: failedSaveCount,
            lastReadError: lastReadError,
            failedReadCount: failedReadCount,
            total: rows.count,
            canvas: rows.filter { $0.sourceRaw == Assignment.Source.canvas.rawValue }.count,
            gradescope: rows.filter { $0.sourceRaw == Assignment.Source.gradescope.rawValue }.count,
            goneFromFeed: rows.filter(\.isGoneFromFeed).count,
            finished: rows.filter(\.isFinished).count,
            archived: rows.filter(\.isArchived).count,
            withScores: rows.filter { $0.scoreEarned != nil }.count,
            duplicateIDs: rows.count - Set(rows.map(\.id)).count,
            earliestFirstSeen: rows.map(\.firstSeen).min(),
            latestSeenInFeed: rows.map(\.lastSeenInFeed).max()
        )
    }
}
