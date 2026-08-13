import Testing
import Foundation
@testable import LowHangingFruitKit

/// The widget's ledger fallback. It runs only when the app hasn't published a
/// snapshot, so its whole job is to be conservative: never show finished work,
/// never show something the ledger has aged out, never invent an entry.
@MainActor
struct LedgerWidgetReaderTests {

    private func makeStore() throws -> (AssignmentStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-widget-\(UUID().uuidString).store")
        return (try AssignmentStore(url: url), url)
    }

    private func canvas(_ id: String, title: String, due: Date?) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: "CIS 3200", title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    @Test("no store file yields no snapshot rather than an empty one")
    func missingStoreIsNil() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-widget-absent-\(UUID().uuidString).store")
        #expect(LedgerWidgetReader.snapshot(storeURL: url) == nil)
    }

    @Test("upcoming work is returned soonest-first")
    func ordersBySoonest() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        _ = store.reconcile([
            canvas("1", title: "Later", due: now.addingTimeInterval(5 * 86_400)),
            canvas("2", title: "Sooner", due: now.addingTimeInterval(86_400)),
        ], source: .canvas)

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url, now: now))
        #expect(snapshot.items.map(\.title) == ["Sooner", "Later"])
    }

    @Test("finished work never reaches the widget")
    func finishedIsExcluded() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        _ = store.reconcile([
            canvas("1", title: "Done already", due: now.addingTimeInterval(86_400)),
            canvas("2", title: "Still open", due: now.addingTimeInterval(2 * 86_400)),
        ], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: now)

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url, now: now))
        #expect(snapshot.items.map(\.title) == ["Still open"])
    }

    @Test("undated items are skipped — the widget is a due list")
    func undatedSkipped() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        _ = store.reconcile([
            canvas("1", title: "No date", due: nil),
            canvas("2", title: "Dated", due: now.addingTimeInterval(86_400)),
        ], source: .canvas)

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url, now: now))
        #expect(snapshot.items.map(\.title) == ["Dated"])
    }

    @Test("a ledger with nothing showable yields nil, not an empty widget")
    func nothingShowableIsNil() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        _ = store.reconcile([canvas("1", title: "No date", due: nil)], source: .canvas)
        #expect(LedgerWidgetReader.snapshot(storeURL: url, now: now) == nil)
    }

    @Test("the list is capped so a widget never over-reads")
    func capped() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        let many = (1...12).map {
            canvas("\($0)", title: "HW \($0)", due: now.addingTimeInterval(Double($0) * 86_400))
        }
        _ = store.reconcile(many, source: .canvas)

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url, now: now))
        #expect(snapshot.items.count == LedgerWidgetReader.maxItems)
    }
}
