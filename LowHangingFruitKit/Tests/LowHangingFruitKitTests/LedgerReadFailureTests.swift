import Testing
import Foundation
import SwiftData
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A ledger that cannot be read is not an empty ledger (hardening plan
/// 2026-10-25, B6: KCR-02 and DAT-10).
///
/// `AssignmentStore.allRows()` used to turn a failed fetch into `[]`, and every
/// caller then reasoned about a ledger with nothing in it. A sync read "no rows
/// for this source", so an empty fetch passed the suspiciously-empty guard as a
/// legitimate first sync and a non-empty one inserted a twin of everything the
/// student already had. Completion read back as "nothing finished" and reopened
/// every card. The launch check for an existing install read "no feed rows" and
/// left the door open for the first feed to be taken for a new student's.
///
/// None of these can be provoked by breaking a real store on demand, so they run
/// through `AssignmentStore.readFailureForTesting`, which makes every fetch
/// throw while it is set, and then clear it to look at what survived.
struct LedgerReadFailureTests {

    private struct InjectedReadFailure: Error {}

    private static let course = "READFAIL 100"

    private func item(_ id: String, title: String = "HW", due: Date? = nil) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: Self.course, title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    private func gradescopeItem(_ id: String, due: Date? = nil) -> Assignment {
        Assignment(source: .gradescope, sourceID: id, kind: .assignment,
                   course: Self.course, title: "GS", dueAt: due, url: nil)
    }

    /// An in-memory ledger holding three Canvas assignments, one of them done.
    @MainActor
    private func seededStore() throws -> AssignmentStore {
        let store = try AssignmentStore(inMemory: true)
        let due = Date().addingTimeInterval(5 * 86_400)
        _ = store.reconcile([item("1", due: due), item("2", due: due), item("3", due: due)], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Date())
        return store
    }

    private func tempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-readfail-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    // MARK: reconcile

    @MainActor
    @Test("a sync over an unreadable ledger changes nothing, whatever it fetched", arguments: [true, false])
    func reconcileAbortsAndWritesNothing(fetchIsEmpty: Bool) throws {
        let store = try seededStore()
        #expect(store.rowCount() == 3)

        store.readFailureForTesting = InjectedReadFailure()
        let due = Date().addingTimeInterval(5 * 86_400)
        let fetched = fetchIsEmpty ? [] : [item("1", due: due), item("brand-new", due: due)]
        let result = store.reconcile(fetched, source: .canvas)

        #expect(result.readFailed)
        #expect(!result.wasSuspectedPartial, "no verdict on a fetch the ledger could not be compared with")
        #expect(result.items.isEmpty, "the items mean nothing here; the caller keeps the pool it has")

        store.readFailureForTesting = nil
        #expect(store.rowCount() == 3, "nothing inserted: the new item and the twin of item 1 were never written")
        #expect(store.goneFromFeedIDs(source: .canvas).isEmpty, "nothing flagged gone for being missing from a fetch")
        #expect(store.completionRecordOrFail().ids == ["canvas:1"], "and the tick is where it was")
        #expect(store.currentAssignments().count == 3)
    }

    @MainActor
    @Test("an aborted sync ages nothing out, and the next good one still does")
    func reconcileAgesNothingOnAReadFailure() throws {
        // A row that is gone from the feed and far past due: exactly what the
        // pruner at the end of a successful reconcile deletes. Written straight
        // into the file so it is already on disk when the store opens.
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        let longAgo = Date().addingTimeInterval(-90 * 86_400)
        let aged = StoredAssignment.make(from: item("aged", due: longAgo), now: longAgo)
        aged.isGoneFromFeed = true
        let container = try ModelContainer(
            for: StoredAssignment.self,
            configurations: ModelConfiguration(url: url, cloudKitDatabase: .none)
        )
        let context = ModelContext(container)
        context.insert(aged)
        try context.save()

        let store = try AssignmentStore(url: url)
        #expect(store.rowCount() == 1)

        store.readFailureForTesting = InjectedReadFailure()
        _ = store.reconcile([item("fresh", due: Date().addingTimeInterval(86_400))], source: .canvas)
        store.readFailureForTesting = nil
        #expect(store.allRowsForTesting().map(\.sourceID) == ["aged"],
                "the aborted pass pruned nothing and inserted nothing")

        // The control: the same call against a readable ledger does collect it,
        // so the assertion above is about the abort and not about aging never
        // running in this fixture.
        _ = store.reconcile([item("fresh", due: Date().addingTimeInterval(86_400))], source: .canvas)
        #expect(store.allRowsForTesting().map(\.sourceID) == ["fresh"],
                "the aged row is collected and the fresh one inserted")
    }

    @MainActor
    @Test("a suspiciously empty fetch hands back the saved rows even if a later fetch would fail")
    func partialGuardAnswersFromTheRowsItAlreadyHolds() throws {
        let store = try seededStore()
        // The first fetch of the pass succeeds and the one after it fails: the
        // answer must come from what the first one returned.
        store.readFailureForTesting = InjectedReadFailure()
        store.readsBeforeFailureForTesting = 1
        let result = store.reconcile([], source: .canvas)
        #expect(result.wasSuspectedPartial)
        #expect(!result.readFailed)
        #expect(result.items.count == 3, "an empty list here would read as \"showing your saved assignments\" over nothing")
    }

    @MainActor
    @Test("a normal pass answers from the rows it already holds even if a later fetch would fail")
    func normalPassAnswersFromTheRowsItAlreadyHolds() throws {
        let store = try seededStore()
        store.readFailureForTesting = InjectedReadFailure()
        store.readsBeforeFailureForTesting = 1
        let due = Date().addingTimeInterval(5 * 86_400)
        let result = store.reconcile([item("1", due: due), item("fresh", due: due)], source: .canvas)
        #expect(!result.readFailed)
        #expect(result.items.count == 4, "the three saved rows and the new one, not an empty list")
        // The pass could not prune, because its fetch failed, and said nothing
        // about it: aging is housekeeping and runs again on the next sync.
        store.readFailureForTesting = nil
        #expect(store.rowCount() == 4)
    }

    @MainActor
    @Test("a good read after a failed one reconciles normally")
    func reconcileRecovers() throws {
        let store = try seededStore()
        store.readFailureForTesting = InjectedReadFailure()
        #expect(store.reconcile([], source: .canvas).readFailed)
        store.readFailureForTesting = nil

        let result = store.reconcile([], source: .canvas)
        #expect(!result.readFailed)
        #expect(result.wasSuspectedPartial, "now the guard has a ledger to compare the empty fetch with")
        #expect(result.items.count == 3)
    }

    // MARK: completionRecord, holdsFeedRows

    @MainActor
    @Test("completionRecord is nil, not empty, while the ledger cannot be read")
    func completionRecordIsNilOnAFailedRead() throws {
        let store = try seededStore()
        #expect(store.completionRecord()?.ids == ["canvas:1"])

        store.readFailureForTesting = InjectedReadFailure()
        #expect(store.completionRecord() == nil)
        #expect(store.completionDates() == nil)

        store.readFailureForTesting = nil
        #expect(store.completionRecord()?.ids == ["canvas:1"])
    }

    @MainActor
    @Test("holdsFeedRows is nil, not false, while the ledger cannot be read")
    func holdsFeedRowsIsNilOnAFailedRead() throws {
        let store = try seededStore()
        #expect(store.holdsFeedRows() == true)

        store.readFailureForTesting = InjectedReadFailure()
        #expect(store.holdsFeedRows() == nil, "false would say \"a new student\"")

        store.readFailureForTesting = nil
        #expect(store.holdsFeedRows() == true)
    }

    // MARK: Counting

    @MainActor
    @Test("every failed read is counted, and the next good read clears the message")
    func failuresAreCounted() throws {
        let store = try seededStore()
        #expect(store.failedReadCount == 0)
        #expect(store.lastReadError == nil)

        store.readFailureForTesting = InjectedReadFailure()
        // Four readers with different appetites for a failure: the forgiving
        // ones carry on with nothing and still count it.
        _ = store.currentAssignments()
        _ = store.rowCount()
        _ = store.completionRecord()
        _ = store.holdsFeedRows()
        #expect(store.failedReadCount >= 4)
        #expect(store.lastReadError != nil)

        let counted = store.failedReadCount
        store.readFailureForTesting = nil
        _ = store.rowCount()
        #expect(store.lastReadError == nil, "failing now, not failed once")
        #expect(store.failedReadCount == counted, "the session count is not reset by a good read")
        #expect(store.stats().failedReadCount == counted)
    }

    @MainActor
    @Test("a ledger that has failed to read is not reported healthy, even on disk")
    func readFailureEndsHealth() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        let store = try AssignmentStore(url: url)
        #expect(store.stats().isHealthy)

        store.readFailureForTesting = InjectedReadFailure()
        _ = store.rowCount()
        store.readFailureForTesting = nil
        #expect(!store.stats().isHealthy)
    }

    // MARK: AppState

    @MainActor
    @Test("AppState keeps what it knows is finished when the ledger cannot be read")
    func appStateKeepsCompletionOnAFailedRead() throws {
        let store = try seededStore()
        let state = AppState(assignmentStore: store)
        state.reloadCompletionFromLedger()
        #expect(state.completedAssignmentIDs.contains("canvas:1"))

        store.readFailureForTesting = InjectedReadFailure()
        state.reloadCompletionFromLedger()
        #expect(state.completedAssignmentIDs.contains("canvas:1"),
                "an unreadable ledger is not a student who has finished nothing")
        #expect(state.completionDates["canvas:1"] != nil)
    }

    @MainActor
    @Test("a Canvas sync that could not read the ledger leaves the pool and says so")
    func canvasSyncKeepsThePoolOnAFailedRead() throws {
        let store = try seededStore()
        let state = AppState(assignmentStore: store)
        let due = Date().addingTimeInterval(5 * 86_400)
        state.canvasItems = store.currentAssignments()
        #expect(state.canvasItems.count == 3)

        store.readFailureForTesting = InjectedReadFailure()
        state.syncNotice = nil
        state.reconcileCanvasFetch([item("only-one", due: due)], into: store)
        #expect(state.canvasItems.count == 3, "neither wiped nor replaced by the fetch's own window")
        #expect(state.syncNotice != nil)

        // The control: once the ledger can be read, the same call lands.
        store.readFailureForTesting = nil
        state.syncNotice = nil
        state.reconcileCanvasFetch([item("only-one", due: due)], into: store)
        #expect(state.canvasItems.contains { $0.sourceID == "only-one" })
        #expect(state.canvasItems.count == 4, "three retained rows and the new one")
    }

    @MainActor
    @Test("a Gradescope sync that could not read the ledger leaves the pool alone")
    func gradescopeSyncKeepsThePoolOnAFailedRead() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([gradescopeItem("g1"), gradescopeItem("g2")], source: .gradescope)
        let state = AppState(assignmentStore: store)
        state.gradescopeItems = store.currentAssignments().filter { $0.source == .gradescope }
        #expect(state.gradescopeItems.count == 2)

        store.readFailureForTesting = InjectedReadFailure()
        state.reconcileGradescopeFetch([], into: store)
        #expect(state.gradescopeItems.count == 2)
    }

    // MARK: The sign-up backlog

    /// A student whose ledger is briefly unreadable at launch must not be taken
    /// for a new student once it can be read: placement 2 records a sign-up for
    /// any install still undecided when feed items arrive, and everything of
    /// theirs older than a week would then be hidden.
    @MainActor
    @Test("an unreadable ledger at launch defers the backlog decision instead of making a new student of an old one")
    func unreadableLedgerAtLaunchDoesNotBecomeASignup() throws {
        let suite = "lhf.readfail-backlog.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = try AssignmentStore(inMemory: true)
        let now = Date()
        let seeded = Assignment(source: .canvas, sourceID: "old", kind: .assignment,
                                course: Self.course, title: "Work from last month",
                                dueAt: now.addingTimeInterval(-20 * 86_400), url: nil)
        _ = store.reconcile([seeded], source: .canvas, now: now.addingTimeInterval(-30 * 86_400))

        // Launch with the ledger unreadable: onboarding unfinished, so no
        // first-launch proof, and the ledger scan is the only evidence.
        store.readFailureForTesting = InjectedReadFailure()
        let state = AppState(
            assignmentStore: store,
            signupBacklogDefaults: defaults,
            persistedFlagsForSignupBacklog: (complete: false, inPreview: false)
        )
        #expect(SignupBacklogStore(defaults: defaults).decision == .undecided)

        // The ledger comes back, a feed arrives, the dashboard rebuilds: the
        // moment placement 2 would take its decision.
        store.readFailureForTesting = nil
        state.canvasItems = [seeded]
        state.rebuildDashboardItemsForTesting(now: now)
        #expect(SignupBacklogStore(defaults: defaults).decision == .undecided,
                "taking an existing install for a new student hides their older work")
        #expect(state.signupBacklogHiddenCount == 0)
    }
}
