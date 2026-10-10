import Testing
import Foundation
@testable import LowHangingFruitKit

/// The widget's entry schedule. The extension only runs when WidgetKit says so,
/// so the timeline itself has to carry a render at the moment an item's due
/// time passes; these pin that rule where `swift test` can reach it, because
/// the widget target is not compiled by `swift build`.
///
/// The rule under test: entry dates are `now` plus each of the next distinct
/// upcoming due times, and **no entry drops anything**. Overdue work stays on
/// the widget, as it does on the dashboard's todo list. An earlier version
/// filtered past-due items out of each entry and hid overdue work; the tests
/// here exist so that does not come back.
struct WidgetTimelinePlannerTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ title: String, in minutes: Double?) -> WidgetItem {
        WidgetItem(
            title: title,
            course: "CIS 3200",
            dueAt: minutes.map { now.addingTimeInterval($0 * 60) }
        )
    }

    private func snapshot(_ items: [WidgetItem]) -> WidgetSnapshot {
        WidgetSnapshot(items: items, generatedAt: now.addingTimeInterval(-600))
    }

    @Test("the first entry is at now and keeps work that was already overdue when the app published")
    func firstEntryKeepsOverdue() {
        let steps = WidgetTimelinePlanner.steps(
            for: snapshot([item("Overdue", in: -90), item("Soon", in: 30), item("Later", in: 600)]),
            now: now
        )
        #expect(steps.first?.date == now)
        #expect(steps.first?.snapshot.items.map(\.title) == ["Overdue", "Soon", "Later"])
    }

    @Test("an entry lands at each upcoming due time, and every entry lists everything, including what is overdue by then")
    func entryAtEachDueTimeKeepsEverything() {
        let steps = WidgetTimelinePlanner.steps(
            for: snapshot([item("A", in: 30), item("B", in: 120), item("C", in: 600)]),
            now: now
        )
        #expect(steps.map(\.date) == [
            now,
            now.addingTimeInterval(30 * 60),
            now.addingTimeInterval(120 * 60),
            now.addingTimeInterval(600 * 60),
        ])
        // A is overdue by the second entry, A and B by the third, all three by
        // the last; none of them leaves the list.
        #expect(steps.map { $0.snapshot.items.map(\.title) } == [
            ["A", "B", "C"],
            ["A", "B", "C"],
            ["A", "B", "C"],
            ["A", "B", "C"],
        ])
    }

    @Test("every entry carries the snapshot unchanged, so the entries differ only in their dates")
    func entriesAreIdenticalInContent() {
        let source = snapshot([item("Overdue", in: -5), item("Soon", in: 10), item("Later", in: 90)])
        let steps = WidgetTimelinePlanner.steps(for: source, now: now)
        #expect(steps.count == 3)
        #expect(steps.allSatisfy { $0.snapshot == source })
    }

    @Test("an item due exactly at now is still listed")
    func dueExactlyAtNowIsKept() {
        let steps = WidgetTimelinePlanner.steps(
            for: snapshot([item("Due this instant", in: 0), item("Next", in: 5)]),
            now: now
        )
        // Due at `now` is not upcoming, so it earns no entry of its own; the
        // item is still on every entry.
        #expect(steps.map(\.date) == [now, now.addingTimeInterval(5 * 60)])
        #expect(steps.allSatisfy { $0.snapshot.items.map(\.title) == ["Due this instant", "Next"] })
    }

    @Test("items sharing a due time collapse into one entry, which still lists them all")
    func sharedDueTimeIsOneEntry() {
        let steps = WidgetTimelinePlanner.steps(
            for: snapshot([item("A", in: 60), item("B", in: 60), item("C", in: 180)]),
            now: now
        )
        #expect(steps.count == 3)
        #expect(steps[1].date == now.addingTimeInterval(60 * 60))
        #expect(steps[1].snapshot.items.map(\.title) == ["A", "B", "C"])
    }

    @Test("the timeline is bounded, nearest due times first")
    func boundedEntries() {
        let items = (1...5).map { item("HW \($0)", in: Double($0) * 60) }
        let steps = WidgetTimelinePlanner.steps(for: snapshot(items), now: now)

        #expect(steps.count == WidgetTimelinePlanner.maxEntries)
        #expect(steps.map(\.date) == [now] + (1...4).map { now.addingTimeInterval(Double($0) * 3600) })

        let tight = WidgetTimelinePlanner.steps(for: snapshot(items), now: now, maxEntries: 2)
        #expect(tight.map(\.date) == [now, now.addingTimeInterval(3600)])

        // A nonsensical cap still yields the entry at `now`, so `Timeline`
        // is never handed an empty list.
        let zero = WidgetTimelinePlanner.steps(for: snapshot(items), now: now, maxEntries: 0)
        #expect(zero.map(\.date) == [now])
    }

    @Test("entry dates ascend even when the snapshot is not in due order, and the app's order is kept in every entry")
    func datesAscendAndOrderIsKept() {
        let steps = WidgetTimelinePlanner.steps(
            for: snapshot([item("Late", in: 300), item("Early", in: 10), item("Mid", in: 100)]),
            now: now
        )
        #expect(steps.map(\.date) == steps.map(\.date).sorted())
        #expect(steps.count == 4)
        #expect(steps.allSatisfy { $0.snapshot.items.map(\.title) == ["Late", "Early", "Mid"] })
    }

    @Test("undated items are listed in every entry alongside the dated ones")
    func undatedItemsRideAlong() {
        let steps = WidgetTimelinePlanner.steps(
            for: snapshot([item("No date", in: nil), item("Dated", in: 15)]),
            now: now
        )
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { $0.snapshot.items.map(\.title) == ["No date", "Dated"] })
    }

    @Test("an empty snapshot is a single empty entry at now")
    func emptySnapshot() {
        let steps = WidgetTimelinePlanner.steps(for: snapshot([]), now: now)
        #expect(steps.count == 1)
        #expect(steps[0].date == now)
        #expect(steps[0].snapshot.items.isEmpty)
    }

    @Test("a snapshot that is entirely overdue is one entry at now that still lists everything")
    func entirelyOverdueStillListed() {
        let steps = WidgetTimelinePlanner.steps(
            for: snapshot([item("Yesterday", in: -1440), item("An hour ago", in: -60)]),
            now: now
        )
        #expect(steps.count == 1)
        #expect(steps[0].date == now)
        #expect(steps[0].snapshot.items.map(\.title) == ["Yesterday", "An hour ago"])
    }

    @Test("every entry keeps the snapshot's generatedAt")
    func generatedAtPreserved() {
        let source = snapshot([item("A", in: 10), item("B", in: 20)])
        let steps = WidgetTimelinePlanner.steps(for: source, now: now)
        #expect(steps.allSatisfy { $0.snapshot.generatedAt == source.generatedAt })
    }

    @Test("planning does not touch the snapshot it was given")
    func sourceUntouched() {
        let source = snapshot([item("Overdue", in: -5), item("Soon", in: 10)])
        let before = source
        _ = WidgetTimelinePlanner.steps(for: source, now: now)
        #expect(source == before)
        #expect(source.items.count == 2)
    }
}
