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
/// "No snapshot" means no file, or one that does not decode, and nothing else.
/// A snapshot the app published with zero items is the dashboard's answer (the
/// student is caught up, or the first-sync hold is withholding unverified
/// work), and `WidgetSnapshotStore.current` trusts it. Falling back to this
/// reader for an empty one is how the widget came to list rows the dashboard
/// hides.
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
    /// `defaults` is where the user's preferences are read from; it is a
    /// parameter so a test can supply a scratch suite instead of the shared one
    /// (a decision written to the shared domain would be read by every
    /// `AppState` in every concurrently running suite).
    static func snapshot(
        storeURL url: URL,
        now: Date = Date(),
        defaults: UserDefaults = .lhf
    ) -> WidgetSnapshot? {
        // Don't let SwiftData create an empty store from inside the extension —
        // if the app has never run, there is simply nothing to show.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // cloudKitDatabase pinned to .none: this is a read of the store file,
        // never a second mirroring party. The widget's entitlements carry no
        // iCloud container today, so .automatic happens to resolve to nothing —
        // but "happens to" is exactly what the pin replaces with "by
        // construction" (see AssignmentStore's local inits).
        //
        // Opened through `LedgerContainer`, the same versioned schema and
        // migration plan the app uses (`AssignmentStore.makeContainer`), not an
        // anonymous `StoredAssignment` container. The widget used to ask for
        // the unversioned model, which is fine with one schema version and
        // breaks the day there are two.
        //
        // `allowMigration: false`: the widget never migrates. After an update
        // the system may run it before the app has been opened; a store still
        // at the older schema is then not this process's to rewrite (the app
        // takes the pre-migration copy and migrates on its first launch), so
        // the door throws and the widget shows its snapshot or nothing.
        guard let container = try? LedgerContainer.make(
            ModelConfiguration(url: url, cloudKitDatabase: .none),
            allowMigration: false
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
        let hidden = Set(defaults.stringArray(forKey: SharedDefaults.hiddenCoursesKey) ?? [])
        let deleted = Set(defaults.stringArray(forKey: SharedDefaults.deletedCoursesKey) ?? [])
        let nameOverrides = defaults
            .dictionary(forKey: SharedDefaults.courseNameOverridesKey) as? [String: String] ?? [:]
        // The sign-up backlog (`SignupBacklog`): the dashboard hides unfinished
        // feed work that was already more than a week overdue when the student
        // signed up, so this fallback must too, or the widget advertises exactly
        // the items the dashboard is hiding. nil when nothing is hidden for this
        // install (undecided, an existing install, or the student chose to see
        // everything), which is also what an absent key reads as.
        let backlog = SignupBacklogStore(defaults: defaults).activeBacklog

        // A plain loop rather than the filter chain this used to be: the
        // merged chain grew to nine links and the Swift 6 type-checker gave
        // up on it ("unable to type-check this expression in reasonable
        // time"). Same predicates, same order, explicit types throughout.
        var candidates: [(id: String, due: Date, item: WidgetItem)] = []
        for row in rows {
            // Completion-only rows are bookkeeping, not assignments: they carry
            // no trustworthy title or due date and must never reach the widget.
            if row.isCompletionOnly { continue }
            if row.isFinished { continue }
            // Work the student put away in a semester rollover. The app drops it
            // from the dashboard and from reminders; a widget still counting
            // down to last April's problem set would be the same bug wearing a
            // home screen. Read straight off the row rather than out of the
            // shared suite, because unlike hiding and deletion this fact is
            // per-item, not per-course — see `StoredAssignment.archivedTerm`.
            if row.isArchived { continue }
            if let backlog,
               let source = Assignment.Source(rawValue: row.sourceRaw),
               backlog.hides(source: source, dueAt: row.dueAt, isFinished: row.isFinished) {
                continue
            }
            if isAgedOut(row, now: now) { continue }
            // An announcement row flagged gone is a task whose post Canvas
            // stopped returning: the dashboard hides it, so the widget does too.
            // Aging no longer removes such a row (it is exempt, see
            // `AssignmentStore.isAgedOut`), so without this line it would sit in
            // the widget for good.
            if row.sourceRaw == Assignment.Source.canvasAnnouncement.rawValue, row.isGoneFromFeed { continue }
            // `.event` rows (readings, lectures, exam dates) have nothing to
            // submit, so they never go "overdue" — mirrors AppState's
            // isExpired: they drop off the moment their due time passes,
            // not at the end of their calendar day. The same goes for the
            // Announcement Watcher's and Ed pass's finds (2026-10-19): guesses
            // from prose, never debt. For those this is the dated half of
            // `AppState.isHiddenAnnouncementTask`, which is the one rule the
            // app itself applies; see `isExpired` below for why the rest of it
            // is not here.
            if isExpired(row, now: now) { continue }
            if !seenIDs.insert(row.id).inserted { continue }
            if hidden.contains(row.course) || deleted.contains(row.course) { continue }
            guard let due = row.dueAt else { continue }
            let display = nameOverrides[row.course]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let course = (display?.isEmpty == false) ? display! : row.course
            candidates.append((row.id, due, WidgetItem(title: row.title, course: course, dueAt: due)))
        }

        let items: [WidgetItem] = candidates
            .sorted { lhs, rhs in
                lhs.due == rhs.due ? lhs.id < rhs.id : lhs.due < rhs.due
            }
            .prefix(maxItems)
            .map(\.item)

        guard !items.isEmpty else { return nil }
        return WidgetSnapshot(items: items, generatedAt: now)
    }

    /// Mirrors `AssignmentStore.isAgedOut` — kept here rather than shared
    /// because that one is main-actor-isolated. Both must stay in step; the
    /// rule is "finished or archived work never ages, announcement rows never
    /// age, otherwise gone + long overdue does". The archived clause is
    /// redundant here — the filter chain above already dropped those rows — and
    /// is kept anyway so the two copies of this predicate remain literally the
    /// same rule, which is the only property that makes duplicating it
    /// survivable.
    private static func isAgedOut(_ row: StoredAssignment, now: Date) -> Bool {
        guard !row.isFinished, !row.isArchived else { return false }
        guard row.sourceRaw != Assignment.Source.canvasAnnouncement.rawValue else { return false }
        guard row.isGoneFromFeed, let due = row.dueAt else { return false }
        return due < now.addingTimeInterval(-AssignmentStore.goneGracePeriod)
    }

    /// A row drops off the moment its due time passes (`due < now`), not at
    /// the end of its calendar day, when it is
    ///
    /// 1. an `.event`-kind row, mirroring `AppState.isExpired`: the widget
    ///    must not keep advertising a class that already started just because
    ///    midnight hasn't arrived yet; or
    /// 2. an announcement find (`sourceRaw` is `canvasAnnouncement`, which Ed
    ///    finds carry too): extracted from prose, so a passed one is noise,
    ///    not overdue work (the owner's rule, 2026-10-19). In the app this is
    ///    `AppState.isHiddenAnnouncementTask`, which also judges same-day
    ///    reminders and undated tasks by the post's date. The widget has no
    ///    post dates (a separate process reading the ledger), so it keeps only
    ///    that rule's dated half, and the published snapshot, which the app
    ///    builds with the whole rule, wins whenever there is one.
    ///
    /// Undated rows are never expired. Display only: the ledger row stays, and
    /// the wrong fix would be deleting or completing it. This copy exists
    /// because `AppState`'s are main-actor-isolated and the widget cannot call
    /// them.
    private static func isExpired(_ row: StoredAssignment, now: Date) -> Bool {
        let isEvent = row.kindRaw == Assignment.Kind.event.rawValue
        let isAnnouncementFind = row.sourceRaw == Assignment.Source.canvasAnnouncement.rawValue
        guard isEvent || isAnnouncementFind, let due = row.dueAt else { return false }
        return due < now
    }
}
