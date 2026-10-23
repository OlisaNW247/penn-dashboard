import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The keep-check through an `AppState`: the Canvas sync and the Ed task pass
/// store one relevance judgment per post, and the megaphone sheet and its badge
/// follow it, including the case that prompted the rule (a post whose one find
/// is finished through its Canvas twin leaves the sheet).
///
/// **Hermeticity.** The announcement log lives in a temp directory and the
/// seen ids and judgments in a scratch `UserDefaults` suite
/// (`enableAnnouncementLogForTesting`); the fetch and the extractor are the
/// per-instance seams. The extraction loops also write the process-wide
/// `processedAnnouncementIDsV1` and their retry counters, so this suite sits
/// under `AnnouncementExtractionSuites` (one serialized parent for every suite
/// that does) and backs those keys up and restores them. Class codes and ids
/// are unique to this file.
extension AnnouncementExtractionSuites {
@MainActor
@Suite("Announcement relevance: written by the passes, read by the sheet", .serialized)
struct AnnouncementRelevanceSyncTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let course = "ANREL 7201"
    private static let courseID = "7201"
    private static let sharedKeys = [
        "announcementExtractionVersionV1", "processedAnnouncementIDsV1", "edTaskRetryAfterV1",
        "announcementExtractionAttemptsV1", "announcementExtractionBackoffUntilV1",
    ]

    // MARK: Stubs

    /// What `extractWithRelevance` answers for each announcement id. `extract`
    /// is the required plain requirement and is never what the sync calls.
    private struct Judging: AnnouncementAssignmentExtractor {
        var tasks: [ExtractedAssignment] = []
        /// Tasks for particular posts; any other post gets `tasks`.
        var tasksByID: [String: [ExtractedAssignment]] = [:]
        var relevanceByID: [String: AnnouncementRelevance] = [:]
        var failing: Set<String> = []
        /// Which posts were sent to the extractor, in order.
        var calls: CallLog?
        struct Failure: Error {}

        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            tasks
        }

        func extractWithRelevance(from announcement: AnnouncementSourceText, now: Date) async throws -> AnnouncementExtraction {
            calls?.record(announcement.announcementID)
            if failing.contains(announcement.announcementID) { throw Failure() }
            return AnnouncementExtraction(
                assignments: tasksByID[announcement.announcementID] ?? tasks,
                relevance: relevanceByID[announcement.announcementID]
            )
        }
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func record(_ id: String) { lock.lock(); seen.append(id); lock.unlock() }
        var ids: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private struct FetchFailure: Error {}

    @MainActor
    private final class Harness {
        let state: AppState
        let store: AssignmentStore
        let directory: URL
        let scratch: UserDefaults
        var response: [CanvasAnnouncement] = []
        var extractor = Judging()
        let calls = CallLog()

        init(state: AppState, store: AssignmentStore, directory: URL, scratch: UserDefaults) {
            self.state = state
            self.store = store
            self.directory = directory
            self.scratch = scratch
        }

        /// The judgments as a second reader of the same defaults sees them.
        var stored: [String: AnnouncementRelevance] { AnnouncementRelevanceStore(defaults: scratch).all }

        func sheetIDs(at now: Date) -> [String] { state.announcementSheetRecords(now: now).map(\.id) }
    }

    /// - Parameter serverJudges: whether the install has already seen the
    ///   server return a judgment (`ServerJudgesRelevance`). On by default:
    ///   these tests are about what the passes do with judgments, and an Ed
    ///   staff post is not read at all before the flag is set. The tests of
    ///   the flag itself, and of the backfill that it switches on, are
    ///   `RelevanceBackfillTests`.
    private func withHarness(
        canvasItems extra: [Assignment] = [],
        serverJudges: Bool = true,
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let saved = Self.sharedKeys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        // Pin the repair version so `AppState.init`'s one-time sweep is a
        // no-op, and start with nothing processed.
        shared.set(2, forKey: "announcementExtractionVersionV1")
        for key in Self.sharedKeys.dropFirst() { shared.removeObject(forKey: key) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("announcement-relevance-\(UUID().uuidString)", isDirectory: true)
        let scratchName = "announcement-relevance-\(UUID().uuidString)"
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
        // One feed item with its Canvas URL gives the id -> code map the sync
        // fetches by; the rest are real assignments for finds to be twins of.
        state.canvasItems = [
            Assignment(
                source: .canvas, sourceID: "seed-\(Self.courseID)", kind: .assignment, course: Self.course,
                title: "Seed", dueAt: nil,
                url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/assignments/1")
            ),
        ] + extra
        state.setCourse(Self.course, selected: true)
        defer {
            state.restoreCourse(Self.course)
            state.setCourse(Self.course, selected: true)
            // The id cache is persisted in the shared preferences.
            state.coursePreferences.setCanvasCourseID(Self.course, nil)
        }
        #expect(state.selectedCanvasCourseIDs().keys.contains(Self.courseID))

        let harness = Harness(state: state, store: store, directory: directory, scratch: scratch)
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

    private func key(_ id: String) -> String { AnnouncementReadState.recordKey(id) }

    // MARK: The Canvas sync writes it

    @Test("a sync stores the judgment of an extracted post, news for an informational one, and nothing for a post the extractor gave none for")
    func syncStoresRelevance() async throws {
        try await withHarness { h in
            let now = Date()
            let until = now.addingTimeInterval(3 * Self.day)
            #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Recording is up", body: "See Canvas."))
            h.response = [
                post("72010001", daysAgo: 2, now: now),
                post("72010002", daysAgo: 1, now: now, title: "Recording is up", message: "See Canvas."),
                post("72010003", daysAgo: 1, now: now),
            ]
            h.extractor.relevanceByID = ["72010001": AnnouncementRelevance(kind: .event, until: until)]
            await h.state.syncAnnouncements(now: now)

            let expected = [
                key("72010001"): AnnouncementRelevance(kind: .event, until: until),
                key("72010002"): AnnouncementRelevance(kind: .news, until: nil),
            ]
            #expect(h.stored == expected)
            #expect(h.state.announcementRelevance == expected)
            // All three were read: the one without a judgment stores none.
            #expect(h.state.processedAnnouncementIDs == ["72010001", "72010002", "72010003"])
        }
    }

    @Test("what was stored is there for the next launch, and nothing is stored without the log")
    func relevanceSurvivesARelaunch() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("72010011", daysAgo: 1, now: now)]
            h.extractor.relevanceByID = ["72010011": AnnouncementRelevance(kind: .standing)]
            await h.state.syncAnnouncements(now: now)

            let relaunched = AppState(assignmentStore: try AssignmentStore(inMemory: true))
            relaunched.forceFixtureDataForTesting(false)
            relaunched.enableAnnouncementLogForTesting(directory: h.directory, defaults: h.scratch)
            #expect(relaunched.announcementRelevance == [key("72010011"): AnnouncementRelevance(kind: .standing)])
        }

        // No log, no store: an `AppState` that did not opt in writes nothing.
        let plain = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        #expect(plain.announcementLog == nil)
        plain.recordAnnouncementRelevance([key("1"): AnnouncementRelevance(kind: .news)])
        #expect(plain.announcementRelevance.isEmpty)
    }

    @Test("a post whose extraction failed stores nothing, and is judged when a later sync reads it")
    func failedExtractionStoresNothing() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("72010021", daysAgo: 1, now: now)]
            h.extractor.failing = ["72010021"]
            h.extractor.relevanceByID = ["72010021": AnnouncementRelevance(kind: .task)]
            await h.state.syncAnnouncements(now: now)
            #expect(h.stored.isEmpty)
            #expect(h.state.processedAnnouncementIDs.isEmpty)

            // Every extraction failed, so the extractor is backed off for an
            // hour (the quota is shared with ask): the retry is after it.
            h.extractor.failing = []
            await h.state.syncAnnouncements(now: now.addingTimeInterval(AppState.announcementExtractionBackoff + 60))
            #expect(h.stored == [key("72010021"): AnnouncementRelevance(kind: .task)])
        }
    }

    @Test("a post is judged once: a processed post is not read again, so its judgment is not replaced")
    func judgedOnce() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("72010031", daysAgo: 1, now: now)]
            h.extractor.relevanceByID = ["72010031": AnnouncementRelevance(kind: .standing)]
            await h.state.syncAnnouncements(now: now)

            h.extractor.relevanceByID = ["72010031": AnnouncementRelevance(kind: .news)]
            await h.state.syncAnnouncements(now: now.addingTimeInterval(900))
            #expect(h.stored == [key("72010031"): AnnouncementRelevance(kind: .standing)])
        }
    }

    // MARK: Bounded and cleared

    @Test("a judgment for a row the log and the Ed list no longer hold is dropped at the next refresh; the rest are kept")
    func prunedToKnownRows() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("72010041", daysAgo: 1, now: now)]
            h.extractor.relevanceByID = ["72010041": AnnouncementRelevance(kind: .standing)]
            await h.state.syncAnnouncements(now: now)

            // A judgment written for a post nothing lists (an Ed post that aged
            // out, a Canvas post that left the 60 days).
            h.state.recordAnnouncementRelevance([
                key("72019999"): AnnouncementRelevance(kind: .news),
                AnnouncementReadState.edKey("ed:7201:9999"): AnnouncementRelevance(kind: .news),
            ])
            #expect(h.stored.count == 3, "written as given: pruning waits for the lists to refresh")

            await h.state.syncAnnouncements(now: now.addingTimeInterval(900))
            #expect(h.stored == [key("72010041"): AnnouncementRelevance(kind: .standing)])
            #expect(h.state.announcementRelevance == h.stored)
        }
    }

    @Test("clearing the log forgets every judgment, on the phone and in memory")
    func clearingForgets() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("72010051", daysAgo: 1, now: now)]
            h.extractor.relevanceByID = ["72010051": AnnouncementRelevance(kind: .standing)]
            await h.state.syncAnnouncements(now: now)
            #expect(!h.stored.isEmpty)

            h.state.clearAnnouncementLog()
            #expect(h.stored.isEmpty)
            #expect(h.state.announcementRelevance.isEmpty)
            #expect(h.scratch.object(forKey: AnnouncementRelevanceStore.key) == nil)
        }
    }

    // MARK: The sheet follows it

    @Test("the sheet drops an event that is over, keeps one still ahead, and brings back an older standing post but not older news")
    func sheetFollowsRelevance() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [
                post("72010061", daysAgo: 2, now: now),
                post("72010062", daysAgo: 1, now: now),
                post("72010063", daysAgo: 10, now: now),
                post("72010064", daysAgo: 11, now: now),
                post("72010065", daysAgo: 0.5, now: now),
            ]
            h.extractor.relevanceByID = [
                "72010061": AnnouncementRelevance(kind: .event, until: now.addingTimeInterval(-Self.day)),
                "72010062": AnnouncementRelevance(kind: .event, until: now.addingTimeInterval(2 * Self.day)),
                "72010063": AnnouncementRelevance(kind: .standing),
                "72010064": AnnouncementRelevance(kind: .news),
            ]
            await h.state.syncAnnouncements(now: now)

            #expect(h.state.announcementRecordsOnPage.count == 5)
            #expect(h.sheetIDs(at: now) == ["72010065", "72010062", "72010063"])
        }
    }

    // MARK: The owner's case, end to end

    @Test("the PHYS post whose one find is the worksheet leaves the sheet and the badge once Canvas's CombinedWorksheets6-7 is finished")
    func ownersWorksheetCase() async throws {
        let now = Date()
        // Read off the owner's phone 2026-10-23: the Canvas assignment is
        // titled exactly this, and the announcement left its find undated.
        let canvasWorksheet = Assignment(
            source: .canvas, sourceID: "combined-6-7", kind: .assignment, course: Self.course,
            title: "CombinedWorksheets6-7", dueAt: now.addingTimeInterval(-2 * Self.day),
            url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/assignments/6767")
        )
        try await withHarness(canvasItems: [canvasWorksheet]) { h in
            let postTitle = "derivation of discharging process & combined worksheet 6-7 & exam 2 review"
            let postBody = "Please do combined worksheet 6-7 before the exam 2 review."
            #expect(!HeuristicAnnouncementExtractor.isLikelyInformational(title: postTitle, body: postBody))

            // A first sync fills the log, and everything in a first fill counts
            // as seen. The worksheet post arrives in the second, unread.
            h.response = [post("72010070", daysAgo: 6, now: now)]
            await h.state.syncAnnouncements(now: now)
            h.extractor.tasks = [ExtractedAssignment(title: "Combined worksheet 6-7", dueAt: nil, kind: .submission)]
            h.response.append(post("72010071", daysAgo: 2, now: now, title: postTitle, message: postBody))
            await h.state.syncAnnouncements(now: now)

            // No judgment came with it (an older server, or an offline phone):
            // only the finished work can take it off the sheet.
            #expect(h.stored[key("72010071")] == nil)
            let find = try #require(h.store.assignments(source: .canvasAnnouncement).first)
            #expect(find.sourceID == "announcement-72010071-0")

            // The student has not turned it in: the post is listed, and the
            // post and its find are both unread.
            #expect(h.sheetIDs(at: now).contains("72010071"))
            #expect(h.state.announcementFindStates(now: now)[key("72010071")] == .open)
            #expect(h.state.announcementBadgeCount(now: now) == 2)

            // The Canvas assignment is turned in.
            h.state.markCompleted(canvasWorksheet)

            #expect(h.state.announcementFindsWithFinishedTwinIDs.contains(find.id))
            #expect(h.state.announcementFindStates(now: now)[key("72010071")] == .allDone)
            #expect(!h.sheetIDs(at: now).contains("72010071"))
            #expect(h.sheetIDs(at: now) == ["72010070"])
            // The find left the found list with it, so nothing about the post is counted.
            #expect(h.state.announcementBadgeCount(now: now) == 0)
            #expect(h.state.unreadAnnouncementCount == 0)

            // Display only: the post is still in the log, and un-finishing the
            // twin brings it straight back.
            #expect(h.state.announcementLogRecords.contains { $0.id == "72010071" })
            h.state.markActive(canvasWorksheet)
            #expect(h.sheetIDs(at: now).contains("72010071"))
        }
    }

    @Test("a standing post stays on the sheet after its find is finished")
    func standingPostSurvivesItsFinishedFind() async throws {
        let now = Date()
        let canvasWorksheet = Assignment(
            source: .canvas, sourceID: "combined-6-7", kind: .assignment, course: Self.course,
            title: "CombinedWorksheets6-7", dueAt: now.addingTimeInterval(-2 * Self.day),
            url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/assignments/6767")
        )
        try await withHarness(canvasItems: [canvasWorksheet]) { h in
            h.extractor.tasks = [ExtractedAssignment(title: "Combined worksheet 6-7", dueAt: nil, kind: .submission)]
            h.extractor.relevanceByID = ["72010081": AnnouncementRelevance(kind: .standing)]
            h.response = [post("72010081", daysAgo: 2, now: now)]
            await h.state.syncAnnouncements(now: now)

            h.state.markCompleted(canvasWorksheet)
            #expect(h.state.announcementFindStates(now: now)[key("72010081")] == .allDone)
            #expect(h.sheetIDs(at: now) == ["72010081"])
        }
    }

    // MARK: The Ed pass writes it

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

    @Test("the Ed pass stores a judgment under the Ed key of the document, and news for an informational post")
    func edPassStoresRelevance() async throws {
        try await withHarness { h in
            let now = Date()
            let judged = edDocument("9701", now: now)
            let informational = edDocument("9702", now: now, title: "Recording is up", body: "See Canvas.")
            let unjudged = edDocument("9703", now: now)
            #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Recording is up", body: "See Canvas."))

            let until = now.addingTimeInterval(4 * Self.day)
            h.extractor.relevanceByID = [judged.id: AnnouncementRelevance(kind: .task, until: until)]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [judged, informational, unjudged])
            await h.state.syncEdAnnouncementTasks(now: now)

            #expect(h.state.announcementRecordsOnPage.map(\.id).contains(judged.id), "the key is the id of the row the sheet lists")
            let expected = [
                AnnouncementReadState.edKey(judged.id): AnnouncementRelevance(kind: .task, until: until),
                AnnouncementReadState.edKey(informational.id): AnnouncementRelevance(kind: .news, until: nil),
            ]
            #expect(h.stored == expected)
            #expect(h.state.announcementRelevance == expected)
        }
    }

    @Test("an Ed post leaves the sheet once the find read from it is finished")
    func edPostLeavesWhenItsFindIsDone() async throws {
        try await withHarness { h in
            let now = Date()
            let document = edDocument("9711", now: now)
            h.extractor.tasks = [ExtractedAssignment(title: "Submit the lab report", dueAt: nil, kind: .submission)]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [document])
            await h.state.syncEdAnnouncementTasks(now: now)

            let find = try #require(h.store.assignments(source: .canvasAnnouncement).first { $0.announcementOrigin == .ed })
            #expect(h.state.announcementFindStates(now: now)[AnnouncementReadState.edKey(document.id)] == .open)
            #expect(h.sheetIDs(at: now) == [document.id])

            h.state.markCompleted(find)
            #expect(h.state.announcementFindStates(now: now)[AnnouncementReadState.edKey(document.id)] == .allDone)
            #expect(h.sheetIDs(at: now).isEmpty)
        }
    }

    // MARK: Ed staff posts

    @Test("a staff post is a candidate row, listed and counted only while its judgment says it matters, and the Ed seeding does not file it as seen")
    func staffPostThroughAnAppState() async throws {
        try await withHarness { h in
            let now = Date()
            let staff = edDocument("9801", now: now, reason: "staff post", title: "Midterm", body: "Midterm is Thursday in class.")

            // Only a staff post on Ed: it is a candidate on the page, nothing is
            // listed or counted, and the seeding has not happened (it waits for
            // the first announcement or pinned post).
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [staff])
            #expect(h.state.announcementRecordsOnPage.map(\.id) == [staff.id])
            #expect(h.state.announcementRecordsOnPage.first?.isStaffPost == true)
            #expect(h.sheetIDs(at: now).isEmpty)
            #expect(h.state.announcementBadgeCount(now: now) == 0)
            #expect(!AnnouncementReadState(defaults: h.scratch).edSeeded)
            #expect(!h.state.showsAnnouncementsButton)

            // The first announcement seeds itself as seen, and not the staff post.
            let announcement = edDocument("9802", now: now)
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [staff, announcement])
            #expect(AnnouncementReadState(defaults: h.scratch).edSeeded)
            #expect(h.state.announcementSeenIDs == [AnnouncementReadState.edKey(announcement.id)])
            #expect(h.sheetIDs(at: now) == [announcement.id])
            #expect(h.state.announcementBadgeCount(now: now) == 0)

            // Its judgment arrives: an exam three days out. It is listed, unread, counted.
            let until = now.addingTimeInterval(3 * Self.day)
            h.state.recordAnnouncementRelevance([AnnouncementReadState.edKey(staff.id): AnnouncementRelevance(kind: .event, until: until)])
            #expect(Set(h.sheetIDs(at: now)) == [staff.id, announcement.id])
            #expect(h.state.announcementBadgeCount(now: now) == 1)
            #expect(h.state.unreadAnnouncementCount == 1)

            // Opened, it is seen and the count is down; it is reported as new once.
            let new = h.state.openAnnouncementsSheet(now: now)
            #expect(new == [AnnouncementReadState.edKey(staff.id)])
            #expect(h.state.unreadAnnouncementCount == 0)

            // After the exam it is gone from the sheet, though the announcement stays.
            #expect(h.sheetIDs(at: until.addingTimeInterval(60)) == [announcement.id])
        }
    }

    @Test("a staff post with no judgment, news, or standing is not listed however fresh it is")
    func staffPostWithoutAQualifyingJudgment() async throws {
        try await withHarness { h in
            let now = Date()
            let announcement = edDocument("9811", now: now, daysAgo: 20)
            let staff = edDocument("9812", now: now, reason: "staff post", daysAgo: 0.5)
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [announcement, staff])
            let key = AnnouncementReadState.edKey(staff.id)

            for judgment in [nil, AnnouncementRelevance(kind: .news), AnnouncementRelevance(kind: .standing)] {
                h.state.recordAnnouncementRelevance(judgment.map { [key: $0] } ?? [:])
                // The class is represented by its announcement, the staff post is
                // not picked as the class's latest and then hidden.
                #expect(h.sheetIDs(at: now) == [announcement.id], "\(String(describing: judgment))")
            }
        }
    }

    @Test("a staff post whose judgment is a task is listed while a find from it is open, and leaves with it")
    func staffTaskFollowsItsFind() async throws {
        try await withHarness { h in
            let now = Date()
            let staff = edDocument("9821", now: now, reason: "staff post", title: "No recitation + HW 5", body: "Submit HW 5 on Gradescope.")
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [staff])
            let find = Assignment(
                source: .canvasAnnouncement,
                sourceID: AnnouncementRecord.edFindSourceID(courseID: Self.courseID, threadID: staff.sourceID, index: 0),
                kind: .assignment, course: Self.course, title: "Submit HW 5", dueAt: nil, url: nil
            )
            h.store.upsert([find])
            h.state.applyAnnouncementLedgerChange()
            h.state.recordAnnouncementRelevance([AnnouncementReadState.edKey(staff.id): AnnouncementRelevance(kind: .task)])

            #expect(h.state.announcementFindStates(now: now)[AnnouncementReadState.edKey(staff.id)] == .open)
            #expect(h.sheetIDs(at: now) == [staff.id])

            h.state.markCompleted(find)
            #expect(h.state.announcementFindStates(now: now)[AnnouncementReadState.edKey(staff.id)] == .allDone)
            #expect(h.sheetIDs(at: now).isEmpty)
        }
    }

    // MARK: The Ed pass reads a staff post for its judgment only

    @Test("the pass reads a staff post and stores its judgment, but writes no row even when the extractor returns tasks; an announcement beside it still produces its row")
    func edPassReadsStaffPostsForRelevanceOnly() async throws {
        try await withHarness { h in
            let now = Date()
            let staff = edDocument("9831", now: now, reason: "staff post")
            let announcement = edDocument("9832", now: now)
            let until = now.addingTimeInterval(2 * Self.day)
            h.extractor.tasks = [ExtractedAssignment(title: "Submit the lab report", dueAt: until, kind: .submission)]
            h.extractor.relevanceByID = [
                staff.id: AnnouncementRelevance(kind: .task, until: until),
                announcement.id: AnnouncementRelevance(kind: .standing),
            ]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [staff, announcement])
            await h.state.syncEdAnnouncementTasks(now: now)

            // Both were sent to the extractor and both judged.
            #expect(Set(h.calls.ids) == [staff.id, announcement.id])
            #expect(h.stored == [
                AnnouncementReadState.edKey(staff.id): AnnouncementRelevance(kind: .task, until: until),
                AnnouncementReadState.edKey(announcement.id): AnnouncementRelevance(kind: .standing),
            ])
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: [staff.id, announcement.id]))

            // But only the announcement wrote a row.
            let rows = h.store.assignments(source: .canvasAnnouncement)
            #expect(rows.map(\.sourceID) == [
                AnnouncementRecord.edFindSourceID(courseID: Self.courseID, threadID: announcement.sourceID, index: 0),
            ])
            #expect(rows.first?.title == "Submit the lab report")
            #expect(h.state.announcementItems.map(\.sourceID) == rows.map(\.sourceID))
            #expect(h.state.announcementPageItems.map(\.sourceID) == rows.map(\.sourceID))
            #expect(h.state.announcementFindStates(now: now)[AnnouncementReadState.edKey(staff.id)] == nil)

            // The staff post is on the sheet through its judgment (a task not yet
            // due) and leaves when the date passes; the standing announcement stays.
            #expect(Set(h.sheetIDs(at: now)) == [staff.id, announcement.id])
            #expect(h.sheetIDs(at: until.addingTimeInterval(60)) == [announcement.id])
        }
    }

    @Test("a staff post is read once, is judged `news` without a call when it reads as information, and a failed read waits and is judged when it is read again")
    func staffPostPassMachinery() async throws {
        try await withHarness { h in
            let now = Date()
            let staff = edDocument("9841", now: now, reason: "staff post")
            let informational = edDocument("9842", now: now, reason: "staff post", title: "Recording is up", body: "See Canvas.")
            h.extractor.tasks = [ExtractedAssignment(title: "Submit the lab report", dueAt: nil, kind: .submission)]
            h.extractor.relevanceByID = [staff.id: AnnouncementRelevance(kind: .event, until: now.addingTimeInterval(Self.day))]
            h.extractor.failing = [staff.id]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [staff, informational])

            // The read fails: nothing is judged or processed for it, and it waits.
            await h.state.syncEdAnnouncementTasks(now: now)
            #expect(h.calls.ids == [staff.id], "the informational post never reaches the extractor")
            #expect(!h.state.processedAnnouncementIDs.contains(staff.id))
            #expect(h.stored == [AnnouncementReadState.edKey(informational.id): AnnouncementRelevance(kind: .news)])
            #expect(h.store.assignments(source: .canvasAnnouncement).isEmpty)

            // Waiting out the retry clock and the hour's back-off, it is read and judged.
            h.extractor.failing = []
            let later = now.addingTimeInterval(AppState.edTaskRetryInterval + 60)
            await h.state.syncEdAnnouncementTasks(now: later)
            #expect(h.calls.ids == [staff.id, staff.id])
            #expect(h.stored[AnnouncementReadState.edKey(staff.id)]?.kind == .event)
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: [staff.id, informational.id]))
            #expect(h.store.assignments(source: .canvasAnnouncement).isEmpty, "still no row from a staff post")

            // Once read, a staff post is not asked about again.
            await h.state.syncEdAnnouncementTasks(now: later.addingTimeInterval(60))
            #expect(h.calls.ids == [staff.id, staff.id])
        }
    }

    // MARK: The daily cap on staff-post reads

    /// Noon UTC today: a moment whose UTC day is today's, with half a day on
    /// either side before it changes, so a test that steps an hour or a day
    /// from it never straddles midnight by accident.
    private static var noonUTC: Date {
        Date(timeIntervalSince1970: (Double(RelevanceReadBudget.utcDay(of: Date())) + 0.5) * 86_400)
    }

    /// `count` staff posts, newest first: thread `first`, `first + 1`, ... each
    /// a quarter of a day older than the last.
    private func staffPosts(_ count: Int, first: Int, now: Date) -> [CourseDocument] {
        (0..<count).map { index in
            edDocument("\(first + index)", now: now, reason: "staff post", daysAgo: 1 + Double(index) / 4)
        }
    }

    @Test("10 eligible staff posts: 6 are read today, newest first; the 4 oldest are left unread and unpenalized; the next UTC day reads them")
    func staffReadsAreCappedPerUTCDay() async throws {
        try await withHarness { h in
            let now = Self.noonUTC
            let posts = staffPosts(10, first: 9901, now: now)
            h.extractor.relevanceByID = Dictionary(uniqueKeysWithValues: posts.map {
                ($0.id, AnnouncementRelevance(kind: .event, until: now.addingTimeInterval(5 * Self.day)))
            })
            h.state.courseKnowledge = CourseKnowledgeBase(documents: posts.shuffled())
            await h.state.syncEdAnnouncementTasks(now: now)

            let today = Array(posts.prefix(6))
            let held = Array(posts.suffix(4))
            #expect(h.calls.ids == today.map(\.id), "the six newest, newest first")
            #expect(Set(h.stored.keys) == Set(today.map { AnnouncementReadState.edKey($0.id) }))
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: today.map(\.id)))
            #expect(h.state.relevanceReadBudget.used(on: now) == 6)
            #expect(h.state.relevanceReadBudget.remaining(on: now) == 0)

            // The four oldest are untouched: not processed, no attempt counted,
            // no retry clock, no judgment.
            for post in held {
                #expect(!h.state.processedAnnouncementIDs.contains(post.id))
                #expect(AppState.loadEdTaskRetryAfter()[post.id] == nil)
                #expect(UserDefaults.lhf.dictionary(forKey: "announcementExtractionAttemptsV1")?[post.id] == nil)
                #expect(h.stored[AnnouncementReadState.edKey(post.id)] == nil)
            }
            #expect(h.state.lastEdTaskSyncSummary?.contains("held back 4") == true)
            #expect(h.store.assignments(source: .canvasAnnouncement).isEmpty)

            // Later the same day, with the budget spent, nothing is sent: runs
            // repeat through the day, and a per-run cap would have read four
            // more here.
            await h.state.syncEdAnnouncementTasks(now: now.addingTimeInterval(3600))
            await h.state.syncEdAnnouncementTasks(now: now.addingTimeInterval(7200))
            #expect(h.calls.ids == today.map(\.id))

            // The next UTC day the rest are read.
            let tomorrow = now.addingTimeInterval(Self.day)
            await h.state.syncEdAnnouncementTasks(now: tomorrow)
            #expect(h.calls.ids == posts.map(\.id), "each post once, the held-back four after the first six")
            #expect(Set(h.stored.keys) == Set(posts.map { AnnouncementReadState.edKey($0.id) }))
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: posts.map(\.id)))
            #expect(h.state.relevanceReadBudget.used(on: tomorrow) == 4)
            #expect(h.state.relevanceReadBudget.used(on: now) == 0, "yesterday's count is gone with yesterday")
        }
    }

    @Test("informational staff posts do not count against the budget")
    func informationalStaffPostsAreNotCounted() async throws {
        try await withHarness { h in
            let now = Self.noonUTC
            // Eight that read as information, all newer than seven that do not.
            let informational = (0..<8).map {
                edDocument("\(9921 + $0)", now: now, reason: "staff post", daysAgo: 1 + Double($0) / 10, title: "Recording is up", body: "See Canvas.")
            }
            let ordinary = (0..<7).map {
                edDocument("\(9931 + $0)", now: now, reason: "staff post", daysAgo: 3 + Double($0) / 4)
            }
            h.extractor.relevanceByID = Dictionary(uniqueKeysWithValues: ordinary.map {
                ($0.id, AnnouncementRelevance(kind: .event, until: now.addingTimeInterval(Self.day)))
            })
            h.state.courseKnowledge = CourseKnowledgeBase(documents: informational + ordinary)
            await h.state.syncEdAnnouncementTasks(now: now)

            #expect(h.calls.ids == ordinary.prefix(6).map(\.id), "no call for an informational post, six for the rest")
            #expect(h.state.relevanceReadBudget.used(on: now) == 6)
            // All eight were judged news with no call, and processed.
            for post in informational {
                #expect(h.stored[AnnouncementReadState.edKey(post.id)] == AnnouncementRelevance(kind: .news))
                #expect(h.state.processedAnnouncementIDs.contains(post.id))
            }
            // The seventh ordinary post is the one held back.
            #expect(!h.state.processedAnnouncementIDs.contains(ordinary[6].id))
        }
    }

    @Test("announcement and pinned posts are not capped, are read before the staff posts, and still produce their rows")
    func announcementsAreUnaffectedByTheCap() async throws {
        try await withHarness { h in
            let now = Self.noonUTC
            let staff = staffPosts(10, first: 9941, now: now)
            let announcements = [
                edDocument("9951", now: now, reason: "announcement", daysAgo: 6, title: "Lab 1"),
                edDocument("9952", now: now, reason: "pinned", daysAgo: 5, title: "Reading"),
                edDocument("9953", now: now, reason: "announcement", daysAgo: 4, title: "Exam logistics"),
                edDocument("9954", now: now, reason: "announcement", daysAgo: 3, title: "Poster session"),
            ]
            let titles = ["Submit lab report one", "Finish chapter seven reading", "Bring a photo ID", "Email the poster abstract"]
            h.extractor.tasksByID = Dictionary(uniqueKeysWithValues: zip(announcements, titles).map {
                ($0.0.id, [ExtractedAssignment(title: $0.1, dueAt: nil, kind: .submission)])
            })
            // The staff posts' tasks must never become rows, however many there are.
            h.extractor.tasks = [ExtractedAssignment(title: "Hand in the staff worksheet", dueAt: nil, kind: .submission)]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: staff + announcements)
            await h.state.syncEdAnnouncementTasks(now: now)

            // Announcements first in the order they came, then six staff posts.
            #expect(h.calls.ids == announcements.map(\.id) + staff.prefix(6).map(\.id))
            let rows = h.store.assignments(source: .canvasAnnouncement)
            #expect(Set(rows.map(\.title)) == Set(titles))
            #expect(rows.allSatisfy { $0.announcementOrigin == .ed })
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: announcements.map(\.id)))
            // They did not spend the staff budget.
            #expect(h.state.relevanceReadBudget.used(on: now) == 6)
        }
    }

    @Test("a staff read that fails still counts toward the day's budget, and waits like any failed read")
    func failedStaffReadCounts() async throws {
        try await withHarness { h in
            let now = Self.noonUTC
            let post = edDocument("9961", now: now, reason: "staff post")
            h.extractor.failing = [post.id]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [post])
            await h.state.syncEdAnnouncementTasks(now: now)

            #expect(h.calls.ids == [post.id])
            #expect(h.state.relevanceReadBudget.used(on: now) == 1)
            #expect(!h.state.processedAnnouncementIDs.contains(post.id))
            #expect(AppState.loadEdTaskRetryAfter()[post.id] != nil)
        }
    }

    @Test("the day and count are kept in the defaults they were given, read back by a fresh budget, and reset on the next UTC day")
    func budgetPersists() async throws {
        try await withHarness { h in
            let now = Self.noonUTC
            h.state.relevanceReadBudget = RelevanceReadBudget(defaults: h.scratch)
            let posts = staffPosts(8, first: 9971, now: now)
            h.extractor.relevanceByID = Dictionary(uniqueKeysWithValues: posts.map {
                ($0.id, AnnouncementRelevance(kind: .event, until: now.addingTimeInterval(Self.day)))
            })
            h.state.courseKnowledge = CourseKnowledgeBase(documents: posts)
            await h.state.syncEdAnnouncementTasks(now: now)
            #expect(h.calls.ids.count == 6)

            // A relaunch builds a new budget over the same defaults.
            let relaunched = RelevanceReadBudget(defaults: h.scratch)
            #expect(relaunched.used(on: now) == 6)
            #expect(relaunched.remaining(on: now.addingTimeInterval(3600)) == 0)
            #expect(relaunched.remaining(on: now.addingTimeInterval(Self.day)) == 6)
            #expect(h.scratch.dictionary(forKey: RelevanceReadBudget.key) as? [String: Int] == [
                "day": RelevanceReadBudget.utcDay(of: now), "count": 6,
            ])
            // Nothing reached the shared domain.
            #expect(UserDefaults.lhf.object(forKey: RelevanceReadBudget.key) == nil)
        }
    }
}
}
