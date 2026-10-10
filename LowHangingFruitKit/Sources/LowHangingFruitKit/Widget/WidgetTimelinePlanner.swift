import Foundation

/// One moment in the widget's timeline: the date WidgetKit should show it at,
/// and the snapshot it shows then.
public struct WidgetTimelineStep: Hashable, Sendable {
    public let date: Date
    public let snapshot: WidgetSnapshot

    public init(date: Date, snapshot: WidgetSnapshot) {
        self.date = date
        self.snapshot = snapshot
    }
}

/// Schedules the widget's timeline entries so it re-renders at the moment an
/// item's due time passes, without waiting for the app or the reload.
///
/// **What this fixes.** The provider used to hand WidgetKit one entry, and the
/// extension only runs again on its 30-minute reload, on WidgetKit's own
/// budget, or when the app republishes. An item whose due time passed in
/// between kept the look it was rendered with (its colour band frozen, its
/// relative date counting up from zero as if it were still coming) until
/// something happened to run the extension or the app.
///
/// **The rule.** The first entry is at `now`; every later entry is at the next
/// distinct upcoming due time, `maxEntries` in all. **Every entry carries the
/// snapshot's items unchanged, in the app's order.** The entries differ only
/// in their dates: a date is a promise that WidgetKit renders the widget again
/// then, which is the moment an item turns overdue. With nothing dropped, the
/// entries are identical in content, and that is intended. The dates are the
/// whole job.
///
/// **Dropping past-due items was tried and rejected.** The first version of
/// this planner omitted, from each entry, the items whose due time had
/// arrived, so the widget "moved on" by itself. It also dropped work that was
/// already overdue when the app published, which the dashboard's todo list
/// leads with, so a student whose only open work was overdue saw the widget's
/// empty state ("all clear"). Overdue work is the work most worth a glance,
/// and the widget's overdue styling (`WidgetUrgency.overdue`) exists for it.
/// Do not reintroduce a filter on due time here. If the widget should ever
/// stop listing something, that is a decision for the app's snapshot
/// (`AppState.widgetNextDueItems`), which sees the same lists as the
/// dashboard, not for a clock check in the extension.
///
/// **A limit to know about.** The views derive their urgency band and relative
/// text from `Date()` at render time, not from the entry's date. An entry
/// guarantees a render near its date, not that the band is computed for
/// exactly that instant; passing `entry.date` into `WidgetUrgency(due:now:)`
/// would make it exact, and has not been done.
///
/// **Why the entries are bounded.** `maxEntries` is a handful, not one per
/// item for the term: the provider reloads in 30 minutes and re-reads the
/// snapshot anyway, so the later entries are only a net under a reload
/// WidgetKit throttles or delays, and the sooner ones are the ones that matter.
///
/// Pure on purpose: no clock, no container, no ledger. The widget target is
/// not compiled by `swift build`, so everything that can be decided without
/// WidgetKit lives here where `swift test` reaches it.
public enum WidgetTimelinePlanner {
    /// The most entries one timeline carries, the first included.
    public static let maxEntries = 5

    /// The timeline: an entry at `now`, then one at each of the next distinct
    /// due times, up to `maxEntries` in all. Never empty, and dates ascend, so
    /// it can be handed to `Timeline` as is. Each entry's snapshot is the one
    /// given, untouched.
    public static func steps(
        for snapshot: WidgetSnapshot,
        now: Date,
        maxEntries: Int = WidgetTimelinePlanner.maxEntries
    ) -> [WidgetTimelineStep] {
        let upcoming = Set(snapshot.items.compactMap(\.dueAt).filter { $0 > now }).sorted()
        let later = upcoming.prefix(max(1, maxEntries) - 1)
        return ([now] + later).map { WidgetTimelineStep(date: $0, snapshot: snapshot) }
    }
}
