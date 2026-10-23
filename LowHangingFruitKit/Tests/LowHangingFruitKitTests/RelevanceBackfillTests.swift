import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The judgment backfill and the flag that switches it on
/// (`AppState+RelevanceBackfill.swift`, `ServerJudgesRelevance`), driven
/// through an `AppState` the way `AnnouncementRelevanceSyncTests` drives the
/// passes. Two real-phone problems are pinned here: posts read before
/// judgments existed never got one, and a post read while the server did not
/// yet judge (or a staff post read for nothing but a judgment) wasted its one
/// read.
///
/// **Hermeticity.** As in `AnnouncementRelevanceSyncTests`: the log in a temp
/// directory, the judgments in a scratch suite, the fetch and extractor as
/// per-instance seams, the process-wide extraction keys backed up and
/// restored, and the flag, the budget and the backfill ledger memory-only
/// (the `AppState` default under the test runner). The suite sits under
/// `AnnouncementExtractionSuites` for the shared keys. Class codes and ids
/// are unique to this file.
extension AnnouncementExtractionSuites {
@MainActor
@Suite("Relevance backfill: the flag, the backfill, the shared daily budget", .serialized)
struct RelevanceBackfillTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let course = "BACKF 7301"
    private static let courseID = "7301"
    private static let sharedKeys = [
        "announcementExtractionVersionV1", "processedAnnouncementIDsV1", "edTaskRetryAfterV1",
        "announcementExtractionAttemptsV1", "announcementExtractionBackoffUntilV1",
    ]

    /// Noon UTC today, so a test that steps an hour or a day never straddles
    /// the budget's UTC midnight by accident.
    private static var noonUTC: Date {
        Date(timeIntervalSince1970: (Double(RelevanceReadBudget.utcDay(of: Date())) + 0.5) * 86_400)
    }

    // MARK: Stubs

    private struct Judging: AnnouncementAssignmentExtractor {
        var tasks: [ExtractedAssignment] = []
        var relevanceByID: [String: AnnouncementRelevance] = [:]
        var failing: Set<String> = []
        var calls: CallLog?
        struct Failure: Error {}

        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            tasks
        }

        func extractWithRelevance(from announcement: AnnouncementSourceText, now: Date) async throws -> AnnouncementExtraction {
            calls?.record(announcement.announcementID)
            if failing.contains(announcement.announcementID) { throw Failure() }
            return AnnouncementExtraction(assignments: tasks, relevance: relevanceByID[announcement.announcementID])
        }
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func record(_ id: String) { lock.lock(); seen.append(id); lock.unlock() }
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    @MainActor
    private final class Harness {
        let state: AppState
        let store: AssignmentStore
        let scratch: UserDefaults
        var response: [CanvasAnnouncement] = []
        var extractor = Judging()
        let calls = CallLog()

        init(state: AppState, store: AssignmentStore, scratch: UserDefaults) {
            self.state = state
            self.store = store
            self.scratch = scratch
        }

        var stored: [String: AnnouncementRelevance] { AnnouncementRelevanceStore(defaults: scratch).all }
        var ledgerRows: [Assignment] { store.assignments(source: .canvasAnnouncement) }
    }

    private func withHarness(
        serverJudges: Bool,
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let saved = Self.sharedKeys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: "announcementExtractionVersionV1")
        for key in Self.sharedKeys.dropFirst() { shared.removeObject(forKey: key) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relevance-backfill-\(UUID().uuidString)", isDirectory: true)
        let scratchName = "relevance-backfill-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: scratchName)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            scratch.removePersistentDomain(forName: scratchName)
        }

        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.enableAnnouncementLogForTesting(directory: directory, defaults: scratch)
        if serverJudges { state.serverJudgesRelevance.markSeen() }
        state.canvasItems = [
            Assignment(
                source: .canvas, sourceID: "seed-\(Self.courseID)", kind: .assignment, course: Self.course,
                title: "Seed", dueAt: nil,
                url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/assignments/1")
            ),
        ]
        state.setCourse(Self.course, selected: true)
        defer {
            state.restoreCourse(Self.course)
            state.setCourse(Self.course, selected: true)
            state.coursePreferences.setCanvasCourseID(Self.course, nil)
        }
        #expect(state.selectedCanvasCourseIDs().keys.contains(Self.courseID))

        let harness = Harness(state: state, store: store, scratch: scratch)
        state.announcementFetchForTesting = { [harness] _, _, _ in harness.response }
        harness.extractor.calls = harness.calls
        state.announcementExtractorForTesting = { [harness] _ in harness.extractor }
        try await body(harness)
    }

    private func post(
        _ id: String,
        daysAgo: Double,
        now: Date,
        title: String = "Please submit the lab report",
        message: String = "Please submit the lab report by Friday."
    ) -> CanvasAnnouncement {
        CanvasAnnouncement(
            id: id, courseID: Self.courseID, title: title, message: message,
            postedAt: now.addingTimeInterval(-daysAgo * Self.day),
            url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/discussion_topics/\(id)")
        )
    }

    private func edDocument(
        _ thread: String,
        now: Date,
        reason: String = "announcement",
        daysAgo: Double = 1,
        title: String = "Lab report",
        body: String = "Please submit the lab report by Friday."
    ) -> CourseDocument {
        AnnouncementEdRowsTests.edDocument(
            thread: thread, courseID: Self.courseID, course: Self.course, reason: reason, category: nil,
            body: body, daysAgo: daysAgo, title: title, now: now
        )
    }

    private func key(_ id: String) -> String { AnnouncementReadState.recordKey(id) }
    private func edKey(_ id: String) -> String { AnnouncementReadState.edKey(id) }
    private let someTask = ExtractedAssignment(title: "Hand in the worksheet", dueAt: nil, kind: .submission)
    private func standing() -> AnnouncementRelevance { AnnouncementRelevance(kind: .standing) }

    // MARK: The flag

    @Test("before the flag is set, an Ed staff post is not read at all: no call, no budget, not processed, no retry clock; the announcement beside it is read as ever")
    func staffPostsWaitForTheFlag() async throws {
        try await withHarness(serverJudges: false) { h in
            let now = Self.noonUTC
            let announcement = edDocument("73101", now: now, reason: "announcement", daysAgo: 2)
            let staff = edDocument("73102", now: now, reason: "staff post", daysAgo: 1)
            h.extractor.tasks = [someTask]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [staff, announcement])
            await h.state.syncEdAnnouncementTasks(now: now)

            #expect(h.calls.ids == [announcement.id], "only the announcement is sent")
            #expect(h.state.processedAnnouncementIDs.contains(announcement.id))
            #expect(!h.state.processedAnnouncementIDs.contains(staff.id))
            #expect(h.state.relevanceReadBudget.used(on: now) == 0)
            #expect(AppState.loadEdTaskRetryAfter()[staff.id] == nil)
            #expect(UserDefaults.lhf.dictionary(forKey: "announcementExtractionAttemptsV1")?[staff.id] == nil)
            #expect(h.ledgerRows.count == 1, "the announcement still files its task")
            #expect(!h.state.serverJudgesRelevance.isSet, "an answer with no judgment does not set the flag")

            // A board with nothing but staff posts is not a run at all.
            await h.state.syncEdAnnouncementTasks(now: now.addingTimeInterval(3600))
            #expect(h.calls.ids == [announcement.id])
            #expect(!h.state.processedAnnouncementIDs.contains(staff.id))
        }
    }

    @Test("a judgment in the same run turns the staff read on: announcements are read first, so the staff post after them is read")
    func aJudgmentInTheRunUnlocksTheStaffRead() async throws {
        try await withHarness(serverJudges: false) { h in
            let now = Self.noonUTC
            let announcement = edDocument("73111", now: now, reason: "announcement", daysAgo: 2)
            let staff = edDocument("73112", now: now, reason: "staff post", daysAgo: 1)
            h.extractor.relevanceByID = [
                announcement.id: standing(), staff.id: AnnouncementRelevance(kind: .news),
            ]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [staff, announcement])
            await h.state.syncEdAnnouncementTasks(now: now)

            #expect(h.calls.ids == [announcement.id, staff.id])
            #expect(h.state.serverJudgesRelevance.isSet)
            #expect(h.state.relevanceReadBudget.used(on: now) == 1)
            #expect(h.stored[edKey(staff.id)]?.kind == .news)
        }
    }

    @Test("the Canvas sync sets the flag from an answer that carries a judgment, and not from one that does not or from a local news judgment")
    func canvasSyncSetsTheFlag() async throws {
        try await withHarness(serverJudges: false) { h in
            let now = Self.noonUTC
            // A post the extractor gives no judgment for, and one that reads
            // as information (news on the phone, no server involved).
            h.response = [
                post("73121", daysAgo: 2, now: now),
                post("73122", daysAgo: 1, now: now, title: "Recording is up", message: "See Canvas."),
            ]
            await h.state.syncAnnouncements(now: now)
            #expect(h.stored[key("73122")]?.kind == .news)
            #expect(!h.state.serverJudgesRelevance.isSet)

            h.response.append(post("73123", daysAgo: 1, now: now))
            h.extractor.relevanceByID = ["73123": standing()]
            await h.state.syncAnnouncements(now: now.addingTimeInterval(60))
            #expect(h.state.serverJudgesRelevance.isSet)
        }
    }

    @Test("the flag is kept in the defaults it was given, read back by a fresh one, and nothing reaches the shared domain")
    func flagPersists() {
        let name = "relevance-flag-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: name)!
        defer { scratch.removePersistentDomain(forName: name) }
        let before = UserDefaults.lhf.object(forKey: ServerJudgesRelevance.key)

        let flag = ServerJudgesRelevance(defaults: scratch)
        #expect(!flag.isSet)
        flag.markSeen()
        #expect(ServerJudgesRelevance(defaults: scratch).isSet)
        #expect(UserDefaults.lhf.object(forKey: ServerJudgesRelevance.key) as? Bool == before as? Bool)
        #expect(!ServerJudgesRelevance(defaults: nil).isSet)
    }

    // MARK: No backfill before the flag

    @Test("before the flag is set, a processed post with no judgment is not asked about: the old server could only answer with none")
    func noBackfillBeforeTheFlag() async throws {
        try await withHarness(serverJudges: false) { h in
            let now = Self.noonUTC
            h.response = [post("73201", daysAgo: 2, now: now)]
            h.state.recordProcessedAnnouncementIDs(["73201"])
            let document = edDocument("73202", now: now, reason: "announcement", daysAgo: 2)
            h.state.recordProcessedAnnouncementIDs([document.id])
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [document])

            await h.state.syncAnnouncements(now: now)
            await h.state.syncEdAnnouncementTasks(now: now)
            #expect(h.calls.ids.isEmpty)
            #expect(h.state.relevanceReadBudget.used(on: now) == 0)
        }
    }

    // MARK: Canvas backfill

    @Test("flag on: a processed, unjudged, in-window Canvas post is asked once, its judgment stored, and its tasks discarded")
    func canvasBackfillAsksOnce() async throws {
        try await withHarness(serverJudges: true) { h in
            let now = Self.noonUTC
            let until = now.addingTimeInterval(3 * Self.day)
            h.response = [post("73301", daysAgo: 3, now: now)]
            h.state.recordProcessedAnnouncementIDs(["73301"])
            // The extractor answers with a task as well: the post was already
            // read for its tasks, so none of it may reach the ledger.
            h.extractor.tasks = [someTask]
            h.extractor.relevanceByID = ["73301": AnnouncementRelevance(kind: .event, until: until)]

            await h.state.syncAnnouncements(now: now)
            #expect(h.calls.ids == ["73301"])
            #expect(h.stored == [key("73301"): AnnouncementRelevance(kind: .event, until: until)])
            #expect(h.state.announcementRelevance[key("73301")]?.kind == .event)
            #expect(h.ledgerRows.isEmpty, "the backfill never writes the ledger")
            #expect(h.state.processedAnnouncementIDs == ["73301"], "the processed ids are not cleared or grown")
            #expect(h.state.relevanceReadBudget.used(on: now) == 1)

            // Judged now: later syncs, and a later day, ask nothing.
            await h.state.syncAnnouncements(now: now.addingTimeInterval(3600))
            await h.state.syncAnnouncements(now: now.addingTimeInterval(Self.day))
            #expect(h.calls.ids == ["73301"])
        }
    }

    @Test("flag on: judged, out-of-window and no-text posts are skipped, and an informational post is news with no call and no budget")
    func canvasBackfillSkips() async throws {
        try await withHarness(serverJudges: true) { h in
            let now = Self.noonUTC
            h.response = [
                post("73311", daysAgo: 2, now: now),
                post("73312", daysAgo: 20, now: now),
                post("73313", daysAgo: 2, now: now, message: "  \n "),
                post("73314", daysAgo: 2, now: now, title: "Recording is up", message: "See Canvas."),
                post("73315", daysAgo: 2, now: now),
            ]
            h.state.recordProcessedAnnouncementIDs(h.response.map(\.id))
            // 73311 already has a judgment; 73315 is the one that should be asked.
            h.state.recordAnnouncementRelevance([key("73311"): AnnouncementRelevance(kind: .standing)])
            h.extractor.relevanceByID = [
                "73311": AnnouncementRelevance(kind: .news), "73312": AnnouncementRelevance(kind: .news),
                "73313": AnnouncementRelevance(kind: .news), "73315": AnnouncementRelevance(kind: .event),
            ]

            await h.state.syncAnnouncements(now: now)
            #expect(h.calls.ids == ["73315"])
            #expect(h.stored[key("73311")]?.kind == .standing, "an existing judgment is left alone")
            #expect(h.stored[key("73312")] == nil, "out of the 14-day window")
            #expect(h.stored[key("73313")] == nil, "nothing to read")
            #expect(h.stored[key("73314")] == AnnouncementRelevance(kind: .news), "informational: news, locally")
            #expect(h.stored[key("73315")]?.kind == .event)
            #expect(h.state.relevanceReadBudget.used(on: now) == 1, "only the one real call")
        }
    }

    @Test("a post read in this very run is not asked a second time by the backfill")
    func aPostReadThisRunIsNotBackfilled() async throws {
        try await withHarness(serverJudges: true) { h in
            let now = Self.noonUTC
            // Read for tasks now, and the server judges nothing for it.
            h.response = [post("73321", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)
            #expect(h.calls.ids == ["73321"])
            #expect(h.state.processedAnnouncementIDs.contains("73321"))
        }
    }

    @Test("an answer with no judgment is not asked again: that day, or any later one")
    func noJudgmentIsFinal() async throws {
        try await withHarness(serverJudges: true) { h in
            let now = Self.noonUTC
            h.response = [post("73331", daysAgo: 2, now: now)]
            h.state.recordProcessedAnnouncementIDs(["73331"])

            await h.state.syncAnnouncements(now: now)
            #expect(h.calls.ids == ["73331"])
            #expect(h.stored.isEmpty)
            #expect(h.state.relevanceReadBudget.used(on: now) == 1)

            await h.state.syncAnnouncements(now: now.addingTimeInterval(3600))
            await h.state.syncAnnouncements(now: now.addingTimeInterval(Self.day))
            await h.state.syncAnnouncements(now: now.addingTimeInterval(2 * Self.day))
            #expect(h.calls.ids == ["73331"], "judged-empty; it cannot burn the budget daily")
        }
    }

    @Test("a failed backfill call counts toward the budget, is not retried that day, and is asked again the next")
    func failedBackfillWaitsADay() async throws {
        try await withHarness(serverJudges: true) { h in
            let now = Self.noonUTC
            h.response = [post("73341", daysAgo: 2, now: now)]
            h.state.recordProcessedAnnouncementIDs(["73341"])
            h.extractor.failing = ["73341"]

            await h.state.syncAnnouncements(now: now)
            #expect(h.calls.ids == ["73341"])
            #expect(h.state.relevanceReadBudget.used(on: now) == 1)
            #expect(h.stored.isEmpty)

            await h.state.syncAnnouncements(now: now.addingTimeInterval(3600))
            await h.state.syncAnnouncements(now: now.addingTimeInterval(7200))
            #expect(h.calls.ids == ["73341"], "no retry on the same UTC day")
            // A failed backfill does not start the extraction back-off: it is
            // bounded by the budget and the stamp, and the back-off is for the
            // main reads.
            #expect(UserDefaults.lhf.object(forKey: "announcementExtractionBackoffUntilV1") == nil)

            h.extractor.failing = []
            h.extractor.relevanceByID = ["73341": standing()]
            await h.state.syncAnnouncements(now: now.addingTimeInterval(Self.day))
            #expect(h.calls.ids == ["73341", "73341"])
            #expect(h.stored[key("73341")]?.kind == .standing)
        }
    }

    // MARK: Ed backfill and the shared budget

    @Test("flag on: a processed, unjudged Ed announcement and staff post are asked once each, newest first, their tasks discarded; no-text and judged posts are skipped")
    func edBackfill() async throws {
        try await withHarness(serverJudges: true) { h in
            let now = Self.noonUTC
            let older = edDocument("73401", now: now, reason: "announcement", daysAgo: 5)
            let newer = edDocument("73402", now: now, reason: "pinned", daysAgo: 2)
            let staff = edDocument("73403", now: now, reason: "staff post", daysAgo: 3)
            let imageOnly = edDocument("73404", now: now, reason: "announcement", daysAgo: 1, body: "- [image]\n> [image]")
            let judged = edDocument("73405", now: now, reason: "announcement", daysAgo: 1)
            let stale = edDocument("73406", now: now, reason: "announcement", daysAgo: 20)
            let documents = [older, newer, staff, imageOnly, judged, stale]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: documents)
            h.state.recordProcessedAnnouncementIDs(documents.map(\.id))
            h.state.recordAnnouncementRelevance([edKey(judged.id): AnnouncementRelevance(kind: .standing)])
            h.extractor.tasks = [someTask]
            h.extractor.relevanceByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, AnnouncementRelevance(kind: .event)) })

            await h.state.syncEdAnnouncementTasks(now: now)
            #expect(h.calls.ids == [newer.id, staff.id, older.id], "newest-posted first")
            #expect(Set(h.stored.keys) == [edKey(newer.id), edKey(staff.id), edKey(older.id), edKey(judged.id)])
            #expect(h.stored[edKey(judged.id)]?.kind == .standing)
            #expect(h.ledgerRows.isEmpty, "the backfill never writes the ledger")
            #expect(h.state.relevanceReadBudget.used(on: now) == 3)

            await h.state.syncEdAnnouncementTasks(now: now.addingTimeInterval(3600))
            #expect(h.calls.ids == [newer.id, staff.id, older.id], "each once")
        }
    }

    @Test("staff reads and backfill calls spend one daily budget of six, staff reads first, in both passes; the next UTC day carries on")
    func oneBudgetForBoth() async throws {
        try await withHarness(serverJudges: true) { h in
            let now = Self.noonUTC
            // Four staff posts never read, and four processed announcements
            // with no judgment, all Ed.
            let staff = (0..<4).map { edDocument("7351\($0)", now: now, reason: "staff post", daysAgo: 1 + Double($0) / 10) }
            let processed = (0..<4).map { edDocument("7352\($0)", now: now, reason: "announcement", daysAgo: 2 + Double($0)) }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: staff + processed)
            h.state.recordProcessedAnnouncementIDs(processed.map(\.id))
            // A Canvas post in the same state, for the other pass.
            h.response = [post("73531", daysAgo: 1, now: now)]
            h.state.recordProcessedAnnouncementIDs(["73531"])
            h.extractor.relevanceByID = Dictionary(
                uniqueKeysWithValues: (staff + processed).map { ($0.id, AnnouncementRelevance(kind: .event)) }
            )
            h.extractor.relevanceByID["73531"] = standing()

            await h.state.syncEdAnnouncementTasks(now: now)
            // Four staff reads, then the two newest processed announcements.
            #expect(h.calls.ids == staff.map(\.id) + processed.prefix(2).map(\.id))
            #expect(h.state.relevanceReadBudget.used(on: now) == 6)
            #expect(h.state.relevanceReadBudget.remaining(on: now) == 0)
            #expect(h.stored[edKey(processed[2].id)] == nil)

            // The Canvas pass finds the budget spent.
            await h.state.syncAnnouncements(now: now.addingTimeInterval(60))
            #expect(h.calls.ids.count == 6)
            #expect(h.stored[key("73531")] == nil)

            // Tomorrow: the Canvas post (newest, 2 days old now) and the
            // others, six calls at most, shared.
            let tomorrow = now.addingTimeInterval(Self.day)
            await h.state.syncAnnouncements(now: tomorrow)
            await h.state.syncEdAnnouncementTasks(now: tomorrow)
            #expect(h.calls.ids.count == 6 + 3, "the Canvas post and the two processed announcements left over")
            #expect(h.calls.ids.suffix(3).first == "73531")
            #expect(h.state.relevanceReadBudget.used(on: tomorrow) == 3)
            #expect(h.stored[key("73531")]?.kind == .standing)
            #expect(processed.allSatisfy { h.stored[edKey($0.id)] != nil })
        }
    }

    // MARK: The ledger

    @Test("the backfill ledger keeps an empty answer for good and a failure for its UTC day, memory-only without defaults and in the defaults it was given")
    func ledgerRememberings() {
        let name = "relevance-ledger-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: name)!
        defer { scratch.removePersistentDomain(forName: name) }
        let now = Self.noonUTC

        for ledger in [RelevanceBackfillLedger(defaults: nil), RelevanceBackfillLedger(defaults: scratch)] {
            #expect(!ledger.shouldSkip("a", on: now))
            ledger.recordFailure("a", on: now)
            ledger.recordEmpty("b", on: now)
            #expect(ledger.shouldSkip("a", on: now.addingTimeInterval(3600)))
            #expect(!ledger.shouldSkip("a", on: now.addingTimeInterval(Self.day)), "a failure is only for its day")
            #expect(ledger.shouldSkip("b", on: now.addingTimeInterval(Self.day)))
            #expect(ledger.shouldSkip("b", on: now.addingTimeInterval(10 * Self.day)))
        }
        #expect(RelevanceBackfillLedger(defaults: scratch).shouldSkip("b", on: now), "read back by a fresh one")
        #expect(UserDefaults.lhf.object(forKey: RelevanceBackfillLedger.key) == nil)

        // Old markers are pruned on the next write.
        let later = now.addingTimeInterval(Double(RelevanceBackfillLedger.emptyRetentionDays + 2) * Self.day)
        let ledger = RelevanceBackfillLedger(defaults: scratch)
        ledger.recordEmpty("c", on: later)
        let saved = scratch.dictionary(forKey: RelevanceBackfillLedger.key) as? [String: [String: Int]]
        #expect(saved?["empty"]?.keys.sorted() == ["c"])
        #expect(saved?["failed"]?.isEmpty == true)
    }
}
}
