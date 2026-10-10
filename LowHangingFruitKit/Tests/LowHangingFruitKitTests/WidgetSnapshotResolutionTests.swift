import Testing
import Foundation
@testable import LowHangingFruitKit

/// Which source the widget trusts. The snapshot the app published is the
/// dashboard's own answer, so an empty one means "caught up" and must stay
/// empty; only the absence of any readable snapshot hands the widget to the
/// raw ledger, which cannot reproduce the dashboard's filtering.
///
/// Every test runs against a temp directory through the `…(from:)` /
/// `…(snapshotURL:ledger:)` seams. `WidgetSnapshotStore`'s public entry points
/// resolve the App Group container, which an unsandboxed macOS test run would
/// reach without the entitlement (see `SharedDefaults.isTestRunner`), so none
/// of these touches them.
struct WidgetSnapshotResolutionTests {

    private func makeTempDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-widget-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ title: String, in hours: Double) -> WidgetItem {
        WidgetItem(title: title, course: "CIS 3200", dueAt: now.addingTimeInterval(hours * 3600))
    }

    /// A ledger stand-in that records whether anyone asked it anything.
    private final class LedgerSpy: @unchecked Sendable {
        private(set) var calls = 0
        let result: WidgetSnapshot?
        init(returning result: WidgetSnapshot?) { self.result = result }
        func read() -> WidgetSnapshot? {
            calls += 1
            return result
        }
    }

    private var ledgerRows: WidgetSnapshot {
        WidgetSnapshot(
            items: [item("Raw ledger row the dashboard hides", in: 2)],
            generatedAt: now
        )
    }

    @Test("a published empty snapshot is used as is, and the ledger is never consulted")
    func publishedEmptyIsTrusted() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)
        WidgetSnapshotStore.write(WidgetSnapshot(items: [], generatedAt: now), to: url)

        let ledger = LedgerSpy(returning: ledgerRows)
        let resolved = WidgetSnapshotStore.current(snapshotURL: url) { ledger.read() }

        #expect(resolved.items.isEmpty)
        #expect(resolved.generatedAt == now)
        #expect(ledger.calls == 0)
    }

    @Test("a published snapshot with items is used as is, and the ledger is never consulted")
    func publishedItemsAreTrusted() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)
        let published = WidgetSnapshot(items: [item("From the dashboard", in: 5)], generatedAt: now)
        WidgetSnapshotStore.write(published, to: url)

        let ledger = LedgerSpy(returning: ledgerRows)
        let resolved = WidgetSnapshotStore.current(snapshotURL: url) { ledger.read() }

        #expect(resolved == published)
        #expect(ledger.calls == 0)
    }

    @Test("no snapshot file falls back to the ledger")
    func missingFileFallsBack() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let ledger = LedgerSpy(returning: ledgerRows)
        let resolved = WidgetSnapshotStore.current(snapshotURL: url) { ledger.read() }

        #expect(resolved == ledgerRows)
        #expect(ledger.calls == 1)
    }

    @Test("an unresolvable App Group (no snapshot URL at all) falls back to the ledger")
    func noURLFallsBack() {
        let ledger = LedgerSpy(returning: ledgerRows)
        let resolved = WidgetSnapshotStore.current(snapshotURL: nil) { ledger.read() }

        #expect(resolved == ledgerRows)
        #expect(ledger.calls == 1)
    }

    @Test("an unreadable snapshot (garbage bytes) falls back to the ledger")
    func garbageFileFallsBack() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)
        try Data("not json at all {{{".utf8).write(to: url)

        let ledger = LedgerSpy(returning: ledgerRows)
        let resolved = WidgetSnapshotStore.current(snapshotURL: url) { ledger.read() }

        #expect(WidgetSnapshotStore.read(from: url) == nil)
        #expect(resolved == ledgerRows)
        #expect(ledger.calls == 1)
    }

    @Test("an empty file and JSON of the wrong shape both count as unreadable")
    func emptyAndWrongShapeFilesFallBack() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)

        for contents in ["", "{}", #"{"items": "nope", "generatedAt": 1}"#] {
            try Data(contents.utf8).write(to: url)
            let ledger = LedgerSpy(returning: ledgerRows)
            let resolved = WidgetSnapshotStore.current(snapshotURL: url) { ledger.read() }

            #expect(WidgetSnapshotStore.read(from: url) == nil, "contents: \(contents)")
            #expect(resolved == ledgerRows, "contents: \(contents)")
            #expect(ledger.calls == 1, "contents: \(contents)")
        }
    }

    @Test("no snapshot and nothing showable in the ledger is the empty snapshot")
    func nothingAnywhereIsEmpty() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)

        let ledger = LedgerSpy(returning: nil)
        let resolved = WidgetSnapshotStore.current(snapshotURL: url) { ledger.read() }

        #expect(resolved == .empty)
        #expect(resolved.items.isEmpty)
        #expect(ledger.calls == 1)
    }

    @Test("a snapshot published long ago is still trusted: there is no staleness rule")
    func oldSnapshotIsStillPublished() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)
        // The app only republishes while it runs, so a student who has not
        // opened it for a term still has a snapshot, and it is still the
        // dashboard's last word.
        let longAgo = now.addingTimeInterval(-120 * 86_400)
        WidgetSnapshotStore.write(WidgetSnapshot(items: [], generatedAt: longAgo), to: url)

        let ledger = LedgerSpy(returning: ledgerRows)
        let resolved = WidgetSnapshotStore.current(snapshotURL: url) { ledger.read() }

        #expect(resolved.items.isEmpty)
        #expect(resolved.generatedAt == longAgo)
        #expect(ledger.calls == 0)
    }

    @Test("the snapshot file round-trips, including an empty item list")
    func roundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(WidgetSharing.snapshotFilename)

        for snapshot in [
            WidgetSnapshot(items: [], generatedAt: now),
            WidgetSnapshot(items: [item("A", in: 1), item("B", in: 30)], generatedAt: now),
        ] {
            WidgetSnapshotStore.write(snapshot, to: url)
            #expect(WidgetSnapshotStore.read(from: url) == snapshot)
        }
    }
}
