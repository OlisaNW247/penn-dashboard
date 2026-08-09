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
    public static let appGroupID = "group.com.lhf.lowhangingfruit"

    /// How long a gone-from-feed item is kept visible past its due date before it
    /// ages out. Generous on purpose: the design brief says a lingering
    /// already-removed item is far better than losing real work. Undated items
    /// and anything still in the feed never age out at all.
    public static let goneGracePeriod: TimeInterval = 14 * 86_400

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

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

    public init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        self.container = try ModelContainer(for: StoredAssignment.self, configurations: config)
    }

    public init(url: URL) throws {
        let config = ModelConfiguration(url: url)
        self.container = try ModelContainer(for: StoredAssignment.self, configurations: config)
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
        if let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let url = groupURL.appending(path: "Assignments.store")
            if let store = try? AssignmentStore(url: url) { return store }
        }
        return try? AssignmentStore(inMemory: true)
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
        try? context.save()

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
        try? context.save()
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
    private func isAgedOut(_ row: StoredAssignment, now: Date) -> Bool {
        guard row.isGoneFromFeed, let due = row.dueAt else { return false }
        return due < now.addingTimeInterval(-Self.goneGracePeriod)
    }

    // MARK: Test/diagnostic access

    /// Total rows on the ledger (including aged/gone), for tests and diagnostics.
    public func rowCount() -> Int { allRows().count }
}
