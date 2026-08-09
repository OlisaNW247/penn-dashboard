import Testing
import Foundation
@testable import LowHangingFruitKit

/// Unit tests for the durable ledger's reconciliation — the mechanism that stops
/// a rolling feed or a flaky fetch from losing assignments.
@MainActor
struct AssignmentStoreTests {

    // MARK: Helpers

    private func store() throws -> AssignmentStore {
        // In-memory: hermetic and fresh per test.
        try AssignmentStore(inMemory: true)
    }

    private func canvas(_ id: String, course: String = "CIS 1200", title: String = "HW", due: Date? = nil) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    private func gradescope(_ id: String, course: String = "CIS 1200", title: String = "HW", due: Date? = nil, submitted: Bool = false) -> Assignment {
        Assignment(source: .gradescope, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due, url: nil, submitted: submitted)
    }

    // MARK: Core reconciliation

    @Test("first sync inserts every fetched item")
    func firstSyncInserts() throws {
        let store = try store()
        let result = store.reconcile([canvas("1"), canvas("2")], source: .canvas)
        #expect(result.items.count == 2)
        #expect(!result.wasSuspectedPartial)
        #expect(store.rowCount() == 2)
    }

    @Test("an item that leaves the feed is retained, not dropped")
    func retainsVanishedItem() throws {
        let store = try store()
        let due = Date().addingTimeInterval(3 * 86_400)   // future → never aged out
        _ = store.reconcile([canvas("1", due: due), canvas("2", due: due)], source: .canvas)

        // Second sync: item "2" has dropped out of the rolling feed.
        let result = store.reconcile([canvas("1", due: due)], source: .canvas)

        // Both are still present — the vanished one is kept.
        #expect(Set(result.items.map(\.id)) == ["canvas:1", "canvas:2"])
    }

    @Test("a suspiciously empty fetch is refused and keeps prior data")
    func partialFetchGuard() throws {
        let store = try store()
        _ = store.reconcile([canvas("1"), canvas("2"), canvas("3")], source: .canvas)

        let result = store.reconcile([], source: .canvas)

        #expect(result.wasSuspectedPartial)
        #expect(result.items.count == 3)   // nothing lost
    }

    @Test("an empty first sync is not treated as a partial")
    func emptyFirstSyncIsNotPartial() throws {
        let store = try store()
        let result = store.reconcile([], source: .canvas)
        #expect(!result.wasSuspectedPartial)
        #expect(result.items.isEmpty)
    }

    @Test("re-seeing an item refreshes its display fields")
    func upsertRefreshesFields() throws {
        let store = try store()
        _ = store.reconcile([canvas("1", title: "HW 3")], source: .canvas)
        let result = store.reconcile([canvas("1", title: "HW 3 (updated)")], source: .canvas)
        #expect(result.items.first?.title == "HW 3 (updated)")
        #expect(store.rowCount() == 1)   // updated in place, not duplicated
    }

    @Test("reconciliation is idempotent")
    func idempotent() throws {
        let store = try store()
        let items = [canvas("1"), canvas("2")]
        _ = store.reconcile(items, source: .canvas)
        let again = store.reconcile(items, source: .canvas)
        #expect(again.items.count == 2)
        #expect(store.rowCount() == 2)
    }

    @Test("sources are reconciled independently")
    func sourcesIndependent() throws {
        let store = try store()
        _ = store.reconcile([canvas("1")], source: .canvas)
        let g = store.reconcile([gradescope("9")], source: .gradescope)
        // Reconciling Gradescope doesn't flag the Canvas item gone.
        #expect(g.items.map(\.id) == ["gradescope:9"])
        let c = store.reconcile([canvas("1")], source: .canvas)
        #expect(c.items.map(\.id) == ["canvas:1"])
    }

    // MARK: Aging

    @Test("a gone item aged past its due-date grace window is dropped")
    func agesOutGoneOverdueItem() throws {
        let store = try store()
        let longAgo = Date().addingTimeInterval(-60 * 86_400)   // 60 days overdue
        _ = store.reconcile([canvas("1", due: longAgo), canvas("2", due: longAgo)], source: .canvas)
        // "1" drops from the feed and is now long overdue → ages out.
        let result = store.reconcile([canvas("2", due: longAgo)], source: .canvas)
        #expect(result.items.map(\.id) == ["canvas:2"])
    }

    @Test("a gone but undated item is never aged out")
    func undatedGoneItemKept() throws {
        let store = try store()
        _ = store.reconcile([canvas("1", due: nil), canvas("2", due: nil)], source: .canvas)
        let result = store.reconcile([canvas("2", due: nil)], source: .canvas)
        #expect(Set(result.items.map(\.id)) == ["canvas:1", "canvas:2"])
    }

    @Test("a recently-overdue gone item is still kept (within grace)")
    func recentlyOverdueKept() throws {
        let store = try store()
        let yesterday = Date().addingTimeInterval(-1 * 86_400)
        _ = store.reconcile([canvas("1", due: yesterday), canvas("2", due: yesterday)], source: .canvas)
        let result = store.reconcile([canvas("2", due: yesterday)], source: .canvas)
        #expect(Set(result.items.map(\.id)) == ["canvas:1", "canvas:2"])
    }

    // MARK: Gradescope submission flag

    @Test("Gradescope submitted flag is persisted and rebuilt")
    func gradescopeSubmittedPersisted() throws {
        let store = try store()
        let result = store.reconcile([gradescope("9", submitted: true)], source: .gradescope)
        #expect(result.items.first?.submitted == true)
    }

    // MARK: Purge

    @Test("purge removes only the named source")
    func purgeBySource() throws {
        let store = try store()
        _ = store.reconcile([canvas("1")], source: .canvas)
        _ = store.reconcile([gradescope("9")], source: .gradescope)
        store.purge(source: .canvas)
        #expect(store.currentAssignments().map(\.id) == ["gradescope:9"])
    }
}
