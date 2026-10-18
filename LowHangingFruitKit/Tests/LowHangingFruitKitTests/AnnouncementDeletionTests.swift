import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A Canvas announcement that Canvas stops returning takes its cards off the
/// dashboard. The ledger keeps the rows (flagged `isGoneFromFeed`, and, unlike
/// a vanished feed item, never aged out and deleted), a task the student
/// finished stays in prev, and a response that cannot be trusted (empty,
/// failed, outside the window, a class that returned nothing, a post missed
/// only once) hides nothing.
///
/// Three layers: the store's targeted flags, the pure rule
/// (`announcementPresence`), and `syncAnnouncements()` end to end with the
/// Canvas fetch replaced by the per-instance seam.
@MainActor
@Suite("Deleted announcements", .serialized)
struct AnnouncementDeletionTests {
    private static let day: TimeInterval = 24 * 3600
    private static let processedKey = "processedAnnouncementIDsV1"
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let missCountsKey = "announcementMissCountsV1"

    // MARK: The store's flags

    private func row(_ sourceID: String, due: Date? = nil) -> Assignment {
        Assignment(source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment,
                   course: "ANDEL 9601", title: "Task \(sourceID)", dueAt: due, url: nil)
    }

    @Test("markGoneFromFeed flags exactly the rows asked for, keeps their completion, and markPresentInFeed undoes it")
    func storeFlags() throws {
        let store = try AssignmentStore(inMemory: true)
        let a = row("announcement-1-0")
        let b = row("announcement-2-0")
        store.upsert([a, b])
        store.setCompleted(ids: [a.id], at: Date())

        #expect(store.markGoneFromFeed(ids: [a.id, "canvasAnnouncement:no-such-row"]) == 1)
        #expect(store.goneFromFeedIDs(source: .canvasAnnouncement) == [a.id])
        // Nothing was deleted, and the completion is intact.
        #expect(Set(store.assignments(source: .canvasAnnouncement).map(\.id)) == [a.id, b.id])
        #expect(store.completionRecord().ids == [a.id])
        // Idempotent.
        #expect(store.markGoneFromFeed(ids: [a.id]) == 0)

        #expect(store.markPresentInFeed(ids: [a.id, b.id]) == 1)
        #expect(store.goneFromFeedIDs(source: .canvasAnnouncement).isEmpty)
        #expect(store.markGoneFromFeed(ids: []) == 0)
        #expect(store.markPresentInFeed(ids: []) == 0)
    }

    /// The trap this pins (CLAUDE.md, Traps): `markGoneFromFeed` was documented
    /// as "flagged, never deleted", while `isAgedOut` (run by `reconcile` on
    /// every Canvas sync, through `pruneAgedOut`) deleted any unfinished flagged
    /// row 14 days after its date. This test used to pin that deletion as the
    /// intended behaviour. A deleted row cannot be restored by
    /// `markPresentInFeed`, and the post's id is in `processedAnnouncementIDs`,
    /// so it is never extracted again either: the task is lost for good.
    @Test("a gone announcement row is never aged out and deleted, however old, and its post coming back restores it")
    func goneAnnouncementRowsSurviveAging() throws {
        let store = try AssignmentStore(inMemory: true)
        let long = Date().addingTimeInterval(-30 * Self.day)
        let canvas = row("announcement-3-0", due: long)
        let ed = row(AnnouncementRecord.edFindSourceID(courseID: "9601", threadID: "33", index: 0), due: long)
        let syllabus = row(AnnouncementRecord.syllabusFindSourceID(courseID: "9601", examKey: "midterm-1"), due: long)
        store.upsert([canvas, ed, syllabus])
        store.markGoneFromFeed(ids: [canvas.id, ed.id, syllabus.id])

        // The prune itself, and the one a Canvas sync runs.
        #expect(store.pruneAgedOut() == 0)
        let feed = Assignment(source: .canvas, sourceID: "event-assignment-1", kind: .assignment,
                              course: "ANDEL 9601", title: "Homework", dueAt: Date().addingTimeInterval(Self.day), url: nil)
        _ = store.reconcile([feed], source: .canvas)
        _ = store.reconcile([feed], source: .canvas)

        #expect(Set(store.allRowsForTesting().map(\.id)).isSuperset(of: [canvas.id, ed.id, syllabus.id]))
        #expect(store.goneFromFeedIDs(source: .canvasAnnouncement) == [canvas.id, ed.id, syllabus.id])

        // And it comes back.
        #expect(store.markPresentInFeed(ids: [canvas.id, ed.id, syllabus.id]) == 3)
        #expect(Set(store.assignments(source: .canvasAnnouncement).map(\.id)) == [canvas.id, ed.id, syllabus.id])
        #expect(store.goneFromFeedIDs(source: .canvasAnnouncement).isEmpty)
    }

    @Test("aging is unchanged for feed rows: a Canvas item gone from its feed and long overdue is still collected, finished work never")
    func feedRowsStillAge() throws {
        let store = try AssignmentStore(inMemory: true)
        let long = Date().addingTimeInterval(-30 * Self.day)
        func feed(_ id: String) -> Assignment {
            Assignment(source: .canvas, sourceID: id, kind: .assignment, course: "ANDEL 9601",
                       title: "Task \(id)", dueAt: long, url: nil)
        }
        let open = feed("event-assignment-10")
        let done = feed("event-assignment-11")
        let keep = feed("event-assignment-12")
        _ = store.reconcile([open, done, keep], source: .canvas)
        store.setCompleted(ids: [done.id], at: Date())

        // The next fetch lists only one of them: the other two are gone from the feed.
        _ = store.reconcile([keep], source: .canvas)
        #expect(Set(store.assignments(source: .canvas).map(\.id)) == [done.id, keep.id])
    }

    @Test("the widget's fallback leaves out an announcement row whose post is gone, now that aging no longer removes it")
    func widgetSkipsGoneAnnouncementRows() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-widget-gone-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try AssignmentStore(url: url)
        let now = Date()
        let live = row("announcement-5-0", due: now.addingTimeInterval(Self.day))
        let deleted = row("announcement-6-0", due: now.addingTimeInterval(2 * Self.day))
        store.upsert([live, deleted])
        store.markGoneFromFeed(ids: [deleted.id])

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url, now: now))
        #expect(snapshot.items.map(\.title) == ["Task announcement-5-0"])
    }

    // MARK: The pure rule

    private func record(_ id: String, course: String = "9601", posted: Date?) -> AnnouncementRecord {
        AnnouncementRecord(id: id, courseID: course, courseCode: "ANDEL 9601", title: "t",
                           postedAt: posted, url: nil, snippet: "", recordedAt: posted ?? Date())
    }

    private func fetched(_ id: String, course: String = "9601") -> CanvasAnnouncement {
        CanvasAnnouncement(id: id, courseID: course, title: "t", message: "m", postedAt: Date(), url: nil)
    }

    @Test("a post is missing only when the log knows it, dates it inside the window, and the fetch covered its class")
    func presenceRule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = AppState.announcementFetchWindow(now: now)
        let inside = record("1", posted: now.addingTimeInterval(-3 * Self.day))
        let atTheEdge = record("2", posted: window.since.addingTimeInterval(3600))
        let beyond = record("3", posted: window.since.addingTimeInterval(-3600))
        let undated = record("4", posted: nil)
        let otherClass = record("5", course: "9699", posted: now.addingTimeInterval(-3 * Self.day))
        let edRow = record("ed:9601:77", posted: now.addingTimeInterval(-3 * Self.day))
        let stillThere = record("6", posted: now.addingTimeInterval(-2 * Self.day))

        let result = AppState.announcementPresence(
            fetched: [fetched("6")],
            requestedCourseIDs: ["9601"],
            known: [inside, atTheEdge, beyond, undated, otherClass, edRow, stillThere],
            window: window
        )
        #expect(result?.missing == ["1"])
        #expect(result?.returned == ["6"])
    }

    @Test("a class the fetch returned nothing for is not judged, however many of its posts the log holds")
    func classWithNoReturnedPostIsNotJudged() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = AppState.announcementFetchWindow(now: now)
        let inOtherClass = record("1", course: "9602", posted: now.addingTimeInterval(-3 * Self.day))
        let inThisClass = record("2", course: "9601", posted: now.addingTimeInterval(-3 * Self.day))
        let result = AppState.announcementPresence(
            fetched: [fetched("7", course: "9601")],
            requestedCourseIDs: ["9601", "9602"],
            known: [inOtherClass, inThisClass],
            window: window
        )
        // Both classes were asked for; only 9601 came back with anything.
        #expect(result?.missing == ["2"])
    }

    @Test("a post must be missing from two judged fetches in a row; being seen, or not being judged, starts it over")
    func twoMissesInARow() {
        let first = AppState.advanceAnnouncementMisses(counts: [:], missing: ["1", "2"])
        #expect(first.counts == ["1": 1, "2": 1])
        #expect(first.confirmed.isEmpty)

        // Post 1 is missed again; post 2 came back (or drifted out of the window).
        let second = AppState.advanceAnnouncementMisses(counts: first.counts, missing: ["1"])
        #expect(second.confirmed == ["1"])
        #expect(second.counts == ["1": 2], "the dictionary holds only posts currently in doubt")

        // Seen in between: the next miss is a first miss again.
        let seen = AppState.advanceAnnouncementMisses(counts: second.counts, missing: [])
        #expect(seen.counts.isEmpty)
        let again = AppState.advanceAnnouncementMisses(counts: seen.counts, missing: ["1"])
        #expect(again.confirmed.isEmpty)
    }

    @Test("an empty fetch judges nothing")
    func emptyFetchJudgesNothing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = AppState.announcementPresence(
            fetched: [], requestedCourseIDs: ["9601"],
            known: [record("1", posted: now.addingTimeInterval(-3 * Self.day))],
            window: AppState.announcementFetchWindow(now: now)
        )
        #expect(result == nil)
    }

    // MARK: End to end

    private struct FetchFailure: Error {}

    @MainActor
    private final class Harness {
        let state: AppState
        let store: AssignmentStore
        var response: [CanvasAnnouncement]? = []
        init(state: AppState, store: AssignmentStore) {
            self.state = state
            self.store = store
        }
    }

    /// One task per post, titled after the post. The posts' titles are kept
    /// unlike on purpose: two similar titles with close due dates are
    /// duplicates by design (`AssignmentDeduplicator`), and these tests are
    /// about deletion, not about that.
    private struct OneTask: AnnouncementAssignmentExtractor {
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            [ExtractedAssignment(
                title: "Submit \(announcement.title)",
                dueAt: now.addingTimeInterval(2 * 24 * 3600),
                kind: .submission
            )]
        }
    }

    private static let titles: [String: String] = [
        "96000001": "cartography memo", "96000002": "tornado worksheet",
        "96000011": "harbour essay",
        "96000021": "glacier poster", "96000022": "orchestra reflection",
        "96000031": "vineyard survey", "96000032": "lantern analysis",
        "96000042": "kayak portfolio",
        "96000051": "granite quarry map", "96000052": "saffron harvest log",
        "96000061": "meridian lecture notes", "96000062": "cobalt mining brief",
        "96000063": "tundra field journal",
    ]

    private func withHarness(_ body: @MainActor (Harness) async throws -> Void) async throws {
        let shared = UserDefaults.lhf
        let keys = [Self.processedKey, Self.extractionVersionKey, Self.missCountsKey]
        let saved = keys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: Self.extractionVersionKey)
        shared.removeObject(forKey: Self.processedKey)
        shared.removeObject(forKey: Self.missCountsKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("announcement-deletion-\(UUID().uuidString)", isDirectory: true)
        let scratchName = "announcement-deletion-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: scratchName)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            scratch.removePersistentDomain(forName: scratchName)
        }

        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.enableAnnouncementLogForTesting(directory: directory, defaults: scratch)
        state.canvasItems = [Assignment(
            source: .canvas, sourceID: "seed-9601", kind: .assignment, course: "ANDEL 9601",
            title: "Seed", dueAt: nil, url: URL(string: "https://canvas.upenn.edu/courses/9601/assignments/1")
        )]
        state.setCourse("ANDEL 9601", selected: true)
        defer {
            state.restoreCourse("ANDEL 9601")
            state.setCourse("ANDEL 9601", selected: true)
            state.coursePreferences.setCanvasCourseID("ANDEL 9601", nil)
        }

        let harness = Harness(state: state, store: store)
        state.announcementFetchForTesting = { [harness] _, _, _ in
            guard let response = harness.response else { throw FetchFailure() }
            return response
        }
        state.announcementExtractorForTesting = { _ in OneTask() }
        try await body(harness)
    }

    private func post(_ id: String, daysAgo: Double, now: Date, course: String = "9601") -> CanvasAnnouncement {
        CanvasAnnouncement(
            id: id, courseID: course, title: Self.titles[id] ?? "lab report",
            message: "Please submit the lab report by Friday.",
            postedAt: now.addingTimeInterval(-daysAgo * Self.day),
            url: URL(string: "https://canvas.upenn.edu/courses/9601/discussion_topics/\(id)")
        )
    }

    private func cards(_ state: AppState) -> [String] {
        (state.assignments + state.laterAssignments + state.assessments)
            .filter { $0.course == "ANDEL 9601" && $0.source == .canvasAnnouncement }
            .map(\.title).sorted()
    }

    @Test("a deleted post's cards leave the dashboard and megaphone page, its rows stay flagged in the ledger, and the other post is untouched")
    func deletedPostIsHidden() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("96000001", daysAgo: 2, now: now), post("96000002", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state) == ["Submit cartography memo", "Submit tornado worksheet"])

            // The first is deleted in Canvas; the second still comes back. One
            // response proves nothing (the next test), a second one does.
            h.response = [post("96000002", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)
            await h.state.syncAnnouncements(now: now)

            #expect(cards(h.state) == ["Submit tornado worksheet"])
            #expect(h.state.announcementPageItems.map(\.title) == ["Submit tornado worksheet"])
            // Flagged, not deleted.
            let gone = h.store.goneFromFeedIDs(source: .canvasAnnouncement)
            #expect(gone == ["canvasAnnouncement:announcement-96000001-0"])
            // Both finds are still rows in the ledger.
            #expect(h.store.allRowsForTesting().filter { $0.sourceRaw == "canvasAnnouncement" }.count == 2)
        }
    }

    @Test("an empty or failed fetch hides nothing")
    func emptyAndFailedFetchHideNothing() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("96000011", daysAgo: 2, now: now)]
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state).count == 1)

            h.response = []
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state).count == 1)

            h.response = nil
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state).count == 1)
            #expect(h.store.goneFromFeedIDs(source: .canvasAnnouncement).isEmpty)
        }
    }

    @Test("a post that comes back gets its cards back")
    func restoredPost() async throws {
        try await withHarness { h in
            let now = Date()
            let first = post("96000021", daysAgo: 2, now: now)
            let second = post("96000022", daysAgo: 1, now: now)
            h.response = [first, second]
            await h.state.syncAnnouncements(now: now)

            h.response = [second]
            await h.state.syncAnnouncements(now: now)
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state) == ["Submit orchestra reflection"])

            h.response = [first, second]
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state) == ["Submit glacier poster", "Submit orchestra reflection"])
            #expect(h.store.goneFromFeedIDs(source: .canvasAnnouncement).isEmpty)
        }
    }

    @Test("a task the student finished stays in prev, completed, after its post is deleted")
    func finishedTaskSurvivesDeletion() async throws {
        try await withHarness { h in
            let now = Date()
            h.response = [post("96000031", daysAgo: 2, now: now), post("96000032", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)
            let finished = try #require(h.state.announcementItems.first { $0.title == "Submit vineyard survey" })
            h.state.markCompleted(finished)
            defer { h.state.markActive(finished) }

            h.response = [post("96000032", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)
            await h.state.syncAnnouncements(now: now)

            #expect(h.state.isCompleted(finished))
            #expect(h.store.completionRecord().ids.contains(finished.id))
            let vm = DashboardViewModel()
            vm.bind(to: h.state)
            let prev = vm.doneSections().flatMap(\.items).filter { $0.assignment.course == "ANDEL 9601" }
            #expect(prev.map(\.assignment.title) == ["Submit vineyard survey"])
            #expect(prev.allSatisfy { $0.isCompleted && !$0.isPast })
            #expect(cards(h.state) == ["Submit lantern analysis"])
        }
    }

    @Test("one response that lacks a post hides nothing; the same absence twice in a row does, and the post coming back restores the cards")
    func oneMissIsNotDeletion() async throws {
        try await withHarness { h in
            let now = Date()
            let kept = post("96000051", daysAgo: 1, now: now)
            let truncated = post("96000052", daysAgo: 2, now: now)
            h.response = [kept, truncated]
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state).count == 2)

            // A response cut short: the second post is not in it. Once.
            h.response = [kept]
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state).count == 2)
            #expect(h.store.goneFromFeedIDs(source: .canvasAnnouncement).isEmpty)

            // It comes back, so the next absence is a first absence again.
            h.response = [kept, truncated]
            await h.state.syncAnnouncements(now: now)
            h.response = [kept]
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state).count == 2)
            #expect(h.store.goneFromFeedIDs(source: .canvasAnnouncement).isEmpty)

            // Absent again, with nothing in between: now it is believed.
            await h.state.syncAnnouncements(now: now)
            #expect(cards(h.state) == ["Submit granite quarry map"])
            #expect(h.store.goneFromFeedIDs(source: .canvasAnnouncement).count == 1)
        }
    }

    @Test("a class that returned nothing in a fetch that returned other classes' posts is not judged, however often")
    func classThatReturnedNothingIsNotJudged() async throws {
        try await withHarness { h in
            // A second class, with its own posts on the phone.
            h.state.canvasItems += [Assignment(
                source: .canvas, sourceID: "seed-9602", kind: .assignment, course: "ANDEL 9602",
                title: "Seed", dueAt: nil, url: URL(string: "https://canvas.upenn.edu/courses/9602/assignments/1")
            )]
            h.state.setCourse("ANDEL 9602", selected: true)
            defer {
                h.state.restoreCourse("ANDEL 9602")
                h.state.coursePreferences.setCanvasCourseID("ANDEL 9602", nil)
            }

            let now = Date()
            let here = post("96000061", daysAgo: 1, now: now)
            let there1 = post("96000062", daysAgo: 2, now: now, course: "9602")
            let there2 = post("96000063", daysAgo: 3, now: now, course: "9602")
            h.response = [here, there1, there2]
            await h.state.syncAnnouncements(now: now)
            #expect(h.store.assignments(source: .canvasAnnouncement).count == 3)

            // Class 9602 is asked for and returns nothing (a truncated or refused
            // response), every time.
            h.response = [here]
            for _ in 0..<3 { await h.state.syncAnnouncements(now: now) }
            #expect(h.store.goneFromFeedIDs(source: .canvasAnnouncement).isEmpty)
        }
    }

    @Test("the miss counts are saved between syncs, keyed by post id")
    func missCountsArePersisted() async throws {
        try await withHarness { h in
            let now = Date()
            let kept = post("96000051", daysAgo: 1, now: now)
            let missed = post("96000052", daysAgo: 2, now: now)
            h.response = [kept, missed]
            await h.state.syncAnnouncements(now: now)
            h.response = [kept]
            await h.state.syncAnnouncements(now: now)

            let saved = UserDefaults.lhf.dictionary(forKey: Self.missCountsKey) as? [String: Int]
            #expect(saved == ["96000052": 1])
        }
    }

    @Test("an Ed task is never hidden by a Canvas fetch that does not mention it")
    func edRowsAreNotJudgedByCanvas() async throws {
        try await withHarness { h in
            let now = Date()
            let ed = Assignment(
                source: .canvasAnnouncement,
                sourceID: AnnouncementRecord.edFindSourceID(courseID: "9601", threadID: "96000041", index: 0),
                kind: .assignment, course: "ANDEL 9601", title: "Submit the Ed thing",
                dueAt: now.addingTimeInterval(2 * Self.day), url: nil
            )
            h.store.upsert([ed])
            h.state.applyAnnouncementLedgerChange()

            h.response = [post("96000042", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)
            h.response = [post("96000042", daysAgo: 1, now: now)]
            await h.state.syncAnnouncements(now: now)

            #expect(cards(h.state).contains("Submit the Ed thing"))
            #expect(!h.store.goneFromFeedIDs(source: .canvasAnnouncement).contains(ed.id))
        }
    }
}
