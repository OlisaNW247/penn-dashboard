import Foundation
import SwiftData

/// The widget's fallback source: "next due" read straight from the durable
/// ledger in the shared App Group container, used when the app hasn't written a
/// `WidgetSnapshot` yet.
///
/// **Why this is a fallback and not the widget's primary path.** The dashboard's
/// list is not the ledger — it's the output of `rebuildDashboardItems()`, which
/// also applies hidden/deleted course selection, Canvas/Gradescope dedup, the
/// end-of-term cap, and folds in manual assignments and recurring tasks that
/// have no ledger rows at all. All of that lives in `LowHangingFruitUI`, which a
/// widget extension cannot import. Reading rows directly as the *normal* path
/// would therefore show duplicates and hidden classes while dropping the user's
/// own tasks — strictly worse than the snapshot.
///
/// What it fixes is the gap the snapshot genuinely has: on a fresh install, or
/// after the container is cleared, there is no snapshot and the widget sits
/// empty until the app is next opened. The ledger already holds real
/// assignments at that point, so showing them beats showing nothing.
///
/// Only ledger-derivable filters are applied here, and every one of them is
/// conservative: an item must be unfinished, still dated, and not aged out.
public enum LedgerWidgetReader {
    /// How many items the widget ever needs — matches the app's own snapshot cap.
    public static let maxItems = 5

    /// Reads the ledger and derives a "next due" snapshot, or nil when the App
    /// Group container is unavailable, the store doesn't exist yet, or it holds
    /// nothing showable.
    ///
    /// `nonisolated` on purpose: `TimelineProvider` callbacks are not
    /// main-actor, and `AssignmentStore` is. This opens its own short-lived
    /// context rather than hopping actors inside a widget's execution window.
    public static func snapshot(now: Date = Date()) -> WidgetSnapshot? {
        guard let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSharing.appGroupID)
        else { return nil }
        return snapshot(storeURL: groupURL.appending(path: "Assignments.store"), now: now)
    }

    /// Testable seam: the same derivation against an explicit store file, so the
    /// filtering rules are exercised without an App Group entitlement.
    static func snapshot(storeURL url: URL, now: Date = Date()) -> WidgetSnapshot? {
        // Don't let SwiftData create an empty store from inside the extension —
        // if the app has never run, there is simply nothing to show.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let container = try? ModelContainer(
            for: StoredAssignment.self,
            configurations: ModelConfiguration(url: url)
        ) else { return nil }

        let context = ModelContext(container)
        guard let rows = try? context.fetch(FetchDescriptor<StoredAssignment>()) else { return nil }

        let items = rows
            .filter { !$0.isFinished }
            .filter { !isAgedOut($0, now: now) }
            .compactMap { row -> (Date, WidgetItem)? in
                guard let due = row.dueAt else { return nil }
                return (due, WidgetItem(title: row.title, course: row.course, dueAt: due))
            }
            .sorted { $0.0 < $1.0 }
            .prefix(maxItems)
            .map(\.1)

        guard !items.isEmpty else { return nil }
        return WidgetSnapshot(items: Array(items), generatedAt: now)
    }

    /// Mirrors `AssignmentStore.isAgedOut` — kept here rather than shared
    /// because that one is main-actor-isolated. Both must stay in step; the
    /// rule is "finished work never ages, otherwise gone + long overdue does".
    private static func isAgedOut(_ row: StoredAssignment, now: Date) -> Bool {
        guard !row.isFinished else { return false }
        guard row.isGoneFromFeed, let due = row.dueAt else { return false }
        return due < now.addingTimeInterval(-AssignmentStore.goneGracePeriod)
    }
}
