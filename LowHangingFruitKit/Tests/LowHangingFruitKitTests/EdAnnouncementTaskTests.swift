import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Tasks found in Ed Discussion posts: which posts are read, the ledger rows
/// they become and how those rows name their origin, and the pass that reads
/// them (once each, with the Canvas path's extractor, gate and switches).
///
/// The pass is driven directly (`syncEdAnnouncementTasks(now:)`): an `AppState`
/// under the test runner starts nothing on its own. One test subscribes to the
/// knowledge base the way the app does, to pin the trigger.
///
/// The processed-ids ratchet is shared with the Canvas path and lives in the
/// shared defaults domain, so it is backed up and restored; every thread id and
/// class code here is unique to this suite.
@MainActor
@Suite("Ed announcement tasks", .serialized)
struct EdAnnouncementTaskTests {
    private static let day: TimeInterval = 24 * 3600
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let processedKey = "processedAnnouncementIDsV1"
    private static let retryKey = "edTaskRetryAfterV1"

    // MARK: Fixtures

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// An Ed document as the builder writes it, dated relative to `now`.
    private func document(
        _ thread: String,
        courseID: String = "9501",
        course: String = "EDTASK 9501",
        reason: String = "announcement",
        body: String = "Please submit the lab report by Friday.",
        daysAgo: Double? = 1,
        title: String = "Lab report",
        now: Date = EdAnnouncementTaskTests.now
    ) -> CourseDocument {
        AnnouncementEdRowsTests.edDocument(
            thread: thread, courseID: courseID, course: course, reason: reason, category: nil,
            body: body, daysAgo: daysAgo, title: title, now: now
        )
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        func reset() { lock.lock(); ids = []; lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    private struct Stub: AnnouncementAssignmentExtractor {
        let log: CallLog
        let tasks: [ExtractedAssignment]
        var fails = false
        struct Failure: Error {}
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            log.record(announcement.announcementID)
            if fails { throw Failure() }
            return tasks
        }
    }

    @MainActor
    private final class Harness {
        let state: AppState
        let store: AssignmentStore
        let calls = CallLog()
        var tasks: [ExtractedAssignment]
        var fails = false

        init(state: AppState, store: AssignmentStore, tasks: [ExtractedAssignment]) {
            self.state = state
            self.store = store
            self.tasks = tasks
        }

        var edRows: [Assignment] {
            store.assignments(source: .canvasAnnouncement).filter { $0.announcementOrigin == .ed }
        }
    }

    private func withHarness(
        tasks: [ExtractedAssignment] = [ExtractedAssignment(title: "Submit the lab report", dueAt: EdAnnouncementTaskTests.now.addingTimeInterval(2 * EdAnnouncementTaskTests.day), kind: .submission)],
        documents: [CourseDocument],
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let keys = [Self.extractionVersionKey, Self.processedKey, Self.retryKey]
        let saved = keys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: Self.extractionVersionKey)
        shared.removeObject(forKey: Self.processedKey)
        shared.removeObject(forKey: Self.retryKey)

        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        // The class the documents belong to: a feed item with its Canvas URL
        // is what gives `canvasCourseIDs()` an id -> code entry.
        state.canvasItems = [Assignment(
            source: .canvas, sourceID: "seed-9501", kind: .assignment, course: "EDTASK 9501",
            title: "Seed", dueAt: nil, url: URL(string: "https://canvas.upenn.edu/courses/9501/assignments/1")
        )]
        state.setCourse("EDTASK 9501", selected: true)
        defer {
            state.restoreCourse("EDTASK 9501")
            state.setCourse("EDTASK 9501", selected: true)
            state.coursePreferences.setCanvasCourseID("EDTASK 9501", nil)
        }
        state.courseKnowledge = CourseKnowledgeBase(documents: documents)

        let harness = Harness(state: state, store: store, tasks: tasks)
        state.announcementExtractorForTesting = { [harness] _ in
            Stub(log: harness.calls, tasks: harness.tasks, fails: harness.fails)
        }
        try await body(harness)
    }

    // MARK: Which posts are read

    @Test("announcements and pinned threads with text and recent activity are read; nothing else is")
    func eligibility() {
        let now = Self.now
        let announcement = document("9500001", reason: "announcement")
        let pinned = document("9500002", reason: "pinned")
        let staffPost = document("9500003", reason: "staff post")
        let imageOnly = document("9500004", body: "- [image]")
        let stale = document("9500005", daysAgo: 20)
        let undated = document("9500006", daysAgo: nil)
        let headerless = CourseDocument(
            courseID: "9501", course: "EDTASK 9501", kind: .ed, sourceID: "9500007", title: "t", url: nil,
            text: "No header, just words due Friday.", updatedAt: now.addingTimeInterval(-Self.day), fetchedAt: now
        )
        let canvasKind = CourseDocument(
            courseID: "9501", course: "EDTASK 9501", kind: .announcement, sourceID: "9500008", title: "t", url: nil,
            text: "[ed · announcement] looks like Ed", updatedAt: now.addingTimeInterval(-Self.day), fetchedAt: now
        )

        let eligible = AppState.edDocumentsEligibleForTasks(
            [announcement, pinned, staffPost, imageOnly, stale, undated, headerless, canvasKind, announcement],
            now: now
        )
        #expect(eligible.map(\.id) == [announcement.id, pinned.id])
    }

    // MARK: The rows

    @Test("an Ed task is a canvasAnnouncement row whose sourceID says Ed, with the thread's own link")
    func rowShape() {
        let doc = document("9500101")
        let rows = AppState.edAnnouncementAssignments(
            from: [
                ExtractedAssignment(title: "Submit the form", dueAt: Self.now, kind: .submission),
                ExtractedAssignment(title: "Read the handout", dueAt: nil, kind: .preparation),
            ],
            document: doc, courseCode: "EDTASK 9501"
        )
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.source == .canvasAnnouncement && $0.announcementOrigin == .ed })
        #expect(rows.map(\.sourceID) == ["ed-9501-9500101-0", "ed-9501-9500101-1"])
        #expect(rows.map(\.kind) == [.assignment, .event])
        #expect(rows.allSatisfy { $0.url == doc.url && $0.course == "EDTASK 9501" && !$0.submitted })
        #expect(rows[0].dueAt == Self.now && rows[1].dueAt == nil)
    }

    @Test("origin comes from the id: Ed finds read back as Ed, every other announcement row as Canvas, every other source as nothing")
    func originAndIDs() {
        let edID = AnnouncementRecord.edFindSourceID(courseID: "9501", threadID: "77", index: 2)
        #expect(edID == "ed-9501-77-2")
        #expect(AnnouncementRecord.edDocumentID(fromFindSourceID: edID) == "ed:9501:77")
        #expect(AnnouncementRecord.announcementID(fromFindSourceID: edID) == nil)
        #expect(AnnouncementRecord.recordID(fromFindSourceID: edID) == "ed:9501:77")

        let canvasID = AnnouncementRecord.findSourceID(announcementID: "55", index: 0)
        #expect(AnnouncementRecord.recordID(fromFindSourceID: canvasID) == "55")
        #expect(AnnouncementRecord.edDocumentID(fromFindSourceID: canvasID) == nil)
        for malformed in ["ed-", "ed-1-2", "ed-1-x-0", "ed-1-2-", "other-1-2-3", ""] {
            #expect(AnnouncementRecord.edDocumentID(fromFindSourceID: malformed) == nil)
        }

        func row(_ source: Assignment.Source, _ sourceID: String) -> Assignment {
            Assignment(source: source, sourceID: sourceID, kind: .assignment, course: "EDTASK 9501",
                       title: "T", dueAt: nil, url: nil)
        }
        #expect(row(.canvasAnnouncement, edID).announcementOrigin == .ed)
        #expect(row(.canvasAnnouncement, canvasID).announcementOrigin == .canvas)
        // Rows from before the prefix existed carry arbitrary ids and are Canvas.
        #expect(row(.canvasAnnouncement, "real-task-0").announcementOrigin == .canvas)
        #expect(row(.canvas, edID).announcementOrigin == nil)
    }

    @Test("Ed rows keep the existing source on disk: no new raw value, no new column, and they survive a reopen")
    func ledgerRoundTrip() throws {
        let url = URL.temporaryDirectory.appending(path: "ed-tasks-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }

        let rows = AppState.edAnnouncementAssignments(
            from: [ExtractedAssignment(title: "Submit the form", dueAt: Self.now, kind: .submission)],
            document: document("9500201"), courseCode: "EDTASK 9501"
        )
        let first = try AssignmentStore(url: url)
        first.upsert(rows)
        first.markGoneFromFeed(ids: [rows[0].id])

        let second = try AssignmentStore(url: url)
        let stored = try #require(second.allRowsForTesting().first)
        // The point: an older build reads this row with the cases it knows.
        #expect(stored.sourceRaw == "canvasAnnouncement")
        #expect(Assignment.Source(rawValue: stored.sourceRaw) == .canvasAnnouncement)
        #expect(stored.id == rows[0].id)
        #expect(stored.assignment.announcementOrigin == .ed)
        #expect(stored.assignment.title == "Submit the form")
        #expect(stored.isGoneFromFeed)
        #expect(second.assignments(source: .canvasAnnouncement).map(\.sourceID) == ["ed-9501-9500201-0"])
    }

    // MARK: The pass

    @Test("a pass reads each eligible post once, files its tasks as Ed rows, and a card appears")
    func passReadsOnce() async throws {
        let doc = document("9500301")
        try await withHarness(documents: [doc]) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)

            #expect(h.calls.all == [doc.id])
            #expect(h.edRows.map(\.title) == ["Submit the lab report"])
            #expect(h.edRows.first?.announcementOrigin == .ed)
            #expect(h.state.processedAnnouncementIDs.contains(doc.id))
            #expect(UserDefaults.lhf.stringArray(forKey: Self.processedKey)?.contains(doc.id) == true)

            // Not read again.
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all == [doc.id])
            #expect(h.edRows.count == 1)

            // The card: due two days after `now`, so check against that clock.
            h.state.rebuildDashboardItemsForTesting(now: Self.now)
            let cards = (h.state.assignments + h.state.laterAssignments + h.state.assessments)
                .filter { $0.course == "EDTASK 9501" && $0.announcementOrigin == .ed }
            #expect(cards.map(\.title) == ["Submit the lab report"])
        }
    }

    @Test("a post that yields no task is still marked read; an informational one is never sent to an extractor")
    func emptyAndInformationalPosts() async throws {
        let nothing = document("9500401", body: "Welcome to the course.", title: "Hello")
        let informational = document("9500402", body: "The slides discussed today have been posted.", title: "Slides posted")
        try await withHarness(tasks: [], documents: [nothing, informational]) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all == [nothing.id])
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: [nothing.id, informational.id]))
            #expect(h.edRows.isEmpty)
        }
    }

    @Test("a failed extraction leaves the post unread, and it is tried again once its wait is over")
    func failureIsRetried() async throws {
        let doc = document("9500501")
        try await withHarness(documents: [doc]) { h in
            h.fails = true
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all == [doc.id])
            #expect(!h.state.processedAnnouncementIDs.contains(doc.id))
            #expect(h.edRows.isEmpty)

            h.fails = false
            await h.state.syncEdAnnouncementTasks(now: Self.now.addingTimeInterval(AppState.edTaskRetryInterval + 1))
            #expect(h.calls.all == [doc.id, doc.id])
            #expect(h.edRows.count == 1)
            #expect(UserDefaults.lhf.object(forKey: Self.retryKey) == nil, "a post that was read has nothing left to wait for")
        }
    }

    /// Every sync replaces the course material, and the pass runs after each.
    /// A backend that is down (or a quota `ask` shares and has used up) would
    /// be asked for the same post again on every one of them.
    @Test("a post whose read failed is not asked for again until six hours have passed, however often the material changes")
    func failedReadWaits() async throws {
        let doc = document("9500502")
        try await withHarness(documents: [doc]) { h in
            h.fails = true
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all == [doc.id])

            for minutes in [1.0, 30, 120, 359] {
                await h.state.syncEdAnnouncementTasks(now: Self.now.addingTimeInterval(minutes * 60))
            }
            #expect(h.calls.all == [doc.id], "four more passes inside the wait, no more requests")

            await h.state.syncEdAnnouncementTasks(now: Self.now.addingTimeInterval(6 * 3600 + 1))
            #expect(h.calls.all == [doc.id, doc.id], "and one request once the wait is over")

            // Failing again starts another wait from that moment.
            await h.state.syncEdAnnouncementTasks(now: Self.now.addingTimeInterval(7 * 3600))
            #expect(h.calls.all == [doc.id, doc.id])
        }
    }

    @Test("the wait outlives the app: it is saved, and a post waiting is not in the eligible set")
    func waitIsPersisted() async throws {
        let doc = document("9500503")
        try await withHarness(documents: [doc]) { h in
            h.fails = true
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            let saved = AppState.loadEdTaskRetryAfter()
            #expect(saved[doc.id] == Self.now.addingTimeInterval(AppState.edTaskRetryInterval))

            #expect(AppState.edDocumentsEligibleForTasks([doc], now: Self.now, retryAfter: saved).isEmpty)
            #expect(AppState.edDocumentsEligibleForTasks(
                [doc], now: Self.now.addingTimeInterval(AppState.edTaskRetryInterval), retryAfter: saved
            ).map(\.id) == [doc.id])
            // What has expired is dropped when the dictionary is saved again.
            AppState.saveEdTaskRetryAfter(saved, now: Self.now.addingTimeInterval(AppState.edTaskRetryInterval + 1))
            #expect(AppState.loadEdTaskRetryAfter().isEmpty)
        }
    }

    // MARK: A class that goes away during the read

    /// What `disconnectCanvas` does to the class map: the feed is emptied and
    /// the saved id -> code cache is cleared. (Only this suite's class is
    /// cleared from the cache, not all of them: the cache lives in the shared
    /// defaults, and other suites' classes are not this test's to forget.)
    private static func simulateDisconnect(_ state: AppState) {
        state.canvasItems = []
        state.coursePreferences.setCanvasCourseID("EDTASK 9501", nil)
    }

    /// The extractor is a network call. These stage "Canvas is disconnected, or
    /// the class hidden, while it is in flight" by doing it from inside the
    /// extractor, which is the one place that is exactly mid-await.
    @Test("Canvas disconnected while a post is being read: no row, and no read-id that would outlive the disconnect")
    func disconnectDuringRead() async throws {
        let doc = document("9500511")
        try await withHarness(documents: [doc]) { h in
            h.state.announcementExtractorForTesting = { [h] _ in
                Self.simulateDisconnect(h.state)
                return Stub(log: h.calls, tasks: h.tasks)
            }
            await h.state.syncEdAnnouncementTasks(now: Self.now)

            #expect(h.calls.all == [doc.id], "it was read before the disconnect")
            #expect(h.edRows.isEmpty)
            #expect(!h.state.processedAnnouncementIDs.contains(doc.id))
            #expect(AppState.loadEdTaskRetryAfter().isEmpty, "and it is not blamed on the backend")
        }
    }

    @Test("the class hidden while a post is being read: no row, and the post is read again when the class is shown")
    func hideDuringRead() async throws {
        let doc = document("9500512")
        try await withHarness(documents: [doc]) { h in
            h.state.announcementExtractorForTesting = { [h] _ in
                h.state.setCourse("EDTASK 9501", selected: false)
                return Stub(log: h.calls, tasks: h.tasks)
            }
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.edRows.isEmpty)
            #expect(!h.state.processedAnnouncementIDs.contains(doc.id))

            h.state.announcementExtractorForTesting = { [h] _ in Stub(log: h.calls, tasks: h.tasks) }
            h.state.setCourse("EDTASK 9501", selected: true)
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.edRows.count == 1)
            #expect(h.state.processedAnnouncementIDs.contains(doc.id))
        }
    }

    @Test("a disconnect during the second post's read also drops the first post's result")
    func disconnectDuringALaterRead() async throws {
        let first = document("9500513")
        let second = document("9500514", title: "Second")
        try await withHarness(documents: [first, second]) { h in
            h.state.announcementExtractorForTesting = { [h] announcement in
                if announcement.id == second.id { Self.simulateDisconnect(h.state) }
                return Stub(log: h.calls, tasks: h.tasks)
            }
            await h.state.syncEdAnnouncementTasks(now: Self.now)

            #expect(Set(h.calls.all) == [first.id, second.id])
            #expect(h.edRows.isEmpty, "the first post's rows are as unwanted as the second's")
            #expect(h.state.processedAnnouncementIDs.isDisjoint(with: [first.id, second.id]))
        }
    }

    @Test("a hidden class's posts are not read, and are read once the class is shown again")
    func hiddenClassIsNotRead() async throws {
        let doc = document("9500601")
        try await withHarness(documents: [doc]) { h in
            h.state.setCourse("EDTASK 9501", selected: false)
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all.isEmpty)
            #expect(!h.state.processedAnnouncementIDs.contains(doc.id))

            h.state.setCourse("EDTASK 9501", selected: true)
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all == [doc.id])
            #expect(h.edRows.count == 1)
        }
    }

    @Test("a post for a Canvas site the app does not know is left unread")
    func unknownSiteIsLeftUnread() async throws {
        let doc = document("9500611", courseID: "9599", course: "EDTASK 9599")
        try await withHarness(documents: [doc]) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all.isEmpty)
            #expect(!h.state.processedAnnouncementIDs.contains(doc.id))
        }
    }

    @Test("disconnecting Canvas deletes the Ed tasks and forgets which posts were read, and nothing brings them back while disconnected")
    func disconnectClearsEdTasks() async throws {
        let doc = document("9500621")
        try await withHarness(documents: [doc]) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.edRows.count == 1)
            #expect(h.state.processedAnnouncementIDs.contains(doc.id))

            h.state.disconnectCanvas()
            #expect(h.edRows.isEmpty)
            #expect(h.state.announcementItems.isEmpty)
            #expect(!h.state.processedAnnouncementIDs.contains(doc.id))
            #expect(UserDefaults.lhf.stringArray(forKey: Self.processedKey)?.contains(doc.id) != true)

            // The post is still in the cached course material; with no Canvas
            // account behind it, a pass reads nothing.
            h.calls.reset()
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all.isEmpty)
            #expect(h.edRows.isEmpty)
        }
    }

    @Test("two tasks in one post get distinct ids, and re-running does not duplicate them")
    func twoTasksOnePost() async throws {
        let doc = document("9500701")
        let tasks = [
            ExtractedAssignment(title: "Submit part one", dueAt: Self.now.addingTimeInterval(Self.day), kind: .submission),
            ExtractedAssignment(title: "Submit part one", dueAt: Self.now.addingTimeInterval(Self.day), kind: .preparation),
        ]
        try await withHarness(tasks: tasks, documents: [doc]) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(Set(h.edRows.map(\.sourceID)) == ["ed-9501-9500701-0", "ed-9501-9500701-1"])
        }
    }

    @Test("an Ed task and the same task on Canvas are one card, even when both were found by their own pass")
    func edAndCanvasPassesMeetInOneCard() async throws {
        let doc = document("9500801")
        try await withHarness(documents: [doc]) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            // The Canvas copy, as `syncAnnouncements` would file it.
            h.store.upsert([Assignment(
                source: .canvasAnnouncement,
                sourceID: AnnouncementRecord.findSourceID(announcementID: "9500802", index: 0),
                kind: .assignment, course: "EDTASK 9501", title: "Submit the lab report",
                dueAt: Self.now.addingTimeInterval(2 * Self.day),
                url: URL(string: "https://canvas.upenn.edu/courses/9501/discussion_topics/9500802")
            )])
            h.state.applyAnnouncementLedgerChange()
            h.state.rebuildDashboardItemsForTesting(now: Self.now)

            let cards = (h.state.assignments + h.state.laterAssignments + h.state.assessments)
                .filter { $0.course == "EDTASK 9501" && $0.source == .canvasAnnouncement }
            #expect(cards.count == 1)
            #expect(cards.first?.announcementOrigin == .canvas)
        }
    }

    // MARK: Triggering

    @Test("a change to the course knowledge runs a pass, and a change that lands while one is running is not lost")
    func knowledgeChangeTriggersPass() async throws {
        let first = document("9500901")
        let second = document("9500902", title: "Second")
        try await withHarness(documents: []) { h in
            h.state.observeKnowledgeForEdTasks()
            // The extractor for the first post is where "a second sync lands
            // mid-pass" is staged: it publishes new knowledge while the pass
            // is awaiting it. A pass that did not go round again would read
            // only `first`.
            h.state.announcementExtractorForTesting = { [h] announcement in
                if announcement.id == first.id {
                    h.state.courseKnowledge = CourseKnowledgeBase(documents: [first, second])
                }
                return Stub(log: h.calls, tasks: h.tasks)
            }

            h.state.courseKnowledge = CourseKnowledgeBase(documents: [first])
            await h.state.edTaskPassTask?.value

            #expect(h.calls.all == [first.id, second.id])
            #expect(h.state.edTaskPassTask == nil)
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: [first.id, second.id]))
        }
    }

    @Test("a subscription that was never installed reads nothing by itself")
    func noSubscriptionNoPass() async throws {
        let doc = document("9500903")
        try await withHarness(documents: []) { h in
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [doc])
            #expect(h.state.edTaskPassTask == nil)
            #expect(h.calls.all.isEmpty)
        }
    }

    @Test("nothing is read in preview mode")
    func notInPreview() async throws {
        let doc = document("9501001")
        try await withHarness(documents: [doc]) { h in
            h.state.forceFixtureDataForTesting(true)
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all.isEmpty)
            h.state.forceFixtureDataForTesting(false)
        }
    }
}
