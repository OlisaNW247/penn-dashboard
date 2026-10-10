import WidgetKit
import SwiftUI
import LowHangingFruitKit

struct NextDueEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Feeds the widget from the snapshot the app last wrote to the shared App
/// Group container (see `WidgetSnapshotStore`). There's no push channel from
/// the app to the extension, so we just re-read on a timer and let
/// `AppState.publishWidgetSnapshot`'s `WidgetCenter.reloadAllTimelines()`
/// call trigger an earlier refresh whenever the dashboard actually changes.
struct NextDueProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextDueEntry {
        NextDueEntry(date: Date(), snapshot: Self.sampleSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextDueEntry) -> Void) {
        // The widget gallery preview has no App Group data to read yet, so it
        // gets the sample; a real placement on the Home/Lock Screen always
        // reflects the actual snapshot (or empty, never fake data).
        let now = Date()
        let snapshot: WidgetSnapshot
        if context.isPreview {
            snapshot = WidgetSnapshotStore.read() ?? Self.sampleSnapshot
        } else {
            snapshot = WidgetSnapshotStore.current(now: now)
        }
        completion(NextDueEntry(date: now, snapshot: snapshot))
    }

    /// One entry now, then one at each of the next few due times. Every entry
    /// carries the same items (overdue work stays on the widget); the extra
    /// dates only make WidgetKit render again when an item turns overdue,
    /// instead of leaving it as it looked until the next reload. Both decisions
    /// live in the Kit, where `swift test` reaches them: which snapshot to trust
    /// is `WidgetSnapshotStore.current` (the app's published snapshot, even when
    /// it is empty; the ledger only when the app has published nothing), and
    /// the entry dates are `WidgetTimelinePlanner`.
    ///
    /// Due-date countdowns render live via `Text(_:style:)`, so the entries
    /// only need refreshing periodically to pick up new data: WidgetKit's own
    /// budget, plus the app's explicit reload on every dashboard rebuild, keep
    /// this from ever going far out of date.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextDueEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.current(now: now)
        let entries = WidgetTimelinePlanner.steps(for: snapshot, now: now).map {
            NextDueEntry(date: $0.date, snapshot: $0.snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    private static var sampleSnapshot: WidgetSnapshot {
        WidgetSnapshot(
            items: [
                WidgetItem(title: "Problem Set 6", course: "CIS 1200", dueAt: Date().addingTimeInterval(3 * 3600)),
                WidgetItem(title: "Reading Response", course: "ENGL 0400", dueAt: Date().addingTimeInterval(2 * 86_400)),
                WidgetItem(title: "Lab 4", course: "PHYS 0150", dueAt: Date().addingTimeInterval(5 * 86_400)),
            ],
            generatedAt: Date()
        )
    }
}

struct NextDueWidget: Widget {
    let kind: String = "NextDueWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextDueProvider()) { entry in
            NextDueEntryView(entry: entry)
        }
        .configurationDisplayName("Next Due")
        .description("next due")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryInline,
            .accessoryRectangular,
            .accessoryCircular,
        ])
    }
}
