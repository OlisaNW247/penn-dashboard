import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Save first, then forget (hardening plan 2026-10-25, B5: DAT-07).
///
/// The store used to swallow a failed save. Two callers then discarded their
/// only other copy on the strength of rows that were still in memory: the
/// launch migration removed the legacy manual-task blob, and the announcement
/// sync recorded a post as read, which is a ratchet (a recorded id is never
/// sent to an extractor again). A full disk, or protected data not yet
/// available, and the student's own tasks or a professor's deadline were gone
/// for good, with the dashboard looking fine until the next launch.
///
/// A failed save is provoked through `AssignmentStore.saveFailureForTesting`,
/// which fails every save that has something to save and, like the real
/// failure, leaves the changes pending in the context.
struct LedgerSaveConfirmationTests {

    private struct InjectedSaveFailure: Error {}
    private struct InjectedReadFailure: Error {}

    private func item(_ id: String, source: Assignment.Source = .canvas) -> Assignment {
        Assignment(source: source, sourceID: id, kind: .assignment,
                   course: "SAVEFIRST 100", title: "HW \(id)",
                   dueAt: Date().addingTimeInterval(5 * 86_400), url: nil)
    }

    private func tempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-savefirst-\(UUID().uuidString).store")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    // MARK: The store says whether a write landed

    @MainActor
    @Test("upsert reports a failed save, and the count of new rows is unaffected")
    func upsertReportsSaveOutcome() throws {
        let store = try AssignmentStore(inMemory: true)

        store.saveFailureForTesting = InjectedSaveFailure()
        let failed = store.upsert([item("1"), item("2")])
        #expect(failed.created == 2)
        #expect(!failed.saved)
        #expect(store.failedSaveCount >= 1)

        store.saveFailureForTesting = nil
        let landed = store.upsert([item("3")])
        #expect(landed.created == 1)
        #expect(landed.saved)
    }

    @MainActor
    @Test("upserting nothing, and completing nothing, are successes")
    func nothingToDoIsASuccess() throws {
        let store = try AssignmentStore(inMemory: true)
        store.saveFailureForTesting = InjectedSaveFailure()
        #expect(store.upsert([]).saved)
        #expect(store.setCompleted(ids: [], at: nil))
        #expect(store.delete(ids: []))
        #expect(store.recordPairings([]))
        #expect(store.failedSaveCount == 0, "none of them tried to save")
    }

    @MainActor
    @Test("setCompleted, delete, recordPairings and reconcile each report a failed save")
    func everyMutatorReportsAFailedSave() throws {
        let store = try AssignmentStore(inMemory: true)
        let canvas = item("c", source: .canvas)
        let gradescope = item("g", source: .gradescope)
        _ = store.reconcile([canvas], source: .canvas)
        _ = store.reconcile([gradescope], source: .gradescope)
        #expect(store.failedSaveCount == 0)

        store.saveFailureForTesting = InjectedSaveFailure()
        #expect(!store.setCompleted(ids: [canvas.id], at: Date()))
        #expect(!store.recordPairings([AssignmentDeduplicator.Match(canvasID: canvas.id, gradescopeID: gradescope.id)]))
        #expect(!store.delete(ids: [gradescope.id]))
        let reconciled = store.reconcile([canvas, item("new")], source: .canvas)
        #expect(!reconciled.saved)
        #expect(!reconciled.readFailed)

        // The next save that works carries everything that was pending, and
        // every mutator reports success again.
        store.saveFailureForTesting = nil
        #expect(store.setCompleted(ids: ["canvas:new"], at: Date()))
        #expect(store.reconcile([canvas, item("new")], source: .canvas).saved)
        #expect(store.completionRecordOrFail().ids == [canvas.id, "canvas:new"])
    }

    @MainActor
    @Test("a failed save is not on disk, and the next one that works writes what was pending")
    func failedSaveIsNotDurable() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        let store = try AssignmentStore(url: url)

        store.saveFailureForTesting = InjectedSaveFailure()
        #expect(!store.upsert([item("kept")]).saved)
        // A second store over the same file sees only what reached it.
        #expect(try AssignmentStore(url: url).rowCount() == 0, "the row was only in memory")

        store.saveFailureForTesting = nil
        #expect(store.upsert([item("other")]).saved)
        #expect(try AssignmentStore(url: url).rowCount() == 2, "the pending row went out with the next good save")
    }

    @MainActor
    @Test("an un-tick that cannot find its row says so; a tick is still written")
    func unreadableLedgerAndCompletion() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([item("1")], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Date())

        store.readFailureForTesting = InjectedReadFailure()
        #expect(!store.setCompleted(ids: [], at: nil, clearing: ["canvas:1"]),
                "reporting success for an un-tick that did nothing would be a lie")
        #expect(store.setCompleted(ids: ["canvas:2"], at: Date()),
                "a tick only adds, so it is written even though the ledger cannot be read")

        store.readFailureForTesting = nil
        #expect(store.completionRecordOrFail().ids == ["canvas:1", "canvas:2"],
                "the un-tick did not happen, and the tick was kept")
    }

    // MARK: The legacy manual-task blob

    private static let blobKey = "manualAssignments"

    /// A scratch defaults suite holding the pre-ledger blob of the student's
    /// own tasks, which is the only copy of them until the ledger holds them.
    @MainActor
    private func withBlob(
        _ tasks: [ManualAssignment],
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suite = "lhf.savefirst-blob.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(tasks), forKey: Self.blobKey)
        try body(defaults)
    }

    @MainActor
    @Test("the legacy task blob stays, and so do the tasks, when the save that should hold them fails")
    func blobStaysWhenTheSaveFails() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        let tasks = [ManualAssignment(title: "Call the advisor", course: "SAVEFIRST 100",
                                      dueAt: Date().addingTimeInterval(86_400))]
        try withBlob(tasks) { defaults in
            let store = try AssignmentStore(url: url)
            store.saveFailureForTesting = InjectedSaveFailure()

            let state = AppState(assignmentStore: store, ownTasksDefaults: defaults)

            #expect(defaults.data(forKey: Self.blobKey) != nil, "the blob is the only durable copy")
            #expect(state.manualAssignments.map(\.title) == ["Call the advisor"])
            #expect(try AssignmentStore(url: url).rowCount() == 0, "and nothing else holds the tasks yet")
        }
    }

    @MainActor
    @Test("once the save has landed the blob is released and the tasks come from the ledger")
    func blobIsReleasedAfterTheSave() throws {
        let url = tempStoreURL()
        defer { removeStore(at: url) }
        let tasks = [ManualAssignment(title: "Call the advisor", course: "SAVEFIRST 100",
                                      dueAt: Date().addingTimeInterval(86_400))]
        try withBlob(tasks) { defaults in
            let store = try AssignmentStore(url: url)

            let state = AppState(assignmentStore: store, ownTasksDefaults: defaults)

            #expect(defaults.data(forKey: Self.blobKey) == nil)
            #expect(state.manualAssignments.map(\.title) == ["Call the advisor"])
            #expect(try AssignmentStore(url: url).assignments(source: .manual).map(\.title) == ["Call the advisor"])
        }
    }
}

// MARK: - Announcement ids

/// The announcement sync, end to end with no network, over a ledger whose
/// saves can be made to fail. Nested under the serialized parent because the
/// sync writes `processedAnnouncementIDsV1` and the retry counters in the
/// shared defaults domain (see `AnnouncementExtractionSuites`); each key is
/// backed up and restored, as in `AnnouncementLogSyncTests`.
extension AnnouncementExtractionSuites {
    @Suite("Announcement ids are recorded only after the save")
    struct AnnouncementSaveFirstTests {
        private static let day: TimeInterval = 24 * 60 * 60
        private static let course = (id: "9201", code: "ANSAVE 9201")
        private static let sharedKeys = [
            "processedAnnouncementIDsV1", "announcementExtractionVersionV1",
            "announcementExtractionAttemptsV1", "announcementExtractionBackoffUntilV1",
        ]

        private struct InjectedSaveFailure: Error {}

        /// One task per post, so "extraction produced a row" is the same as "was extracted".
        private struct OneTaskExtractor: AnnouncementAssignmentExtractor {
            func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
                [ExtractedAssignment(title: "Submit \(announcement.announcementID)", dueAt: nil, kind: .submission)]
            }
        }

        private func post(_ id: String, now: Date, title: String, message: String) -> CanvasAnnouncement {
            CanvasAnnouncement(
                id: id, courseID: Self.course.id, title: title, message: message,
                postedAt: now.addingTimeInterval(-2 * Self.day),
                url: URL(string: "https://canvas.upenn.edu/courses/\(Self.course.id)/discussion_topics/\(id)")
            )
        }

        @MainActor
        private func withSyncingState(
            posts: [CanvasAnnouncement],
            _ body: (AppState, AssignmentStore) async throws -> Void
        ) async throws {
            let shared = UserDefaults.lhf
            let backup = Self.sharedKeys.map { ($0, shared.object(forKey: $0)) }
            defer {
                for (key, value) in backup {
                    if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
                }
            }
            // Pin the repair version so `AppState.init`'s one-time sweep is a
            // no-op, and start with nothing processed.
            shared.set(2, forKey: "announcementExtractionVersionV1")
            shared.removeObject(forKey: "processedAnnouncementIDsV1")
            shared.removeObject(forKey: "announcementExtractionAttemptsV1")
            shared.removeObject(forKey: "announcementExtractionBackoffUntilV1")

            let store = try AssignmentStore(inMemory: true)
            let state = AppState(assignmentStore: store)
            state.forceFixtureDataForTesting(false)
            state.canvasItems = [Assignment(
                source: .canvas, sourceID: "seed-\(Self.course.id)", kind: .assignment,
                course: Self.course.code, title: "Seed", dueAt: nil,
                url: URL(string: "https://canvas.upenn.edu/courses/\(Self.course.id)/assignments/1")
            )]
            state.setCourse(Self.course.code, selected: true)
            defer {
                state.restoreCourse(Self.course.code)
                state.setCourse(Self.course.code, selected: true)
                state.coursePreferences.setCanvasCourseID(Self.course.code, nil)
            }
            state.announcementFetchForTesting = { _, _, _ in posts }
            state.announcementExtractorForTesting = { _ in OneTaskExtractor() }
            try await body(state, store)
        }

        @MainActor
        @Test("a post whose rows were not saved is not recorded as read, and is read again once saves work")
        func failedSaveLeavesThePostUnread() async throws {
            let now = Date()
            let actionable = post("9201001", now: now, title: "Please submit your essay by Friday",
                                  message: "Please submit your essay by Friday. It is worth 10 percent.")
            try await withSyncingState(posts: [actionable]) { state, store in
                store.saveFailureForTesting = InjectedSaveFailure()
                await state.syncAnnouncements(now: now)
                #expect(!state.processedAnnouncementIDs.contains("9201001"),
                        "recorded as read, the task would never be extracted again")
                #expect(!(UserDefaults.lhf.stringArray(forKey: "processedAnnouncementIDsV1") ?? []).contains("9201001"))

                store.saveFailureForTesting = nil
                await state.syncAnnouncements(now: now)
                #expect(state.processedAnnouncementIDs.contains("9201001"))
                #expect(store.assignments(source: .canvasAnnouncement).map(\.sourceID) == ["announcement-9201001-0"],
                        "read again, and filed once, not twice")
            }
        }

        @MainActor
        @Test("a post that needed no row is recorded even when the save fails")
        func informationalPostIsStillRecorded() async throws {
            let now = Date()
            #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Recording is up", body: "See Canvas."))
            let informational = post("9201002", now: now, title: "Recording is up", message: "See Canvas.")
            let actionable = post("9201003", now: now, title: "Please submit your essay by Friday",
                                  message: "Please submit your essay by Friday. It is worth 10 percent.")
            try await withSyncingState(posts: [informational, actionable]) { state, store in
                store.saveFailureForTesting = InjectedSaveFailure()
                await state.syncAnnouncements(now: now)
                #expect(state.processedAnnouncementIDs.contains("9201002"), "nothing to lose, so nothing to wait for")
                #expect(!state.processedAnnouncementIDs.contains("9201003"))
            }
        }

        @MainActor
        @Test("with saves working the post is recorded on the first pass")
        func healthySaveRecordsThePost() async throws {
            let now = Date()
            let actionable = post("9201004", now: now, title: "Please submit your essay by Friday",
                                  message: "Please submit your essay by Friday. It is worth 10 percent.")
            try await withSyncingState(posts: [actionable]) { state, store in
                await state.syncAnnouncements(now: now)
                #expect(state.processedAnnouncementIDs.contains("9201004"))
                #expect(store.assignments(source: .canvasAnnouncement).count == 1)
            }
        }
    }
}
