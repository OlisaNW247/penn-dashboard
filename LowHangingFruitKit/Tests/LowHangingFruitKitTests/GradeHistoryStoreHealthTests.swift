import Testing
import Foundation
import SwiftData
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Grade history reports its own health (hardening plan 2026-10-25, B9: DAT-08
/// and KCR-14).
///
/// `GradeHistoryStore` swallowed every failure. A file that would not open fell
/// back to memory with no word of it, a save that failed was `try?`, and an
/// unreadable history read as an empty one, so the week-delta chip's baseline
/// could be gone for good while everything looked as usual. It now keeps the
/// same pairs of counters the ledger does, runs under a versioned schema, and
/// feeds `StorageHealth.Failures`.
///
/// "Versioned container" is the SwiftData sense here, because that is what
/// `GradeHistory.store` is: a store file opened with `GradeHistorySchemaV1`
/// and a migration plan, as `LedgerSchemaV1` does for the ledger. There is no
/// separate JSON envelope to version.
struct GradeHistoryStoreHealthTests {

    private struct InjectedFailure: Error {}

    private func tempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-gradehistory-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private let day: TimeInterval = 86_400
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: The versioned container

    @Test("the schema is 1.0.0, the version an unversioned store already has, with nothing yet to migrate")
    func schemaIdentity() {
        #expect(GradeHistorySchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(GradeHistoryMigrationPlan.schemas.count == 1)
        #expect(GradeHistoryMigrationPlan.stages.isEmpty)
    }

    /// The migration read. The file every shipped build wrote was opened with a
    /// bare `ModelContainer(for:)`; if the versioned open could not adopt it,
    /// `makeDefault()` would fall back to memory on every launch and the
    /// history on disk would be unreachable.
    @MainActor
    @Test("a history file written before the schema was versioned opens in place and reads back")
    func unversionedFileIsAdopted() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        do {
            // Exactly how the previous builds opened it.
            let old = try ModelContainer(
                for: StoredGradeObservation.self,
                configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
            )
            let context = ModelContext(old)
            context.insert(StoredGradeObservation(courseID: "111", observedAt: t0, percent: 88.5))
            context.insert(StoredGradeObservation(courseID: "111", observedAt: t0.addingTimeInterval(day), percent: 90))
            context.insert(StoredGradeObservation(courseID: "222", observedAt: t0, percent: 71))
            try context.save()
        }

        let store = try GradeHistoryStore(url: url)
        #expect(store.isPersistent)
        #expect(store.storageFailureReason == nil)
        let history = store.allHistory()
        #expect(history["111"]?.map(\.percent) == [88.5, 90])
        #expect(history["222"]?.map(\.percent) == [71])
        #expect(store.failedReadCount == 0)

        // And it is writable in the new shape: a reading recorded now is there
        // for the next open.
        #expect(store.record(courseID: "222", percent: 75, now: t0.addingTimeInterval(2 * day)))
        let reopened = try GradeHistoryStore(url: url)
        #expect(reopened.history(courseID: "222").map(\.percent) == [71, 75])
        #expect(reopened.failedReadCount == 0)
    }

    @MainActor
    @Test("a store created under the versioned schema reopens")
    func versionedFileRoundTrips() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }

        let first = try GradeHistoryStore(url: url)
        #expect(first.record(courseID: "111", percent: 93, now: t0))

        let second = try GradeHistoryStore(url: url)
        #expect(second.history(courseID: "111").map(\.percent) == [93])
    }

    // MARK: Falling back to memory says why

    @MainActor
    @Test("a history file that will not open falls back to memory and keeps the reason")
    func unopenableFileSaysWhy() throws {
        // A path under a regular file, which no store can be created at.
        let blocker = tempStoreURL()
        defer { removeStore(at: blocker) }
        try Data("not a directory".utf8).write(to: blocker)
        let impossible = blocker.appendingPathComponent("GradeHistory.store")

        let store = try #require(GradeHistoryStore.openOrFallBack(at: impossible))
        #expect(!store.isPersistent)
        let reason = try #require(store.storageFailureReason)
        #expect(reason.contains("kept in memory only"))
        // Still usable for the session.
        #expect(store.record(courseID: "111", percent: 80, now: t0))
        #expect(store.history(courseID: "111").count == 1)
    }

    @MainActor
    @Test("a missing App Group container falls back to memory and keeps the reason")
    func missingContainerSaysWhy() throws {
        let store = try #require(GradeHistoryStore.openOrFallBack(at: nil))
        #expect(!store.isPersistent)
        #expect(try #require(store.storageFailureReason).contains("App Group"))
    }

    @MainActor
    @Test("a file that opens is persistent and has no failure to report")
    func openableFileIsClean() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        let store = try #require(GradeHistoryStore.openOrFallBack(at: url))
        #expect(store.isPersistent)
        #expect(store.storageFailureReason == nil)
    }

    @MainActor
    @Test("the deliberate in-memory store is not a failure")
    func hermeticStoreIsNotAFailure() throws {
        let store = try GradeHistoryStore(inMemory: true)
        #expect(!store.isPersistent)
        #expect(store.storageFailureReason == nil, "tests and previews run this way on purpose")
    }

    // MARK: Counting

    @MainActor
    @Test("a failed save is reported and counted, and the next good one clears the message")
    func saveFailuresAreCounted() throws {
        let store = try GradeHistoryStore(inMemory: true)
        store.saveFailureForTesting = InjectedFailure()
        #expect(!store.record(courseID: "111", percent: 80, now: t0))
        #expect(store.failedSaveCount == 1)
        #expect(store.lastSaveError != nil)

        store.saveFailureForTesting = nil
        #expect(store.record(courseID: "111", percent: 82, now: t0.addingTimeInterval(day)))
        #expect(store.lastSaveError == nil, "failing now, not failed once")
        #expect(store.failedSaveCount == 1, "the session count is not reset")
    }

    @MainActor
    @Test("an unreadable history is not an empty one: it is counted, and no second reading is added blind")
    func readFailuresAreCounted() throws {
        let store = try GradeHistoryStore(inMemory: true)
        #expect(store.record(courseID: "111", percent: 80, now: t0))

        store.readFailureForTesting = InjectedFailure()
        #expect(store.allHistory().isEmpty)
        #expect(store.history(courseID: "111").isEmpty)
        #expect(store.failedReadCount == 2)
        #expect(store.lastReadError != nil)
        // A second reading the same day would break the one-per-day rule, so
        // when today's row cannot be looked for, nothing is written.
        #expect(!store.record(courseID: "111", percent: 99, now: t0.addingTimeInterval(60)))

        store.readFailureForTesting = nil
        #expect(store.history(courseID: "111").map(\.percent) == [80], "and nothing was added or lost")
        #expect(store.lastReadError == nil)
        #expect(store.failedReadCount >= 3)
    }

    @MainActor
    @Test("clearing history says when it could not")
    func clearAllReportsOutcome() throws {
        let store = try GradeHistoryStore(inMemory: true)
        #expect(store.record(courseID: "111", percent: 80, now: t0))

        store.readFailureForTesting = InjectedFailure()
        #expect(!store.clearAll(), "nothing could be found to delete")
        store.readFailureForTesting = nil
        #expect(store.history(courseID: "111").count == 1)

        store.saveFailureForTesting = InjectedFailure()
        #expect(!store.clearAll())
        store.saveFailureForTesting = nil

        #expect(store.clearAll())
        #expect(store.allHistory().isEmpty)
    }

    @MainActor
    @Test("a legacy import skips a course it cannot look at, instead of importing it blind")
    func legacyImportSkipsUnreadableCourses() throws {
        let store = try GradeHistoryStore(inMemory: true)
        let legacy = ["111": [GradeHistoryStore.Observation(date: t0, percent: 80)]]

        store.readFailureForTesting = InjectedFailure()
        #expect(store.importLegacyHistory(legacy) == 0)
        store.readFailureForTesting = nil
        #expect(store.allHistory().isEmpty)

        #expect(store.importLegacyHistory(legacy) == 1)
    }

    // MARK: StorageHealth

    @MainActor
    @Test("StorageHealth.Failures carries grade history's failed reads and saves, and a fallback counts as a failed load")
    func appStateFeedsHistoryFailuresIntoStorageHealth() throws {
        let ledger = try AssignmentStore(inMemory: true)
        let history = try GradeHistoryStore(inMemory: true)
        let state = AppState(assignmentStore: ledger, gradeHistoryStore: history)
        #expect(state.storageFailures.isClean)

        history.readFailureForTesting = InjectedFailure()
        _ = history.allHistory()
        history.readFailureForTesting = nil
        history.saveFailureForTesting = InjectedFailure()
        history.record(courseID: "111", percent: 80, now: t0)
        history.saveFailureForTesting = nil

        #expect(state.storageFailures.historyReads == 1)
        #expect(state.storageFailures.historySaves == 1)
        #expect(state.storageFailures.reads >= 1)
        #expect(state.storageFailures.saves >= 1)
        #expect(!state.storageFailures.isClean)

        // A history that could not be opened is a failed load from the first
        // moment, before any fetch.
        let fallback = try #require(GradeHistoryStore.openOrFallBack(at: nil))
        let stateWithFallback = AppState(assignmentStore: try AssignmentStore(inMemory: true),
                                         gradeHistoryStore: fallback)
        #expect(stateWithFallback.storageFailures.historyReads == 1)
    }
}
