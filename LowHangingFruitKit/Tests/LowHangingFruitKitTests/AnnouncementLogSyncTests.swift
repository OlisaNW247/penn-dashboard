import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `AppState.syncAnnouncements()` end to end, with no network: the Canvas
/// fetch and the extractor choice are replaced by the per-instance seams
/// `announcementFetchForTesting` / `announcementExtractorForTesting`
/// (`AnnouncementWatcherWiringTests` could not exercise the sync because it
/// had none).
///
/// Hermeticity. The log lives in a per-test temp directory and the seen ids
/// in a scratch `UserDefaults` suite (`enableAnnouncementLogForTesting`);
/// under the test runner an `AppState` has no log at all otherwise, so no
/// other suite's `AppState` can reach either. The one shared write is the
/// extraction pipeline's own `processedAnnouncementIDsV1` (it was written
/// before this feature and the sync cannot be pointed elsewhere), so that key
/// and the repair-version key are backed up and restored the way
/// `AnnouncementWatcherWiringTests` does, and every id and class code here is
/// unique to this suite.
@MainActor
@Suite("Announcement log sync", .serialized)
struct AnnouncementLogSyncTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let processedKey = "processedAnnouncementIDsV1"
    private static let extractionVersionKey = "announcementExtractionVersionV1"

    // MARK: Stubs

    /// What reached the extraction stage, in order. The extractor choice is
    /// where an announcement would go to the heuristic or to the backend's AI
    /// assist, so "never reached this" is "never sent".
    private final class ExtractionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(id: String, body: String)] = []

        func record(_ source: AnnouncementSourceText) {
            lock.lock(); defer { lock.unlock() }
            seen.append((source.announcementID, source.body))
        }
        var ids: [String] {
            lock.lock(); defer { lock.unlock() }
            return seen.map(\.id)
        }
        var bodies: [String: String] {
            lock.lock(); defer { lock.unlock() }
            return Dictionary(seen.map { ($0.id, $0.body) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private struct StubExtractor: AnnouncementAssignmentExtractor {
        let log: ExtractionLog
        let tasksPerAnnouncement: Int

        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            log.record(announcement)
            return (0..<tasksPerAnnouncement).map { index in
                ExtractedAssignment(
                    title: "Submit part \(index) of \(announcement.announcementID)",
                    dueAt: nil,
                    kind: .submission
                )
            }
        }
    }

    private struct FetchFailure: Error {}

    // MARK: Harness

    @MainActor
    private final class Harness {
        let state: AppState
        let directory: URL
        let scratchName: String
        let scratch: UserDefaults
        let extraction = ExtractionLog()
        var fetchCalls: [(courseIDs: [String], since: Date, until: Date)] = []
        /// When true the stub answers like Canvas: only announcements posted
        /// inside the requested `since...until` window come back. Off by
        /// default, where the stub returns `response` whole.
        var filtersByWindow = false
        /// What the next fetch returns; nil makes it throw.
        var response: [CanvasAnnouncement]? = []

        init(state: AppState, directory: URL, scratchName: String, scratch: UserDefaults) {
            self.state = state
            self.directory = directory
            self.scratchName = scratchName
            self.scratch = scratch
        }

        var diskLog: [AnnouncementRecord]? {
            AnnouncementLogStore(directory: directory).loadIfPresent()
        }
    }

    /// Courses: Canvas id -> class code, both unique to this suite.
    private static let defaultCourses: [(id: String, code: String)] = [("9101", "ANLOG 9101")]

    private func withHarness(
        courses: [(id: String, code: String)] = AnnouncementLogSyncTests.defaultCourses,
        tasksPerAnnouncement: Int = 0,
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let backup = [Self.processedKey, Self.extractionVersionKey].map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in backup {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        // Pin the repair version so `AppState.init`'s one-time sweep is a
        // no-op, and start with nothing processed.
        shared.set(2, forKey: Self.extractionVersionKey)
        shared.removeObject(forKey: Self.processedKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("announcement-log-sync-\(UUID().uuidString)", isDirectory: true)
        let scratchName = "announcement-log-sync-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: scratchName)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            scratch.removePersistentDomain(forName: scratchName)
        }

        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        state.forceFixtureDataForTesting(false)
        state.enableAnnouncementLogForTesting(directory: directory, defaults: scratch)
        // The course id -> code map the sync fetches by is derived from feed
        // items' URLs; one item per course is enough to seed it.
        state.canvasItems = courses.map { course in
            Assignment(
                source: .canvas, sourceID: "seed-\(course.id)", kind: .assignment,
                course: course.code, title: "Seed \(course.code)", dueAt: nil,
                url: URL(string: "https://canvas.upenn.edu/courses/\(course.id)/assignments/1")
            )
        }
        for course in courses { state.setCourse(course.code, selected: true) }
        defer {
            for course in courses {
                state.restoreCourse(course.code)
                state.setCourse(course.code, selected: true)
                // The id cache is persisted in the shared preferences, so an
                // entry left behind would make the next test's `AppState`
                // fetch for this test's class as well.
                state.coursePreferences.setCanvasCourseID(course.code, nil)
            }
        }
        // A superset, not equality: another suite may have left an id of its
        // own in the shared cache, and that must not fail this one.
        #expect(Set(courses.map(\.id)).isSubset(of: Set(state.selectedCanvasCourseIDs().keys)))

        let harness = Harness(state: state, directory: directory, scratchName: scratchName, scratch: scratch)
        state.announcementFetchForTesting = { [harness] ids, since, until in
            harness.fetchCalls.append((ids, since, until))
            guard let response = harness.response else { throw FetchFailure() }
            guard harness.filtersByWindow else { return response }
            return response.filter { announcement in
                announcement.postedAt.map { $0 >= since && $0 <= until } ?? true
            }
        }
        let extraction = harness.extraction
        state.announcementExtractorForTesting = { _ in
            StubExtractor(log: extraction, tasksPerAnnouncement: tasksPerAnnouncement)
        }
        try await body(harness)
    }

    private func announcement(
        _ id: String,
        course: String = "9101",
        daysAgo: Double,
        now: Date,
        title: String = "Please submit your essay by Friday",
        message: String = "Please submit your essay by Friday. It is worth 10 percent of the grade."
    ) -> CanvasAnnouncement {
        CanvasAnnouncement(
            id: id, courseID: course, title: title, message: message,
            postedAt: now.addingTimeInterval(-daysAgo * Self.day),
            url: URL(string: "https://canvas.upenn.edu/courses/\(course)/discussion_topics/\(id)")
        )
    }

    // MARK: Recording

    @Test("every fetched announcement is recorded, including one the informational gate discards")
    func recordsEverythingFetched() async throws {
        try await withHarness { h in
            let now = Date()
            // "Recording is up" is judged informational and never reaches an
            // extractor; it must still be listed.
            #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Recording is up", body: "See Canvas."))
            h.response = [
                announcement("9100001", daysAgo: 3, now: now, title: "Recording is up", message: "See Canvas."),
                announcement("9100002", daysAgo: 2, now: now),
            ]
            await h.state.syncAnnouncements(now: now)

            #expect(Set(h.diskLog?.map(\.id) ?? []) == ["9100001", "9100002"])
            #expect(Set(h.state.announcementRecordsOnPage.map(\.id)) == ["9100001", "9100002"])
            #expect(h.state.announcementRecordsOnPage.allSatisfy { $0.courseCode == "ANLOG 9101" })
            // The gate still did its job: only the actionable post was extracted.
            #expect(h.extraction.ids == ["9100002"])
            // The record keeps a preview, not the author or the full body.
            let recorded = try #require(h.diskLog?.first { $0.id == "9100002" })
            #expect(recorded.snippet.hasPrefix("Please submit your essay by Friday"))
            #expect(recorded.url?.absoluteString == "https://canvas.upenn.edu/courses/9101/discussion_topics/9100002")
        }
    }

    @Test("the fetch asks Canvas for 60 days")
    func fetchWindowIsSixtyDays() async throws {
        try await withHarness { h in
            let now = Date()
            await h.state.syncAnnouncements(now: now)
            let call = try #require(h.fetchCalls.first)
            #expect(call.courseIDs.contains("9101"))
            #expect(call.since == now.addingTimeInterval(-60 * Self.day))
        }
    }

    // MARK: Extraction sees exactly what it saw before

    @Test("a 30-day-old announcement is recorded but never extracted, never reaches the AI-assist decision, and makes no ledger row")
    func oldAnnouncementIsLoggedNotExtracted() async throws {
        try await withHarness(tasksPerAnnouncement: 1) { h in
            let now = Date()
            let recentBody = "Please submit your essay by Friday. Exact body text, unchanged."
            h.response = [
                announcement("9100010", daysAgo: 30, now: now),
                announcement("9100011", daysAgo: 3, now: now, message: recentBody),
            ]
            await h.state.syncAnnouncements(now: now)

            // Recorded: both.
            #expect(Set(h.diskLog?.map(\.id) ?? []) == ["9100010", "9100011"])
            // Extracted: only the recent one. The extractor choice is the one
            // place an announcement goes to the heuristic or to the backend,
            // so an id absent here was not sent anywhere.
            #expect(h.extraction.ids == ["9100011"])
            // And the extractor got the full, unmodified text, not the snippet.
            #expect(h.extraction.bodies["9100011"] == recentBody)
            // No ledger row for the old one, one for the recent one.
            let rows = h.state.assignmentStore?.assignments(source: .canvasAnnouncement) ?? []
            #expect(rows.map(\.sourceID) == ["announcement-9100011-0"])
            // Only the extracted one is marked processed.
            #expect(h.state.processedAnnouncementIDs == ["9100011"])
        }
    }

    @Test("the fetch window starts 60 days back and ends after now, because Canvas defaults end_date to 28 days after start_date")
    func fetchWindowHasAnEndAfterNow() async throws {
        try await withHarness { h in
            let now = Date()
            await h.state.syncAnnouncements(now: now)
            let call = try #require(h.fetchCalls.first)
            #expect(call.since == now.addingTimeInterval(-60 * Self.day))
            #expect(call.until > now)
            #expect(call.until == now.addingTimeInterval(Self.day))
            // And it is a whole 61-day window, far past Canvas's 28-day default.
            #expect(call.until.timeIntervalSince(call.since) == 61 * Self.day)

            let window = AppState.announcementFetchWindow(now: now)
            #expect(window.since == call.since)
            #expect(window.until == call.until)
        }
    }

    @Test("regression: against a Canvas that honours the requested window, a 40-day-old and a 2-day-old announcement are both recorded and the recent one still reaches extraction")
    func recentAnnouncementsSurviveTheWindow() async throws {
        try await withHarness(tasksPerAnnouncement: 1) { h in
            let now = Date()
            h.filtersByWindow = true
            h.response = [
                announcement("9100100", daysAgo: 46, now: now),
                announcement("9100101", daysAgo: 40, now: now),
                announcement("9100102", daysAgo: 2, now: now),
            ]
            await h.state.syncAnnouncements(now: now)

            // Both the old and the recent post are listed.
            #expect(Set(h.diskLog?.map(\.id) ?? []) == ["9100100", "9100101", "9100102"])
            #expect(h.state.announcementRecordsOnPage.map(\.id) == ["9100102", "9100101", "9100100"])
            // The Announcement Watcher still sees the last 14 days: the recent
            // post is extracted and makes its ledger row; the older ones do not.
            #expect(h.extraction.ids == ["9100102"])
            let rows = h.state.assignmentStore?.assignments(source: .canvasAnnouncement) ?? []
            #expect(rows.map(\.sourceID) == ["announcement-9100102-0"])
        }
    }

    @Test("only announcements posted in the last 14 days are eligible for extraction; an undated one still is")
    func extractionEligibility() {
        let now = Date()
        func make(_ id: String, daysAgo: Double?) -> CanvasAnnouncement {
            CanvasAnnouncement(
                id: id, courseID: "1", title: "t", message: "m",
                postedAt: daysAgo.map { now.addingTimeInterval(-$0 * Self.day) }, url: nil
            )
        }
        let eligible = AppState.announcementsEligibleForExtraction(
            [make("today", daysAgo: 0), make("13", daysAgo: 13.9), make("15", daysAgo: 14.1),
             make("30", daysAgo: 30), make("59", daysAgo: 59), make("undated", daysAgo: nil)],
            now: now
        )
        #expect(eligible.map(\.id) == ["today", "13", "undated"])
        #expect(AppState.announcementExtractionWindow == 14 * Self.day)
    }

    @Test("a fetch with nothing left to extract still updates the log")
    func logUpdatesWhenNothingIsUnprocessed() async throws {
        try await withHarness { h in
            let now = Date()
            let recent = announcement("9100020", daysAgo: 2, now: now)
            h.response = [recent]
            await h.state.syncAnnouncements(now: now)
            #expect(h.extraction.ids == ["9100020"])
            #expect(h.diskLog?.map(\.id) == ["9100020"])

            // Second sync: the recent post is already processed, and the new
            // arrival is 30 days old, so nothing is unprocessed. The early
            // return must not skip the log.
            h.response = [recent, announcement("9100021", daysAgo: 30, now: now)]
            await h.state.syncAnnouncements(now: now)
            #expect(h.extraction.ids == ["9100020"])
            #expect(Set(h.diskLog?.map(\.id) ?? []) == ["9100020", "9100021"])
            #expect(Set(h.state.announcementRecordsOnPage.map(\.id)) == ["9100020", "9100021"])
        }
    }

    @Test("a fetch error leaves the log exactly as it was")
    func fetchErrorLeavesLogAlone() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [announcement("9100030", daysAgo: 2, now: now)]
            await h.state.syncAnnouncements(now: now)
            let before = try #require(h.diskLog)
            let pageBefore = h.state.announcementRecordsOnPage
            #expect(before.map(\.id) == ["9100030"])

            h.response = nil   // the next fetch throws
            await h.state.syncAnnouncements(now: now.addingTimeInterval(60))
            #expect(h.fetchCalls.count == 2)
            #expect(h.diskLog == before)
            #expect(h.state.announcementRecordsOnPage == pageBefore)
        }
    }

    @Test("an error on the very first fetch writes nothing, so the first real fill is still the first fill")
    func firstFetchErrorWritesNothing() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = nil
            await h.state.syncAnnouncements(now: now)
            #expect(h.diskLog == nil)

            h.response = [announcement("9100031", daysAgo: 2, now: now)]
            await h.state.syncAnnouncements(now: now)
            #expect(h.state.unreadAnnouncementCount == 0)
        }
    }

    // MARK: Seen state

    @Test("the first fill counts as already seen; a later arrival is unread; opening the sheet marks all seen")
    func firstFillIsNotNew() async throws {
        try await withHarness { h in
            let now = Date()
            let a = announcement("9100040", daysAgo: 20, now: now)
            let b = announcement("9100041", daysAgo: 4, now: now)
            let c = announcement("9100042", daysAgo: 0.1, now: now)

            h.response = [a, b]
            await h.state.syncAnnouncements(now: now)
            #expect(h.state.announcementRecordsOnPage.count == 2)
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(h.state.showsAnnouncementsButton)

            h.response = [a, b, c]
            await h.state.syncAnnouncements(now: now.addingTimeInterval(300))
            #expect(h.state.unreadAnnouncementCount == 1)

            let newIDs = h.state.openAnnouncementsSheet()
            #expect(newIDs == [AnnouncementReadState.recordKey("9100042")])
            #expect(h.state.unreadAnnouncementCount == 0)
            // Persisted, not just in memory.
            #expect(AnnouncementReadState(defaults: h.scratch).seenIDs
                == Set(["9100040", "9100041", "9100042"].map(AnnouncementReadState.recordKey)))
        }
    }

    @Test("an empty first fill still counts as the first fill")
    func emptyFirstFill() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = []
            await h.state.syncAnnouncements(now: now)
            #expect(h.diskLog == [])
            #expect(!h.state.showsAnnouncementsButton)

            h.response = [announcement("9100050", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)
            #expect(h.state.unreadAnnouncementCount == 1)
            #expect(h.state.showsAnnouncementsButton)
        }
    }

    @Test("the first fill marks records seen but leaves the extractor's finds unread, and the badge adds both")
    func badgeAddsFindsAndRecords() async throws {
        try await withHarness(tasksPerAnnouncement: 1) { h in
            let now = Date()
            h.response = [announcement("9100060", daysAgo: 2, now: now),
                          announcement("9100061", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)

            // Two finds (one per extracted announcement), unread; two records, seen.
            #expect(h.state.announcementPageItems.count == 2)
            #expect(h.state.announcementRecordsOnPage.count == 2)
            #expect(h.state.unreadAnnouncementCount == 2)

            // A third post arrives later: one more find, one more record.
            h.response = (h.response ?? []) + [announcement("9100062", daysAgo: 0.1, now: now)]
            await h.state.syncAnnouncements(now: now.addingTimeInterval(300))
            #expect(h.state.unreadAnnouncementCount == 2 + 1 + 1)

            let newIDs = h.state.openAnnouncementsSheet()
            #expect(newIDs.contains(AnnouncementReadState.recordKey("9100062")))
            #expect(newIDs.count == 4)
            #expect(h.state.unreadAnnouncementCount == 0)
        }
    }

    // MARK: Display

    @Test("a hidden or deleted class's records leave the list and return with it, newest first")
    func listFollowsClassSelection() async throws {
        let courses: [(id: String, code: String)] = [
            ("9101", "ANLOG 9101"), ("9102", "ANLOG 9102"), ("9103", "ANLOG 9103"),
        ]
        try await withHarness(courses: courses) { h in
            let now = Date()
            h.response = [
                announcement("9100070", course: "9101", daysAgo: 5, now: now),
                announcement("9100071", course: "9102", daysAgo: 1, now: now),
                announcement("9100072", course: "9101", daysAgo: 3, now: now),
                announcement("9100073", course: "9103", daysAgo: 2, now: now),
            ]
            await h.state.syncAnnouncements(now: now)
            #expect(h.state.announcementRecordsOnPage.map(\.id) == ["9100071", "9100073", "9100072", "9100070"])

            h.state.setCourse("ANLOG 9102", selected: false)
            #expect(h.state.announcementRecordsOnPage.map(\.id) == ["9100073", "9100072", "9100070"])

            h.state.deleteCourse("ANLOG 9103")
            #expect(h.state.announcementRecordsOnPage.map(\.id) == ["9100072", "9100070"])

            h.state.restoreCourse("ANLOG 9103")
            h.state.setCourse("ANLOG 9102", selected: true)
            #expect(h.state.announcementRecordsOnPage.map(\.id) == ["9100071", "9100073", "9100072", "9100070"])

            // Hidden-class records stay on disk: hiding is not forgetting.
            #expect(h.diskLog?.count == 4)
        }
    }

    @Test("the log is read back from disk by the next AppState, before any sync")
    func listSurvivesRelaunch() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [announcement("9100080", daysAgo: 2, now: now)]
            await h.state.syncAnnouncements(now: now)

            let relaunched = AppState(assignmentStore: try AssignmentStore(inMemory: true))
            relaunched.forceFixtureDataForTesting(false)
            relaunched.enableAnnouncementLogForTesting(directory: h.directory, defaults: h.scratch)
            relaunched.canvasItems = h.state.canvasItems
            relaunched.setCourse("ANLOG 9101", selected: true)
            #expect(relaunched.announcementLogRecords.map(\.id) == ["9100080"])
            #expect(relaunched.announcementRecordsOnPage.map(\.id) == ["9100080"])
            #expect(relaunched.unreadAnnouncementCount == 0)
        }
    }

    // MARK: Disconnect

    @Test("disconnecting Canvas clears the log, the list and the record ids in the seen set")
    func disconnectClearsLog() async throws {
        try await withHarness(tasksPerAnnouncement: 1) { h in
            let now = Date()
            h.response = [announcement("9100090", daysAgo: 2, now: now)]
            await h.state.syncAnnouncements(now: now)
            _ = h.state.openAnnouncementsSheet()
            #expect(h.diskLog?.count == 1)
            #expect(!h.state.announcementRecordsOnPage.isEmpty)
            #expect(AnnouncementReadState(defaults: h.scratch).seenIDs.contains(AnnouncementReadState.recordKey("9100090")))

            h.state.disconnectCanvas()

            #expect(h.diskLog == nil)
            #expect(!FileManager.default.fileExists(atPath: AnnouncementLogStore(directory: h.directory).fileURL.path))
            #expect(h.state.announcementRecordsOnPage.isEmpty)
            #expect(h.state.announcementLogRecords.isEmpty)
            #expect(!AnnouncementReadState(defaults: h.scratch).seenIDs.contains { AnnouncementReadState.isRecordKey($0) })
            #expect(!h.state.announcementSeenIDs.contains { AnnouncementReadState.isRecordKey($0) })
        }
    }

    // MARK: Test-runner isolation and nothing-new-leaves-the-phone

    @Test("an AppState that did not opt in has no log and never touches the real Application Support file")
    func defaultStateHasNoLog() throws {
        // Under the test runner `announcementLog` is nil until a test opts in
        // with a scratch directory, which is what keeps `init` from reading
        // (and the sync from writing) the real file.
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        #expect(state.announcementLog == nil)
        #expect(state.announcementRecordsOnPage.isEmpty)
        #expect(!state.showsAnnouncementsButton)
    }

    @Test("the log code makes no network call and builds no backend request")
    func logCodeIsLocalOnly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Tests/LowHangingFruitKitTests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // .../LowHangingFruitKit
            .appendingPathComponent("Sources")
        let files = [
            "LowHangingFruitKit/Canvas/AnnouncementLog.swift",
            "LowHangingFruitUI/AppState+AnnouncementLog.swift",
            "LowHangingFruitUI/AnnouncementReadState.swift",
        ].map { sources.appendingPathComponent($0) }
        // A prebuilt test bundle run away from the checkout has nothing to scan.
        guard FileManager.default.fileExists(atPath: sources.path) else { return }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["URLSession", "URLRequest", "BackendServices", "BackendClient", "BackendAnnouncementExtractor"] {
                #expect(!text.contains(forbidden), "\(file.lastPathComponent) mentions \(forbidden)")
            }
        }
    }
}
