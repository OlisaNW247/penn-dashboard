import Foundation
import SwiftData

/// The widget's fallback source: "next due" read straight from the durable
/// ledger in the shared App Group container, used when the app hasn't written a
/// `WidgetSnapshot` yet.
///
/// **Why this is a fallback and not the widget's primary path.** The dashboard's
/// list is not the ledger — it's the output of `rebuildDashboardItems()`, which
/// also applies Canvas/Gradescope dedup and the end-of-term cap. That lives in
/// `LowHangingFruitUI`, which a widget extension cannot import, so reading rows
/// directly as the *normal* path could still show a duplicate the app would
/// have merged.
///
/// Course selection and custom names are no longer part of that gap: they move
/// through `SharedDefaults`, which lives in this module precisely so the widget
/// can read them. A class the user hid, deleted, or renamed in the app is
/// honoured here.
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

        // Same versioned schema and migration plan the app writes with. Opening
        // the store under an anonymous schema is how a reader and a writer end
        // up disagreeing about what is on disk.
        guard let container = try? ModelContainer(
            for: Schema(versionedSchema: LedgerSchemaV1.self),
            migrationPlan: LedgerMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        ) else { return nil }

        let context = ModelContext(container)
        guard let rows = try? context.fetch(FetchDescriptor<StoredAssignment>()) else { return nil }

        // One entry per assignment id. `AssignmentStore` keeps the ledger free of
        // duplicates in code (the database stopped enforcing it when
        // `@Attribute(.unique)` came off for CloudKit's sake), but that sweep
        // needs to write and a widget extension only reads — so if a duplicate
        // is sitting there between app launches, this is what stops a five-item
        // list showing the same homework twice.
        var seenIDs: Set<String> = []

        // The user's own decisions about their classes, read from the shared
        // suite. Without these the widget cheerfully advertised a class the
        // user had hidden or deleted, under the raw Canvas name they had
        // already renamed.
        let hidden = Set(UserDefaults.lhf.stringArray(forKey: SharedDefaults.hiddenCoursesKey) ?? [])
        let deleted = Set(UserDefaults.lhf.stringArray(forKey: SharedDefaults.deletedCoursesKey) ?? [])
        let nameOverrides = UserDefaults.lhf
            .dictionary(forKey: SharedDefaults.courseNameOverridesKey) as? [String: String] ?? [:]

        let items = rows
            // Completion-only rows are bookkeeping, not assignments: they carry
            // no trustworthy title or due date and must never reach the widget.
            .filter { !$0.isCompletionOnly }
            .filter { !$0.isFinished }
            // Work the student put away in a semester rollover. The app drops it
            // from the dashboard and from reminders; a widget still counting
            // down to last April's problem set would be the same bug wearing a
            // home screen. Read straight off the row rather than out of the
            // shared suite, because unlike hiding and deletion this fact is
            // per-item, not per-course — see `StoredAssignment.archivedTerm`.
            .filter { !$0.isArchived }
            .filter { !isAgedOut($0, now: now) }
            .filter { seenIDs.insert($0.id).inserted }
            .filter { !hidden.contains($0.course) && !deleted.contains($0.course) }
            .compactMap { row -> (Date, WidgetItem)? in
                guard let due = row.dueAt else { return nil }
                let display = nameOverrides[row.course]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let course = (display?.isEmpty == false) ? display! : row.course
                return (due, WidgetItem(title: row.title, course: course, dueAt: due))
            }
            .sorted { $0.0 < $1.0 }
            .prefix(maxItems)
            .map(\.1)

        guard !items.isEmpty else { return nil }
        return WidgetSnapshot(items: Array(items), generatedAt: now)
    }

    /// Mirrors `AssignmentStore.isAgedOut` — kept here rather than shared
    /// because that one is main-actor-isolated. Both must stay in step; the
    /// rule is "finished or archived work never ages, otherwise gone + long
    /// overdue does". The archived clause is redundant here — the filter chain
    /// above already dropped those rows — and is kept anyway so the two copies
    /// of this predicate remain literally the same rule, which is the only
    /// property that makes duplicating it survivable.
    private static func isAgedOut(_ row: StoredAssignment, now: Date) -> Bool {
        guard !row.isFinished, !row.isArchived else { return false }
        guard row.isGoneFromFeed, let due = row.dueAt else { return false }
        return due < now.addingTimeInterval(-AssignmentStore.goneGracePeriod)
    }
}
