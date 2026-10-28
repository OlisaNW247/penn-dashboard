import Foundation
import SwiftData

/// Versioned schema for the grade-history store, the twin of `LedgerSchemaV1`.
///
/// `GradeHistory.store` was opened with a bare `ModelContainer(for:)`, which
/// pins the file to an anonymous, unversioned schema. That works until a field
/// is added, and then the open throws, `makeDefault()` falls back to memory,
/// and the week-delta chip loses its baseline with nothing to say why. Declaring
/// the schema makes the next change a migration instead.
///
/// 1.0.0 is the version SwiftData gives an unversioned schema, so the file every
/// shipped build wrote is adopted in place rather than treated as incompatible
/// (`GradeHistoryStoreHealthTests` opens one written the old way). A store
/// created from here on is stamped with this version.
enum GradeHistorySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] { [StoredGradeObservation.self] }
}

/// Every grade-history schema version the app has shipped. Empty `stages`
/// because V1 is the first; wired into every container so a future version only
/// has to append (see `LedgerMigrationPlan`).
enum GradeHistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [GradeHistorySchemaV1.self] }

    static var stages: [MigrationStage] { [] }
}

/// Durable home for observed grade history — the trail of `(day, percent)`
/// readings behind the week-delta chip (docs/grades.md §11).
///
/// This used to be a single `gradeWatcherHistory` JSON blob in UserDefaults: a
/// dictionary of arrays, rewritten whole on every refresh, opaque to anything
/// that wanted to inspect or sync it. It is now `StoredGradeObservation` rows,
/// which is what lets it survive a reinstall through the App Group container
/// and, later, ride an iCloud sync alongside the assignment ledger.
///
/// **Why its own store file rather than the assignment ledger's.** The widget
/// extension opens `Assignments.store` with a container declaring exactly one
/// entity (`LedgerWidgetReader`). Adding a second entity to that container from
/// the app side would leave the two processes disagreeing about the schema of
/// the same file. Grade history is of no use to the widget, so it gets its own
/// file in the same App Group directory and the widget's read stays trivially
/// safe.
///
/// Retention matches what the UserDefaults version did, because the week delta
/// depends on it: **one entry per course per calendar day, most recent 180
/// kept.** A day's second refresh overwrites that day's row rather than
/// appending, so a student who pulls-to-refresh ten times doesn't flood the
/// history and shift the ~7-days-back baseline onto this morning.
@MainActor
public final class GradeHistoryStore {
    /// Shared App Group container id — the same one the assignment ledger uses.
    public static let appGroupID = AssignmentStore.appGroupID

    /// How many daily observations are kept per course (~6 months of a term).
    public static let retentionPerCourse = 180

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// False when this is the in-memory fallback and nothing is surviving a
    /// relaunch — mirrors `AssignmentStore.isPersistent`.
    public let isPersistent: Bool

    /// Why history is running in memory when the on-disk file could not be
    /// used. Nil on a store that opened on disk, and on the deliberate
    /// in-memory path (tests and previews), which is not a failure. Before
    /// this, `makeDefault()` swallowed the error and the fallback looked
    /// exactly like a store that works (hardening plan 2026-10-25, B9: DAT-08).
    public let storageFailureReason: String?

    /// The most recent failed write and fetch, and how many failed this
    /// session: the same two pairs `AssignmentStore` keeps, for the same
    /// reason. `isPersistent` says only that the file opened; a full disk fails
    /// every save while the store still reports itself persistent. These feed
    /// `StorageHealth.Failures`.
    public private(set) var lastSaveError: String?
    public private(set) var failedSaveCount: Int = 0
    public private(set) var lastReadError: String?
    public private(set) var failedReadCount: Int = 0

    /// Test seams, as on `AssignmentStore`: while set, every fetch (or every
    /// save that has something to save) fails with this. Never set outside
    /// tests.
    var readFailureForTesting: (any Error)?
    var saveFailureForTesting: (any Error)?

    /// One observed reading. Mirrors the shape `GradeWatcherStore` published
    /// before this store existed, so its callers and its `weekDelta` maths are
    /// unchanged by the move.
    public struct Observation: Sendable, Hashable, Codable {
        public let date: Date
        public let percent: Double

        public init(date: Date, percent: Double) {
            self.date = date
            self.percent = percent
        }
    }

    // MARK: Construction

    // cloudKitDatabase is pinned to .none on both inits below for the same
    // reason as AssignmentStore's local paths: the parameter defaults to
    // .automatic, which adopts the first iCloud container in the app's
    // entitlements — and the app now carries one (Tier 2). Without the pin,
    // grade history would silently mirror to CloudKit for every user, sync
    // toggle or not. When grade history is meant to ride the iCloud sync
    // (the "later" this type's doc mentions), that gets its own opt-in
    // cloud init, like AssignmentStore.init(cloudKitGroupURL:).
    /// Every container goes through the versioned schema and the migration
    /// plan, as the ledger's do (`LedgerSchema.swift`).
    private static func makeContainer(_ config: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: GradeHistorySchemaV1.self),
            migrationPlan: GradeHistoryMigrationPlan.self,
            configurations: config
        )
    }

    /// - Parameter storageFailureReason: Non-nil only for the fallback
    ///   `makeDefault()` builds after the file could not be used.
    public init(inMemory: Bool = false, storageFailureReason: String? = nil) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        self.container = try Self.makeContainer(config)
        self.isPersistent = !inMemory
        self.storageFailureReason = inMemory ? storageFailureReason : nil
    }

    public init(url: URL) throws {
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        self.container = try Self.makeContainer(config)
        self.isPersistent = true
        self.storageFailureReason = nil
    }

    /// The store the real app uses. Same posture as `AssignmentStore.makeDefault`:
    /// App Group file when entitled, hermetic in-memory otherwise (tests,
    /// previews), nil only if even that fails — in which case grade history
    /// degrades to session-only rather than crashing the app.
    public static func makeDefault() -> GradeHistoryStore? {
        // The fourth choke point. `SharedDefaults.isTestRunner` guards
        // `AssignmentStore`, the shared defaults and the widget snapshot for the
        // reason documented there — an unsandboxed macOS test run resolves the
        // App Group container with no entitlement — but this store was added
        // later and never picked the guard up, so `swift test` opened the real
        // Mac app's GradeHistory.store on every run. It currently fails closed
        // (the sandbox denies the read, and the run is merely buried in CoreData
        // errors); on a machine where the open succeeds, the suite reads and
        // writes a student's real grade history.
        if SharedDefaults.isTestRunner { return try? GradeHistoryStore(inMemory: true) }
        let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "GradeHistory.store")
        return openOrFallBack(at: url)
    }

    /// Opens the file store at `url`, or builds the in-memory fallback and says
    /// why. Falling back is right (losing the session's chip beats refusing to
    /// launch), but doing it silently is how a store that is not keeping
    /// anything looks exactly like one that is. A nil `url` is a missing App
    /// Group container. Separate from `makeDefault()` so a test can hand it a
    /// file that will not open.
    static func openOrFallBack(at url: URL?) -> GradeHistoryStore? {
        let failure: String
        if let url {
            do {
                return try GradeHistoryStore(url: url)
            } catch {
                failure = "Saved grade history couldn't be opened (\(error.localizedDescription)). "
                    + "This session is being kept in memory only."
            }
        } else {
            failure = "The app isn't entitled for its shared App Group container, "
                + "so grade history can't be saved to disk."
        }
        return try? GradeHistoryStore(inMemory: true, storageFailureReason: failure)
    }

    // MARK: Reading

    /// Every course's history, oldest first — the shape `GradeWatcherStore`
    /// publishes and `weekDelta` reads.
    ///
    /// A fetch that fails reads as no history, and is counted
    /// (`failedReadCount`); a caller that decides something from the answer
    /// uses the throwing reads below.
    public func allHistory() -> [String: [Observation]] {
        var byCourse: [String: [Observation]] = [:]
        for row in (try? allRows()) ?? [] {
            byCourse[row.courseID, default: []].append(
                Observation(date: row.observedAt, percent: row.percent)
            )
        }
        return byCourse.mapValues { $0.sorted { $0.date < $1.date } }
    }

    /// One course's history, oldest first.
    public func history(courseID: String) -> [Observation] {
        ((try? rows(courseID: courseID)) ?? [])
            .map { Observation(date: $0.observedAt, percent: $0.percent) }
            .sorted { $0.date < $1.date }
    }

    // MARK: Writing

    /// Records `percent` as today's reading for `courseID`, replacing an earlier
    /// reading from the same calendar day and pruning to `retentionPerCourse`.
    ///
    /// Returns whether the reading is on disk. A course whose existing rows
    /// cannot be read gets no new reading at all: without them there is no
    /// telling whether today already has one, and a second row for the day
    /// would break the one-per-day rule the week delta stands on. The next
    /// refresh records it.
    @discardableResult
    public func record(courseID: String, percent: Double, now: Date = Date()) -> Bool {
        guard let existing = try? rows(courseID: courseID) else { return false }
        let calendar = Calendar.current
        if let today = existing.first(where: { calendar.isDate($0.observedAt, inSameDayAs: now) }) {
            today.observedAt = now
            today.percent = percent
        } else {
            context.insert(StoredGradeObservation(courseID: courseID, observedAt: now, percent: percent))
        }
        prune(courseID: courseID)
        return saveChanges()
    }

    /// One-time import of the old `gradeWatcherHistory` UserDefaults blob.
    /// Returns how many observations were written.
    ///
    /// Skips any course the store already has rows for: a re-run must never
    /// resurrect readings that were legitimately cleared (a Canvas sign-out
    /// wipes history on purpose), nor duplicate ones already imported. Within a
    /// course the same one-per-day / most-recent-180 rules are applied to the
    /// incoming data, so a blob written by a buggy older build can't import
    /// history the live path would never have produced.
    @discardableResult
    public func importLegacyHistory(_ history: [String: [Observation]]) -> Int {
        importingLegacyHistory(history).imported
    }

    /// What an import did, for a caller that decides whether it is finished.
    public struct LegacyImportResult: Sendable, Equatable {
        /// Observations written.
        public let imported: Int
        /// Courses with something to import whose existing rows could not be
        /// read, so they were left alone. Not the courses skipped because the
        /// store already has their history, which is the guard working: these
        /// are courses the import has not yet been able to look at, and an
        /// import that skipped any is not done.
        public let unreadableCourses: Int
    }

    /// `importLegacyHistory`, reporting the courses it could not look at.
    ///
    /// A course whose rows cannot be read is skipped, not imported blind: the
    /// already-has-rows guard exists so a re-run cannot duplicate what is
    /// there, and it cannot be applied to a course that cannot be read. That is
    /// the right thing for this pass and a trap for the caller, who used to
    /// take "returned" for "finished" and record the migration as done, so the
    /// blob was never imported (`LegacyStateMigration` now leaves its version
    /// alone when `unreadableCourses` is not zero).
    public func importingLegacyHistory(_ history: [String: [Observation]]) -> LegacyImportResult {
        var imported = 0
        var unreadable = 0
        for (courseID, observations) in history {
            guard !observations.isEmpty else { continue }
            guard let existing = try? rows(courseID: courseID) else {
                unreadable += 1
                continue
            }
            guard existing.isEmpty else { continue }
            for observation in Self.collapsedByDay(observations).suffix(Self.retentionPerCourse) {
                context.insert(StoredGradeObservation(
                    courseID: courseID,
                    observedAt: observation.date,
                    percent: observation.percent
                ))
                imported += 1
            }
        }
        if imported > 0 { saveChanges() }
        return LegacyImportResult(imported: imported, unreadableCourses: unreadable)
    }

    /// Drops every observation. Called when the user disconnects Canvas —
    /// grades are downstream of that session, so a signed-out student's
    /// observed grades must not stay on disk.
    ///
    /// Returns whether the history is gone from disk: false when it could not
    /// be read (nothing was found to delete) or the save failed. A sign-out
    /// that did not clear grades is something the caller may want to know.
    @discardableResult
    public func clearAll() -> Bool {
        guard let rows = try? allRows() else { return false }
        for row in rows { context.delete(row) }
        return saveChanges()
    }

    // MARK: Internals

    /// Keeps the newest reading of each calendar day, oldest first — the same
    /// rule `record` enforces going forward, applied to imported data.
    private static func collapsedByDay(_ observations: [Observation]) -> [Observation] {
        let calendar = Calendar.current
        var byDay: [Date: Observation] = [:]
        for observation in observations {
            let day = calendar.startOfDay(for: observation.date)
            if let existing = byDay[day], existing.date >= observation.date { continue }
            byDay[day] = observation
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// Saves pending changes, keeping the failure instead of discarding it.
    /// Replaces the `try? context.save()` at each call site, where a failed
    /// write was indistinguishable from a successful one.
    @discardableResult
    private func saveChanges(_ operation: String = #function) -> Bool {
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

    private func prune(courseID: String) {
        let rows = ((try? rows(courseID: courseID)) ?? []).sorted { $0.observedAt < $1.observedAt }
        guard rows.count > Self.retentionPerCourse else { return }
        for row in rows.prefix(rows.count - Self.retentionPerCourse) { context.delete(row) }
    }

    private func rows(courseID: String) throws -> [StoredGradeObservation] {
        try fetch(FetchDescriptor<StoredGradeObservation>(
            predicate: #Predicate { $0.courseID == courseID }
        ))
    }

    private func allRows() throws -> [StoredGradeObservation] {
        try fetch(FetchDescriptor<StoredGradeObservation>())
    }

    /// The one place a fetch happens, so a failure is counted once whoever
    /// handles it. Throws; it used to return `[]`, and an unreadable history
    /// read as an empty one.
    private func fetch(
        _ descriptor: FetchDescriptor<StoredGradeObservation>,
        _ operation: String = #function
    ) throws -> [StoredGradeObservation] {
        do {
            if let injected = readFailureForTesting { throw injected }
            let rows = try context.fetch(descriptor)
            lastReadError = nil
            return rows
        } catch {
            failedReadCount += 1
            lastReadError = "\(operation) — \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: Diagnostics

    /// Rows held, and how far back they reach — the grade-history half of the
    /// Settings → Storage panel.
    public struct HistoryStats: Sendable, Equatable {
        public let isPersistent: Bool
        public let courses: Int
        public let observations: Int
        public let earliest: Date?
        public let latest: Date?
    }

    public func stats() -> HistoryStats {
        let rows = (try? allRows()) ?? []
        return HistoryStats(
            isPersistent: isPersistent,
            courses: Set(rows.map(\.courseID)).count,
            observations: rows.count,
            earliest: rows.map(\.observedAt).min(),
            latest: rows.map(\.observedAt).max()
        )
    }
}
