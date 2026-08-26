import Foundation
import SwiftData

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
    public init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        self.container = try ModelContainer(for: StoredGradeObservation.self, configurations: config)
        self.isPersistent = !inMemory
    }

    public init(url: URL) throws {
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        self.container = try ModelContainer(for: StoredGradeObservation.self, configurations: config)
        self.isPersistent = true
    }

    /// The store the real app uses. Same posture as `AssignmentStore.makeDefault`:
    /// App Group file when entitled, hermetic in-memory otherwise (tests,
    /// previews), nil only if even that fails — in which case grade history
    /// degrades to session-only rather than crashing the app.
    public static func makeDefault() -> GradeHistoryStore? {
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let url = groupURL.appending(path: "GradeHistory.store")
            if let store = try? GradeHistoryStore(url: url) { return store }
        }
        return try? GradeHistoryStore(inMemory: true)
    }

    // MARK: Reading

    /// Every course's history, oldest first — the shape `GradeWatcherStore`
    /// publishes and `weekDelta` reads.
    public func allHistory() -> [String: [Observation]] {
        var byCourse: [String: [Observation]] = [:]
        for row in allRows() {
            byCourse[row.courseID, default: []].append(
                Observation(date: row.observedAt, percent: row.percent)
            )
        }
        return byCourse.mapValues { $0.sorted { $0.date < $1.date } }
    }

    /// One course's history, oldest first.
    public func history(courseID: String) -> [Observation] {
        rows(courseID: courseID)
            .map { Observation(date: $0.observedAt, percent: $0.percent) }
            .sorted { $0.date < $1.date }
    }

    // MARK: Writing

    /// Records `percent` as today's reading for `courseID`, replacing an earlier
    /// reading from the same calendar day and pruning to `retentionPerCourse`.
    public func record(courseID: String, percent: Double, now: Date = Date()) {
        let existing = rows(courseID: courseID)
        let calendar = Calendar.current
        if let today = existing.first(where: { calendar.isDate($0.observedAt, inSameDayAs: now) }) {
            today.observedAt = now
            today.percent = percent
        } else {
            context.insert(StoredGradeObservation(courseID: courseID, observedAt: now, percent: percent))
        }
        prune(courseID: courseID)
        try? context.save()
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
        var imported = 0
        for (courseID, observations) in history {
            guard !observations.isEmpty, rows(courseID: courseID).isEmpty else { continue }
            for observation in Self.collapsedByDay(observations).suffix(Self.retentionPerCourse) {
                context.insert(StoredGradeObservation(
                    courseID: courseID,
                    observedAt: observation.date,
                    percent: observation.percent
                ))
                imported += 1
            }
        }
        if imported > 0 { try? context.save() }
        return imported
    }

    /// Drops every observation. Called when the user disconnects Canvas —
    /// grades are downstream of that session, so a signed-out student's
    /// observed grades must not stay on disk.
    public func clearAll() {
        for row in allRows() { context.delete(row) }
        try? context.save()
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

    private func prune(courseID: String) {
        let rows = rows(courseID: courseID).sorted { $0.observedAt < $1.observedAt }
        guard rows.count > Self.retentionPerCourse else { return }
        for row in rows.prefix(rows.count - Self.retentionPerCourse) { context.delete(row) }
    }

    private func rows(courseID: String) -> [StoredGradeObservation] {
        let descriptor = FetchDescriptor<StoredGradeObservation>(
            predicate: #Predicate { $0.courseID == courseID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func allRows() -> [StoredGradeObservation] {
        (try? context.fetch(FetchDescriptor<StoredGradeObservation>())) ?? []
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
        let rows = allRows()
        return HistoryStats(
            isPersistent: isPersistent,
            courses: Set(rows.map(\.courseID)).count,
            observations: rows.count,
            earliest: rows.map(\.observedAt).min(),
            latest: rows.map(\.observedAt).max()
        )
    }
}
