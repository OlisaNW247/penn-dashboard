import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Disconnecting Canvas used to delete every ledger row of the source, finished
/// ones included, and clear the grade history with it, on a confirmation that
/// never says so (hardening plan B1). CLAUDE.md's invariant is that nothing the
/// student did is ever lost. These pin the store rule, the `AppState` wiring
/// (including the school-switch path that must keep the old, total purge), and
/// the retry of a server deletion the network refused.
@MainActor
@Suite("Disconnect keeps student work", .serialized)
struct DisconnectKeepsStudentWorkTests {
    /// Puts `UserDefaults.lhf` back after each test (see `LHFDefaultsGuard`).
    private let defaultsGuard = LHFDefaultsGuard()

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let future = now.addingTimeInterval(5 * 86_400)

    private func canvas(_ id: String) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment, course: "CIS 1200", title: "HW \(id)",
                   dueAt: Self.future, url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    private func announcementTask(_ id: String) -> Assignment {
        Assignment(source: .canvasAnnouncement, sourceID: id, kind: .assignment, course: "CIS 1200",
                   title: "Task \(id)", dueAt: Self.future, url: nil)
    }

    private func rowsByID(_ store: AssignmentStore) -> [String: StoredAssignment] {
        Dictionary(uniqueKeysWithValues: store.allRowsForTesting().map { ($0.id, $0) })
    }

    // MARK: The store rule

    @Test("a finished row survives, flagged gone from the feed, and an unfinished one is removed")
    func finishedSurvivesUnfinishedGoes() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1"), canvas("2")], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Self.now)

        let removed = store.purgeKeepingStudentWork(source: .canvas)

        #expect(removed == 1)
        let rows = rowsByID(store)
        #expect(Set(rows.keys) == ["canvas:1"])
        #expect(rows["canvas:1"]?.userCompleted == true)
        #expect(rows["canvas:1"]?.isGoneFromFeed == true)
        #expect(store.completionRecord()?.ids.contains("canvas:1") == true)
        #expect(store.goneFromFeedIDs(source: .canvas) == ["canvas:1"])
    }

    @Test("work Canvas reported as turned in counts as finished, and a completion-only row is kept")
    func submittedAndCompletionOnlyRowsAreKept() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("3"), canvas("4")], source: .canvas)
        store.applySubmissionState(submittedCanvasAssignmentIDs: ["3"], scores: [:])
        // A completion for an id the ledger never held a real row for.
        store.setCompleted(ids: ["canvas:99"], at: Self.now)

        store.purgeKeepingStudentWork(source: .canvas)

        let rows = rowsByID(store)
        #expect(Set(rows.keys) == ["canvas:3", "canvas:99"])
        #expect(rows["canvas:99"]?.isCompletionOnly == true)
        #expect(rows["canvas:99"]?.isGoneFromFeed == true)
    }

    @Test("it only touches the named source")
    func otherSourcesAreUntouched() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1")], source: .canvas)
        _ = store.reconcile([Assignment(source: .gradescope, sourceID: "9", kind: .assignment, course: "CIS 1200",
                                        title: "G", dueAt: Self.future, url: nil)], source: .gradescope)

        store.purgeKeepingStudentWork(source: .canvas)

        #expect(Set(rowsByID(store).keys) == ["gradescope:9"])
    }

    @Test("signing back in brings a kept row back to life, still completed")
    func reconnectRestoresKeptRow() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1")], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Self.now)
        store.purgeKeepingStudentWork(source: .canvas)

        let result = store.reconcile([canvas("1")], source: .canvas)

        #expect(result.items.map(\.id) == ["canvas:1"])
        #expect(rowsByID(store)["canvas:1"]?.isGoneFromFeed == false)
        #expect(rowsByID(store)["canvas:1"]?.userCompleted == true)
    }

    @Test("the old purge still removes everything, which is what a school switch needs")
    func plainPurgeIsUnchanged() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1"), canvas("2")], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Self.now)
        store.purge(source: .canvas)
        #expect(store.rowCount() == 0)
    }

    // MARK: AppState

    private func makeState(store: AssignmentStore, history: GradeHistoryStore? = nil) -> AppState {
        let state = AppState(assignmentStore: store, gradeHistoryStore: history)
        state.forceFixtureDataForTesting(false)
        return state
    }

    @Test("disconnecting Canvas keeps the finished row and the grade history, and drops the unfinished row")
    func disconnectKeepsWhatTheStudentDid() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1"), canvas("2")], source: .canvas)
        _ = store.reconcile([announcementTask("a1"), announcementTask("a2")], source: .canvasAnnouncement)
        store.setCompleted(ids: ["canvas:1", "canvasAnnouncement:a1"], at: Self.now)
        let history = try GradeHistoryStore(inMemory: true)
        history.record(courseID: "100", percent: 91.5, now: Self.now)
        let state = makeState(store: store, history: history)
        #expect(state.gradeWatcher.history["100"]?.count == 1)

        state.disconnectCanvas()

        let rows = rowsByID(store)
        #expect(rows["canvas:1"]?.userCompleted == true)
        #expect(rows["canvas:1"]?.isGoneFromFeed == true)
        #expect(rows["canvas:2"] == nil)
        #expect(rows["canvasAnnouncement:a1"]?.userCompleted == true)
        #expect(rows["canvasAnnouncement:a2"] == nil)
        #expect(state.completedAssignmentIDs.contains("canvas:1"))
        // The grade trail is the student's, not the session's.
        #expect(history.allHistory()["100"]?.count == 1)
        #expect(state.gradeWatcher.history["100"]?.count == 1)
        #expect(state.gradeWatcher.snapshots.isEmpty)
    }

    @Test("switching school keeps the total purge, because the kept rows' ids belong to the old school")
    func schoolSwitchStillPurgesEverything() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1")], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Self.now)
        let history = try GradeHistoryStore(inMemory: true)
        history.record(courseID: "100", percent: 91.5, now: Self.now)
        let state = makeState(store: store, history: history)

        state.disconnectCanvas(keepingStudentWork: false)

        #expect(store.rowCount() == 0)
        #expect(history.allHistory().isEmpty)
    }

    @Test("the school switch passes the total purge and the Settings disconnect uses the default")
    func wiring() throws {
        let appState = try uiSource("AppState.swift")
        guard !appState.isEmpty else { return }
        #expect(appState.contains("disconnectCanvas(keepingStudentWork: false)"))
        #expect(appState.contains("func disconnectCanvas(keepingStudentWork: Bool = true)"))
        let settings = try uiSource("SettingsPage.swift")
        #expect(settings.contains("state.disconnectCanvas()"))
    }

    // MARK: The server deletion that can fail offline

    private struct Offline: Error {}

    private func scratchDefaults() -> UserDefaults {
        let name = "lhf.tests.pendingDeletion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a failed deletion is remembered, and a confirmed one clears the record")
    func failureIsRecordedSuccessClearsIt() async throws {
        let state = makeState(store: try AssignmentStore(inMemory: true))
        let defaults = scratchDefaults()

        let failed = await state.performBackendDeletion(defaults: defaults, afterConfirmed: { Issue.record("cleared on a failure") }) {
            throw Offline()
        }
        #expect(failed == false)
        #expect(PendingBackendDeletion.isPending(in: defaults))

        var cleared = 0
        let succeeded = await state.performBackendDeletion(defaults: defaults, afterConfirmed: { cleared += 1 }) { }
        #expect(succeeded)
        #expect(cleared == 1, "the local course-material cache goes only once the server has confirmed")
        #expect(!PendingBackendDeletion.isPending(in: defaults))
    }

    @Test("the record exists while the call is still in flight, so a kill mid-request cannot lose it")
    func recordedBeforeTheCall() async throws {
        let state = makeState(store: try AssignmentStore(inMemory: true))
        let defaults = scratchDefaults()
        var pendingDuringCall = false
        _ = await state.performBackendDeletion(defaults: defaults, afterConfirmed: {}) {
            pendingDuringCall = PendingBackendDeletion.isPending(in: defaults)
        }
        #expect(pendingDuringCall)
    }

    @Test("the next pass retries a remembered deletion until it succeeds, then stops")
    func retryUntilItSucceeds() async throws {
        let state = makeState(store: try AssignmentStore(inMemory: true))
        let defaults = scratchDefaults()
        PendingBackendDeletion.setPending(true, in: defaults)
        var calls = 0

        let first = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false) {
            calls += 1
            throw Offline()
        }
        #expect(first == .failed)
        #expect(PendingBackendDeletion.isPending(in: defaults))

        let second = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false, afterConfirmed: {}) { calls += 1 }
        #expect(second == .deleted)
        #expect(!PendingBackendDeletion.isPending(in: defaults))

        let third = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false) { calls += 1 }
        #expect(third == .nothingPending)
        #expect(calls == 2)
    }

    @Test("a student who has reconnected since is not deleted out from under their new session")
    func reconnectSupersedesTheRetry() async throws {
        let state = makeState(store: try AssignmentStore(inMemory: true))
        let defaults = scratchDefaults()
        PendingBackendDeletion.setPending(true, in: defaults)
        var called = false

        let attempt = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: true) { called = true }

        #expect(attempt == .superseded)
        #expect(!called)
        #expect(!PendingBackendDeletion.isPending(in: defaults))
    }

    @Test("the decision table")
    func decisionTable() {
        #expect(PendingBackendDeletion.decision(pending: false, canvasConnected: false) == .nothingPending)
        #expect(PendingBackendDeletion.decision(pending: false, canvasConnected: true) == .nothingPending)
        #expect(PendingBackendDeletion.decision(pending: true, canvasConnected: false) == .retry)
        #expect(PendingBackendDeletion.decision(pending: true, canvasConnected: true) == .dropSuperseded)
    }

    @Test("the retry rides the dashboard's launch pass and refresh, never blocks them, and the disconnect never waits on it")
    func retryWiring() throws {
        let content = try uiSource("ContentView.swift")
        guard !content.isEmpty else { return }
        let settle = try #require(content.range(of: "private func settleAfterFetch() async {"))
        let settleBody = String(content[settle.lowerBound...].prefix(900))
        #expect(settleBody.contains("state.startPendingBackendDeletionRetryIfNeeded()"))
        #expect(!settleBody.contains("await state.startPendingBackendDeletionRetryIfNeeded()"))
        let deletion = try uiSource("AppState+BackendDeletion.swift")
        let starter = try #require(deletion.range(of: "func startPendingBackendDeletionRetryIfNeeded() {"))
        #expect(String(deletion[starter.lowerBound...].prefix(500)).contains("Task {"))
        // The disconnect itself makes no network call.
        let appState = try uiSource("AppState.swift")
        let disconnect = try #require(appState.range(of: "func disconnectCanvas(keepingStudentWork: Bool = true) {"))
        let disconnectCode = String(appState[disconnect.lowerBound...].prefix(14_000))
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!disconnectCode.contains("deleteBackendData"))
        #expect(!disconnectCode.contains("deleteAccount"))
    }

    private func uiSource(_ filename: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI").appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
