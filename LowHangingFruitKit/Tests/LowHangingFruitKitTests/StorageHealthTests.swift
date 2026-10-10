import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// "not saving on this phone": when the dashboard says nothing is being kept.
/// The rule is a pure function of three booleans (`StorageHealth`), so the
/// truth table is tested directly; a few tests then check that `AppState`
/// feeds it from the real ledger.
@Suite("Storage health banner")
struct StorageHealthTests {

    @Test("a healthy, on-disk ledger shows nothing")
    func healthyShowsNothing() {
        #expect(!StorageHealth.showsNotSavingBanner(isFixtureData: false, isPersistent: true, lastSaveFailed: false))
    }

    @Test("an in-memory ledger shows the banner")
    func inMemoryShows() {
        #expect(StorageHealth.showsNotSavingBanner(isFixtureData: false, isPersistent: false, lastSaveFailed: false))
    }

    @Test("a failing write shows the banner even on an on-disk ledger")
    func failedSaveShows() {
        #expect(StorageHealth.showsNotSavingBanner(isFixtureData: false, isPersistent: true, lastSaveFailed: true))
    }

    @Test("in-memory and failing together still show it once")
    func bothShow() {
        #expect(StorageHealth.showsNotSavingBanner(isFixtureData: false, isPersistent: false, lastSaveFailed: true))
    }

    @Test("never in preview or demo mode, whatever the ledger says")
    func neverForFixtureData() {
        for persistent in [true, false] {
            for failed in [true, false] {
                #expect(!StorageHealth.showsNotSavingBanner(
                    isFixtureData: true, isPersistent: persistent, lastSaveFailed: failed))
            }
        }
    }

    // MARK: AppState reads the real ledger

    @MainActor
    @Test("AppState shows it for an in-memory ledger and hides it for fixture data")
    func appStateWithInMemoryLedger() throws {
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        // Pinned per instance: preview mode is a shared-defaults flag other
        // suites' `AppState.init` read (CLAUDE.md, the shared-defaults trap).
        state.forceFixtureDataForTesting(false)
        #expect(state.showsNotSavingBanner)

        state.forceFixtureDataForTesting(true)
        #expect(!state.showsNotSavingBanner, "preview mode is the reviewer's path and must stay clean")
    }

    @MainActor
    @Test("AppState shows nothing for a ledger that is really on disk")
    func appStateWithPersistentLedger() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-health-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let store = try AssignmentStore(url: url)
        #expect(store.isPersistent)
        #expect(store.lastSaveError == nil)

        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        #expect(!state.showsNotSavingBanner)
    }
}
