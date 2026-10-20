import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// What the Ed pass (`syncEdAnnouncementTasks`) gained when the two lines of
/// work were merged on 2026-10-20: the header's posting day as the post's date
/// and the window's, the twin check before anything is written, a quota
/// refusal that ends the run without starting a retry clock, and a one-line
/// summary of each run that read posts. The rest of the pass is
/// `EdAnnouncementTaskTests`'.
///
/// Not compiled when written (no toolchain on the machine it was written on).
/// Same discipline as that suite: the processed ids, the retry clock and the
/// new summary key live in the shared defaults domain, so they are backed up
/// and restored, and every thread id and class code here is unique to this
/// suite (`EDMERGE 9601`, threads 96xxxxx).
@MainActor
@Suite("Ed announcement tasks: merged behaviour", .serialized)
struct EdAnnouncementTaskMergeTests {
    private static let day: TimeInterval = 24 * 3600
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let processedKey = "processedAnnouncementIDsV1"
    private static let retryKey = "edTaskRetryAfterV1"
    private static let summaryKey = "lastEdTaskSyncSummaryV1"
    private static let courseID = "9601"
    private static let code = "EDMERGE 9601"

    /// 2027-01-15, the clock `EdAnnouncementTaskTests` uses.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func document(
        _ thread: String,
        daysAgo: Double? = 1,
        posted: String? = nil,
        title: String = "Lab report",
        body: String = "Please submit the lab report by Friday."
    ) -> CourseDocument {
        AnnouncementEdRowsTests.edDocument(
            thread: thread, courseID: Self.courseID, course: Self.code, reason: "announcement", category: nil,
            body: body, daysAgo: daysAgo, title: title, now: Self.now, posted: posted
        )
    }

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    /// Records the call, then throws `error`, or answers with the tasks keyed
    /// to this post's id (`tasksByID`) or, failing that, `tasks`.
    private struct Extractor: AnnouncementAssignmentExtractor {
        let log: CallLog
        var tasks: [ExtractedAssignment] = []
        var tasksByID: [String: [ExtractedAssignment]] = [:]
        var error: (any Error)?
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            log.record(announcement.announcementID)
            if let error { throw error }
            return tasksByID[announcement.announcementID] ?? tasks
        }
    }

    private static var labReport: ExtractedAssignment {
        ExtractedAssignment(title: "Submit the lab report", dueAt: now.addingTimeInterval(2 * day), kind: .submission)
    }

    @MainActor
    private final class Harness {
        let state: AppState
        let store: AssignmentStore
        let calls = CallLog()
        init(state: AppState, store: AssignmentStore) {
            self.state = state
            self.store = store
        }
        var edRows: [Assignment] {
            store.assignments(source: .canvasAnnouncement).filter { $0.announcementOrigin == .ed }
        }
    }

    private func withHarness(
        documents: [CourseDocument],
        extractor: @escaping @MainActor (CallLog) -> any AnnouncementAssignmentExtractor,
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let keys = [Self.extractionVersionKey, Self.processedKey, Self.retryKey, Self.summaryKey]
        let saved = keys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: Self.extractionVersionKey)
        for key in [Self.processedKey, Self.retryKey, Self.summaryKey] { shared.removeObject(forKey: key) }

        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.canvasItems = [Assignment(
            source: .canvas, sourceID: "seed-\(Self.courseID)", kind: .assignment, course: Self.code,
            title: "Seed", dueAt: nil,
            url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/assignments/1")
        )]
        state.setCourse(Self.code, selected: true)
        defer {
            state.restoreCourse(Self.code)
            state.setCourse(Self.code, selected: true)
            state.coursePreferences.setCanvasCourseID(Self.code, nil)
        }
        state.courseKnowledge = CourseKnowledgeBase(documents: documents)

        let harness = Harness(state: state, store: store)
        let calls = harness.calls
        state.announcementExtractorForTesting = { _ in extractor(calls) }
        try await body(harness)
    }

    // MARK: The date is the posting day

    @Test("a post is dated by its header's posting day: an old post bumped recently is out of the window, a recent post whose last activity is old is in")
    func windowUsesThePostingDay() {
        // `now` is 2027-01-15. Both are announcements with text.
        let bumpedOld = document("9600101", daysAgo: 1, posted: "2026-12-01")
        let recentQuiet = document("9600102", daysAgo: 30, posted: "2027-01-14")
        let untokened = document("9600103", daysAgo: 1)

        #expect(AppState.edPostDate(bumpedOld) != bumpedOld.updatedAt)
        let eligible = AppState.edDocumentsEligibleForTasks(
            [bumpedOld, recentQuiet, untokened], now: Self.now
        )
        #expect(eligible.map(\.id) == [recentQuiet.id, untokened.id])
    }

    @Test("what the extractor is told about the post's date is the posting day too")
    func sourceTextCarriesThePostingDay() async throws {
        final class Captured: @unchecked Sendable {
            private let lock = NSLock()
            private var dates: [Date?] = []
            func record(_ date: Date?) { lock.lock(); dates.append(date); lock.unlock() }
            var all: [Date?] { lock.lock(); defer { lock.unlock() }; return dates }
        }
        struct Capturing: AnnouncementAssignmentExtractor {
            let captured: Captured
            func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
                captured.record(announcement.postedAt)
                return []
            }
        }
        let captured = Captured()
        let doc = document("9600201", daysAgo: 1, posted: "2027-01-12")
        try await withHarness(documents: [doc], extractor: { _ in Capturing(captured: captured) }) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            let expected = try #require(EdDocumentHeader.parse(doc.text).postedAt)
            #expect(captured.all == [expected])
            #expect(expected != doc.updatedAt)
        }
    }

    // MARK: Twins

    @Test("an Ed task that restates a task already on the ledger is dropped, the post still counts as read, and a different task is kept")
    func twinOfAnExistingFindIsDropped() async throws {
        let twin = document("9600301")
        let different = document("9600302", title: "Recitation", body: "Please bring a laptop to recitation.")
        let laptop = ExtractedAssignment(
            title: "Bring a laptop to recitation", dueAt: Self.now.addingTimeInterval(3 * Self.day), kind: .preparation
        )
        try await withHarness(
            documents: [twin],
            extractor: { Extractor(log: $0, tasks: [Self.labReport], tasksByID: [different.id: [laptop]]) }
        ) { h in
            // The Canvas copy, as `syncAnnouncements` would have filed it.
            h.store.upsert([Assignment(
                source: .canvasAnnouncement,
                sourceID: AnnouncementRecord.findSourceID(announcementID: "9600399", index: 0),
                kind: .assignment, course: Self.code, title: "Submit the lab report",
                dueAt: Self.now.addingTimeInterval(2 * Self.day),
                url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/discussion_topics/9600399")
            )])
            h.state.applyAnnouncementLedgerChange()

            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all == [twin.id])
            #expect(h.edRows.isEmpty, "the Ed copy of a task Canvas already announced is not written")
            #expect(h.state.processedAnnouncementIDs.contains(twin.id))

            // A different task from another post is kept.
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [twin, different])
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all == [twin.id, different.id])
            #expect(h.state.processedAnnouncementIDs.contains(different.id))
            #expect(h.edRows.map(\.title) == ["Bring a laptop to recitation"])
        }
    }

    @Test("two posts in one run that announce the same task make one find: the first read wins")
    func twinWithinOneRun() async throws {
        let first = document("9600311")
        let second = document("9600312", title: "Lab report reminder")
        try await withHarness(
            documents: [first, second],
            extractor: { Extractor(log: $0, tasks: [Self.labReport]) }
        ) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all.count == 2)
            #expect(h.edRows.count == 1)
            #expect(h.state.processedAnnouncementIDs.isSuperset(of: [first.id, second.id]))
        }
    }

    // MARK: Quota

    @Test("a quota refusal ends the run: the second post is not sent, no retry clock starts, nothing is marked read, and the summary names the kind")
    func quotaEndsTheRun() async throws {
        let first = document("9600401")
        let second = document("9600402", title: "Second")
        try await withHarness(
            documents: [first, second],
            extractor: { Extractor(log: $0, error: BackendError.quotaExceeded(resetAt: nil)) }
        ) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)

            #expect(h.calls.all.count == 1)
            #expect(h.state.processedAnnouncementIDs.isEmpty)
            #expect(UserDefaults.lhf.object(forKey: Self.retryKey) == nil, "a quota refusal is nobody's fault, so nothing waits")
            #expect(h.edRows.isEmpty)
            let summary = try #require(h.state.lastEdTaskSyncSummary)
            #expect(summary.hasSuffix("eligible 2 \u{00B7} finds 0 \u{00B7} errors 1 \u{00B7} processed 0 \u{00B7} first error: quota"))

            // Both are tried again on the next pass.
            await h.state.syncEdAnnouncementTasks(now: Self.now.addingTimeInterval(60))
            #expect(h.calls.all.count == 2)
        }
    }

    @Test("an ordinary failure still starts the post's retry clock, and the posts after it are still tried")
    func ordinaryFailureStillWaits() async throws {
        struct Failure: Error {}
        let first = document("9600411")
        let second = document("9600412", title: "Second")
        try await withHarness(
            documents: [first, second],
            extractor: { Extractor(log: $0, error: Failure()) }
        ) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all.count == 2)
            #expect(UserDefaults.lhf.object(forKey: Self.retryKey) != nil)
            let summary = try #require(h.state.lastEdTaskSyncSummary)
            #expect(summary.contains("errors 2"))
        }
    }

    // MARK: The summary

    @Test("a run that read a post writes counts and words only, and a run with nothing to read keeps that line behind its own")
    func summaryLines() async throws {
        let doc = document("9600501")
        try await withHarness(
            documents: [doc],
            extractor: { Extractor(log: $0, tasks: [Self.labReport]) }
        ) { h in
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            let ran = try #require(h.state.lastEdTaskSyncSummary)
            #expect(ran.hasPrefix(AppState.diagnosticStamp(Self.now) + " \u{00B7} "))
            #expect(ran.hasSuffix("eligible 1 \u{00B7} finds 1 \u{00B7} errors 0 \u{00B7} processed 1"))
            #expect(!ran.contains("Lab report"))
            #expect(!ran.contains("9600501"))
            #expect(!ran.contains("http"))
            #expect(UserDefaults.lhf.string(forKey: Self.summaryKey) == ran)

            let later = Self.now.addingTimeInterval(3600)
            await h.state.syncEdAnnouncementTasks(now: later)
            let skipped = try #require(h.state.lastEdTaskSyncSummary)
            #expect(skipped.hasPrefix(AppState.diagnosticStamp(later) + " \u{00B7} skipped: nothing eligible"))
            #expect(skipped.hasSuffix(" | last run: " + ran))
        }
    }

    @Test("in preview mode the pass says why it did nothing, and reads nothing")
    func summaryInPreview() async throws {
        let doc = document("9600601")
        try await withHarness(documents: [doc], extractor: { Extractor(log: $0, tasks: [Self.labReport]) }) { h in
            h.state.forceFixtureDataForTesting(true)
            await h.state.syncEdAnnouncementTasks(now: Self.now)
            #expect(h.calls.all.isEmpty)
            let summary = try #require(h.state.lastEdTaskSyncSummary)
            #expect(summary.hasSuffix("skipped: fixture"))
        }
    }
}
