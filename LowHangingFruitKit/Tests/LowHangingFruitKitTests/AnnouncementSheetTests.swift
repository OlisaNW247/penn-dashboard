import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The megaphone sheet as the owner asked for it on 2026-10-18: the posts of
/// the past 7 days (and, since 2026-10-23, each class's newest post however
/// old, so a quiet class does not vanish), the tasks and exams found in them
/// that are still ahead (the syllabus's included), one class filter over both,
/// and a badge that counts only what the sheet can show.
///
/// The pure rules first (window, found list, filter), then the same rules
/// through an `AppState` (the badge and what opening the sheet marks seen),
/// then the words and structure the view is pinned to.
///
/// **Hermeticity.** The pure suite touches no state at all. The `AppState`
/// suite backs the announcement log with a temp directory and a scratch
/// `UserDefaults` suite (`enableAnnouncementLogForTesting`), keeps the ledger
/// in memory, and uses class codes unique to this file, so nothing reaches
/// the shared preferences domain or Application Support (CLAUDE.md's
/// shared-defaults trap).
@MainActor
@Suite("Announcements sheet: window, found list, class filter")
struct AnnouncementSheetRulesTests {
    static let day: TimeInterval = 24 * 60 * 60
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ id: String,
        course: String = "ANSHEET 7000",
        posted: Date?,
        recorded: Date? = nil
    ) -> AnnouncementRecord {
        AnnouncementRecord(
            id: id, courseID: "7000", courseCode: course, title: "Post \(id)", postedAt: posted,
            url: nil, snippet: "", recordedAt: recorded ?? posted ?? Self.now
        )
    }

    private func find(
        _ sourceID: String,
        title: String = "Submit the worksheet",
        course: String = "ANSHEET 7000",
        due: Date?,
        kind: Assignment.Kind = .assignment
    ) -> Assignment {
        Assignment(
            source: .canvasAnnouncement, sourceID: sourceID, kind: kind, course: course,
            title: title, dueAt: due, url: nil
        )
    }

    private func found(_ items: [Assignment], at now: Date = AnnouncementSheetRulesTests.now) -> [Assignment] {
        AppState.foundAnnouncementItems(items, dueAt: { $0.dueAt }, now: now)
    }

    // MARK: The 7-day window

    // The three window tests below are unchanged by the "each class's newest
    // post" rule on purpose: every older post in them has a newer post of its
    // own class inside the window, so it is still out. The cases where the
    // newest post is itself older than the window are the tests after them.

    @Test("a post from exactly 7 days ago is in, one second older is out, and nothing newer is dropped")
    func windowBoundary() {
        let now = Self.now
        let edge = record("1", posted: now.addingTimeInterval(-7 * Self.day))
        let justOutside = record("2", posted: now.addingTimeInterval(-7 * Self.day - 1))
        let recent = record("3", posted: now.addingTimeInterval(-2 * Self.day))
        let today = record("4", posted: now)
        let ahead = record("5", posted: now.addingTimeInterval(60))

        let shown = AppState.announcementRecordsInSheetWindow([justOutside, edge, recent, today, ahead], now: now)
        #expect(shown.map(\.id) == ["5", "4", "3", "1"])
        #expect(AppState.announcementSheetWindowDays == 7)
    }

    @Test("an undated post counts from when this phone first saw it, and the list is newest first whatever order it came in")
    func windowUsesSortDateAndOrders() {
        let now = Self.now
        let undatedSeenYesterday = record("10", posted: nil, recorded: now.addingTimeInterval(-Self.day))
        let undatedSeenLongAgo = record("11", posted: nil, recorded: now.addingTimeInterval(-30 * Self.day))
        let older = record("12", posted: now.addingTimeInterval(-5 * Self.day))
        let newer = record("13", posted: now.addingTimeInterval(-3 * Self.day))

        let shown = AppState.announcementRecordsInSheetWindow(
            [older, undatedSeenLongAgo, undatedSeenYesterday, newer], now: now
        )
        #expect(shown.map(\.id) == ["10", "13", "12"])
        #expect(AppState.announcementRecordsInSheetWindow([], now: now).isEmpty)
    }

    @Test("an Ed post is held to the same window as a Canvas one")
    func edPostsShareTheWindow() throws {
        let now = Self.now
        let fresh = try #require(AnnouncementRecord.edRecord(
            from: AnnouncementEdRowsTests.edDocument(thread: "801", daysAgo: 3, now: now), now: now
        ))
        let stale = try #require(AnnouncementRecord.edRecord(
            from: AnnouncementEdRowsTests.edDocument(thread: "802", daysAgo: 9, now: now), now: now
        ))
        #expect(fresh.isEd && stale.isEd)
        #expect(AppState.announcementRecordsInSheetWindow([stale, fresh], now: now).map(\.id) == [fresh.id])
    }

    // MARK: Each class's newest post, however old

    @Test("a class with posts 2 and 10 days old lists only the 2-day one")
    func newestInsideWindowAddsNothing() {
        let now = Self.now
        let recent = record("21", posted: now - 2 * Self.day)
        let older = record("20", posted: now - 10 * Self.day)

        #expect(AppState.announcementRecordsInSheetWindow([older, recent], now: now).map(\.id) == ["21"])
    }

    @Test("a class whose only post is 20 days old lists it")
    func onlyPostOutsideWindowIsListed() {
        let now = Self.now
        let lone = record("30", posted: now - 20 * Self.day)

        #expect(AppState.announcementRecordsInSheetWindow([lone], now: now).map(\.id) == ["30"])
    }

    @Test("a class with posts 10 and 20 days old lists only the 10-day one")
    func newestOutsideWindowIsTheOnlyOne() {
        let now = Self.now
        let tenDays = record("41", posted: now - 10 * Self.day)
        let twentyDays = record("40", posted: now - 20 * Self.day)

        #expect(AppState.announcementRecordsInSheetWindow([twentyDays, tenDays], now: now).map(\.id) == ["41"])
    }

    @Test("two spellings of one class are one class: PHYS 0151 and PHYS 151 earn a single newest post between them")
    func spellingsOfOneClassGroupTogether() {
        let now = Self.now
        // The newest is under the descriptor's spelling, the older under the
        // cleaned code. Grouped by raw string, the 10-day post would be the
        // newest of "PHYS 151" and be listed beside the 2-day one.
        let newerLeadingZero = record("51", course: "PHYS 0151", posted: now - 2 * Self.day)
        let olderPlain = record("50", course: "PHYS 151", posted: now - 10 * Self.day)
        #expect(AppState.announcementRecordsInSheetWindow([olderPlain, newerLeadingZero], now: now).map(\.id) == ["51"])

        // And when both are outside the window, one of them is still just one.
        let tenDays = record("53", course: "PHYS 151", posted: now - 10 * Self.day)
        let twentyDays = record("52", course: "PHYS 0151", posted: now - 20 * Self.day)
        #expect(AppState.announcementRecordsInSheetWindow([twentyDays, tenDays], now: now).map(\.id) == ["53"])
    }

    @Test("every class gets its newest post, mixed with the week's posts newest first, and no post is listed twice")
    func everyClassIsRepresented() {
        let now = Self.now
        // The owner's phone on 2026-10-23: a busy class, a class that posted
        // once in September, and a class that has not posted for weeks.
        let busyToday = record("60", course: "PHYS 0151", posted: now - 1 * Self.day)
        let busyMid = record("61", course: "PHYS 0151", posted: now - 4 * Self.day)
        let busyOld = record("62", course: "PHYS 0151", posted: now - 9 * Self.day)
        let quiet = record("63", course: "FNAR 0010", posted: now - 31 * Self.day)
        let quieterNewest = record("64", course: "CIS 2620", posted: now - 40 * Self.day)
        let quieterOlder = record("65", course: "CIS 2620", posted: now - 50 * Self.day)

        let shown = AppState.announcementRecordsInSheetWindow(
            [quieterOlder, busyOld, quiet, busyMid, quieterNewest, busyToday], now: now
        )
        #expect(shown.map(\.id) == ["60", "61", "63", "64"])
        #expect(Set(shown.map(\.id)).count == shown.count)
    }

    @Test("a class's newest post is chosen in the sheet's own order, so a same-second tie goes to the higher id, and an undated post counts from when it was first seen")
    func newestFollowsTheSheetsOrder() {
        let now = Self.now
        let moment = now - 12 * Self.day
        let tieLow = record("9", posted: moment)
        let tieHigh = record("10", posted: moment)
        #expect(AppState.announcementRecordsInSheetWindow([tieLow, tieHigh], now: now).map(\.id) == ["10"])

        // Undated and first seen 15 days ago is newer than one posted 20 days ago.
        let undated = record("71", course: "PHYS 0151", posted: nil, recorded: now - 15 * Self.day)
        let dated = record("70", course: "PHYS 0151", posted: now - 20 * Self.day)
        #expect(AppState.announcementRecordsInSheetWindow([dated, undated], now: now).map(\.id) == ["71"])
    }

    @Test("a Canvas post and an Ed post of one class compete as one class")
    func canvasAndEdShareAClass() throws {
        let now = Self.now
        let ed = try #require(AnnouncementRecord.edRecord(
            from: AnnouncementEdRowsTests.edDocument(
                thread: "803", course: "ANSHEET 7000", daysAgo: 12, now: now
            ), now: now
        ))
        let canvas = record("80", course: "ANSHEET 7000", posted: now - 20 * Self.day)
        #expect(ed.isEd)
        #expect(AppState.announcementRecordsInSheetWindow([canvas, ed], now: now).map(\.id) == [ed.id])
    }

    // MARK: The found list

    @Test("found means still ahead: an upcoming task, an undated one and one due this very second stay; a past one goes")
    func foundIsUpcoming() {
        let now = Self.now
        let upcoming = find("announcement-1-0", title: "Submit the lab report", due: now.addingTimeInterval(2 * Self.day))
        let undated = find("announcement-2-0", title: "Bring a calculator", due: nil)
        let dueNow = find("announcement-3-0", title: "Turn in the poster", due: now)
        let justPast = find("announcement-4-0", title: "Return the survey", due: now.addingTimeInterval(-1))
        let september = find("announcement-5-0", title: "Finish the reading response", due: now.addingTimeInterval(-40 * Self.day))

        let shown = found([september, justPast, undated, dueNow, upcoming])
        #expect(Set(shown.map(\.title)) == ["Submit the lab report", "Bring a calculator", "Turn in the poster"])
    }

    @Test("found takes Canvas announcement tasks, Ed tasks and the syllabus's exams")
    func foundSources() {
        let now = Self.now
        let canvas = find("announcement-10-0", title: "Submit the lab report", due: now + 2 * Self.day)
        let ed = find("ed-7000-55-0", title: "Post your question on Ed", due: now + 3 * Self.day)
        let exam = find("syllabus-7000-midterm-1", title: "Midterm 1", due: now + 6 * Self.day, kind: .event)

        let shown = found([exam, ed, canvas])
        #expect(shown.map(\.title) == ["Submit the lab report", "Post your question on Ed", "Midterm 1"])
        #expect(shown.map(\.announcementOrigin) == [.canvas, .ed, .syllabus])
        #expect(shown.last?.isFoundExam == true)
    }

    @Test("past is judged by the date the card shows, so an edit can bring a task back or put one away")
    func foundHonoursEditedDates() {
        let now = Self.now
        let movedForward = find("announcement-20-0", title: "Submit the lab report", due: now - 3 * Self.day)
        let movedBack = find("announcement-21-0", title: "Return the survey", due: now + 3 * Self.day)
        let edits: [String: Date] = [
            movedForward.id: now + 2 * Self.day,
            movedBack.id: now - Self.day,
        ]

        let shown = AppState.foundAnnouncementItems(
            [movedForward, movedBack], dueAt: { edits[$0.id] ?? $0.dueAt }, now: now
        )
        #expect(shown.map(\.id) == [movedForward.id])
    }

    @Test("found is soonest first with the undated last, and one exam named twice is one card")
    func foundOrderAndTwins() {
        let now = Self.now
        let later = find("announcement-30-0", title: "Submit the lab report", due: now + 5 * Self.day)
        let sooner = find("announcement-31-0", title: "Return the survey", due: now + Self.day)
        let undated = find("announcement-32-0", title: "Bring a calculator", due: nil)
        #expect(found([undated, later, sooner]).map(\.id) == [sooner.id, later.id, undated.id])

        // The syllabus and an announcement both say Midterm 1 is on the 23rd.
        let day23 = now + 4 * Self.day
        let fromSyllabus = find("syllabus-7000-midterm-1", title: "Midterm 1", due: day23, kind: .event)
        let announced = find("announcement-33-0", title: "Midterm 1", due: day23)
        let twins = found([fromSyllabus, announced])
        #expect(twins.count == 1)
        #expect(twins.first?.id == announced.id)
    }

    @Test("found is the dashboard's own visibility rule: an undated task a week past its post, and a same-day be-there reminder, are off the list")
    func foundFollowsTheDashboardRule() {
        let now = Self.now
        var dates = AppState.AnnouncementPostDates()
        func post(_ id: String, ago: TimeInterval) { dates.canvas[id] = now - ago }

        // Undated: shown six days after its post, hidden from the eighth.
        let freshUndated = find("announcement-60-0", title: "Read chapter 4", due: nil)
        let staleUndated = find("announcement-61-0", title: "Read chapter 5", due: nil)
        post("60", ago: 6 * Self.day)
        post("61", ago: 8 * Self.day)

        // A same-day reminder to be somewhere, posted an hour ago for later today.
        let reminder = find("announcement-62-0", title: "Attend the weekly rotation quiz", due: now + 2 * 3600)
        // A real deadline for the same day is not a reminder.
        let deadline = find("announcement-63-0", title: "Submit the lab report", due: now + 2 * 3600)
        // The same wording, a week ahead, is preparation the student wants.
        let preparation = find("announcement-64-0", title: "Attend the review session", due: now + 7 * Self.day)
        post("62", ago: 3600)
        post("63", ago: 3600)
        post("64", ago: 3600)

        // A syllabus exam is no post's, so it is never aged, whatever the ledger says.
        let exam = find("syllabus-7000-final", title: "Final Exam", due: now + 30 * Self.day, kind: .event)
        dates.firstSeen[exam.id] = now - 90 * Self.day

        let all = [freshUndated, staleUndated, reminder, deadline, preparation, exam]
        let shown = AppState.foundAnnouncementItems(all, dueAt: { $0.dueAt }, postDates: dates, now: now)
        #expect(Set(shown.map(\.id)) == [freshUndated.id, deadline.id, preparation.id, exam.id])
    }

    @Test("found is exactly the rows the dashboard rule does not hide, one for one")
    func foundIsTheNotHiddenSet() {
        let now = Self.now
        var dates = AppState.AnnouncementPostDates()
        var rows: [Assignment] = []
        // Titles that are plainly different tasks: near-identical ones with close
        // dates are one card by design (`resolvingAnnouncementDuplicates`).
        let titles = [
            "Submit the lab report", "Return the survey", "Finish the essay", "Turn in the poster",
            "Email your advisor", "Upload the dataset", "Write the abstract",
        ]
        for (index, offset) in [-40.0, -3.0, -0.1, 0.0, 0.1, 2.0, 9.0].enumerated() {
            let row = find("announcement-7\(index)-0", title: titles[index], due: now + offset * Self.day)
            rows.append(row)
            dates.canvas["7\(index)"] = now - 1 * Self.day
        }
        rows.append(find("announcement-79-0", title: "Undated old task", due: nil))
        dates.canvas["79"] = now - 20 * Self.day

        let expected = rows.filter {
            !AppState.isHiddenAnnouncementTask(
                $0, dueAt: $0.dueAt, postedAt: dates.postedAt(for: $0),
                firstSeenAt: dates.firstSeenAt(for: $0), now: now
            )
        }
        let shown = AppState.foundAnnouncementItems(rows, dueAt: { $0.dueAt }, postDates: dates, now: now)
        #expect(Set(shown.map(\.id)) == Set(expected.map(\.id)))
        #expect(!expected.isEmpty && expected.count < rows.count)
    }

    // MARK: The class filter

    @Test("the class filter narrows both lists, keeps their order, and all classes means no narrowing")
    func classFilterNarrowsBothLists() {
        let now = Self.now
        let a1 = record("40", course: "ANSHEET 7001", posted: now - Self.day)
        let b1 = record("41", course: "ANSHEET 7002", posted: now - 2 * Self.day)
        let a2 = record("42", course: "ANSHEET 7001", posted: now - 3 * Self.day)
        let records = [a1, b1, a2]

        func card(_ assignment: Assignment) -> DashItem {
            DashItem(assignment: assignment, dueOverride: nil, isCompleted: false, completedAt: nil)
        }
        let taskA = card(find("announcement-50-0", course: "ANSHEET 7001", due: now + Self.day))
        let taskB = card(find("announcement-51-0", title: "Return the survey", course: "ANSHEET 7002", due: now + 2 * Self.day))
        let examA = card(find("syllabus-7001-final", title: "Final Exam", course: "ANSHEET 7001", due: now + 9 * Self.day, kind: .event))
        let cards = [taskA, taskB, examA]

        #expect(AppState.announcementSheetNarrowed(records, toCourse: nil) == records)
        #expect(AppState.announcementSheetNarrowed(cards, toCourse: nil) == cards)

        #expect(AppState.announcementSheetNarrowed(records, toCourse: "ANSHEET 7001").map(\.id) == ["40", "42"])
        #expect(AppState.announcementSheetNarrowed(cards, toCourse: "ANSHEET 7001").map(\.id) == [taskA.id, examA.id])
        #expect(AppState.announcementSheetNarrowed(records, toCourse: "ANSHEET 7002").map(\.id) == ["41"])
        #expect(AppState.announcementSheetNarrowed(cards, toCourse: "ANSHEET 7002").map(\.id) == [taskB.id])
        #expect(AppState.announcementSheetNarrowed(records, toCourse: "ANSHEET 7003").isEmpty)
        #expect(AppState.announcementSheetNarrowed(cards, toCourse: "ANSHEET 7003").isEmpty)
    }

    @Test("a class is matched by identity, not by spelling: a leading zero in the number does not hide its rows")
    func classFilterMatchesByIdentity() {
        #expect(AppState.announcementSheetCourseMatches("PHYS 0151", filter: "PHYS 151"))
        #expect(AppState.announcementSheetCourseMatches("PHYS 151", filter: "PHYS 0151"))
        #expect(AppState.announcementSheetCourseMatches("phys 151", filter: "PHYS 151"))
        #expect(!AppState.announcementSheetCourseMatches("PHYS 152", filter: "PHYS 151"))
        #expect(!AppState.announcementSheetCourseMatches("CIS 151", filter: "PHYS 151"))
        #expect(AppState.announcementSheetCourseMatches("anything at all", filter: nil))
    }
}

/// The same rules through an `AppState`: the badge counts exactly the two
/// lists the sheet shows, and opening the sheet marks exactly those seen.
@MainActor
@Suite("Announcements sheet: badge and read state in an AppState", .serialized)
struct AnnouncementSheetBadgeTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let course = "ANSHEET 7101"
    private static let courseID = "7101"

    private final class Harness {
        let state: AppState
        let scratch: UserDefaults
        let rows: [String: Assignment]
        var seenOnDisk: Set<String> { AnnouncementReadState(defaults: scratch).seenIDs }

        init(state: AppState, scratch: UserDefaults, rows: [String: Assignment]) {
            self.state = state
            self.scratch = scratch
            self.rows = rows
        }
    }

    private func task(_ sourceID: String, title: String, due: Date?, kind: Assignment.Kind = .assignment) -> Assignment {
        Assignment(
            source: .canvasAnnouncement, sourceID: sourceID, kind: kind, course: Self.course,
            title: title, dueAt: due, url: nil
        )
    }

    private func ed(_ thread: String, daysAgo: Double, now: Date) -> CourseDocument {
        AnnouncementEdRowsTests.edDocument(
            thread: thread, courseID: Self.courseID, course: Self.course, reason: "announcement",
            body: "Body of \(thread).", daysAgo: daysAgo, title: "Post \(thread)", now: now
        )
    }

    /// A state holding four found rows (an upcoming Canvas task, a past one,
    /// an upcoming Ed task and an upcoming syllabus exam) for one class, with
    /// the announcement log opted in.
    private func withHarness(
        extra: (Date) -> [String: Assignment] = { _ in [:] },
        _ body: @MainActor (Harness, Date) async throws -> Void
    ) async throws {
        let now = Date()
        var rows = [
            "upcoming": task("announcement-71010001-0", title: "Submit the lab report", due: now + 2 * Self.day),
            "past": task("announcement-71010002-0", title: "Return the survey", due: now - 3 * Self.day),
            "ed": task("ed-7101-91-0", title: "Post your question on Ed", due: now + 3 * Self.day),
            "exam": task("syllabus-7101-midterm-1", title: "Midterm 1", due: now + 6 * Self.day, kind: .event),
        ]
        rows.merge(extra(now)) { _, new in new }

        let store = try AssignmentStore(inMemory: true)
        store.upsert(Array(rows.values))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("announcement-sheet-\(UUID().uuidString)", isDirectory: true)
        let scratchName = "announcement-sheet-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: scratchName)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            scratch.removePersistentDomain(forName: scratchName)
        }

        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.enableAnnouncementLogForTesting(directory: directory, defaults: scratch)
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
        state.rebuildDashboardItemsForTesting(now: now)

        try await body(Harness(state: state, scratch: scratch, rows: rows), now)
    }

    @Test("the found list is the upcoming rows, syllabus exam included, and the page keeps the past one the sheet will not show")
    func foundListInAnAppState() async throws {
        try await withHarness { h, now in
            let page = Set(h.state.announcementPageItems.map(\.id))
            #expect(page == Set(h.rows.values.map(\.id)))

            let found = h.state.announcementFoundItems(now: now)
            #expect(Set(found.map(\.id)) == [h.rows["upcoming"]!.id, h.rows["ed"]!.id, h.rows["exam"]!.id])
            #expect(!found.contains { $0.id == h.rows["past"]!.id })
            #expect(found.map(\.title) == ["Submit the lab report", "Post your question on Ed", "Midterm 1"])

            let cards = h.state.announcementFoundCards(now: now)
            #expect(cards.map(\.id) == found.map(\.id))
            #expect(cards.first { $0.id == h.rows["exam"]!.id }?.examStyleOverride == true)
            #expect(cards.first { $0.id == h.rows["upcoming"]!.id }?.examStyleOverride == nil)
        }
    }

    @Test("a finished task leaves the found list and the badge")
    func completedLeavesFound() async throws {
        try await withHarness { h, now in
            let upcoming = h.rows["upcoming"]!
            #expect(h.state.announcementFoundItems(now: now).contains { $0.id == upcoming.id })
            #expect(h.state.announcementBadgeCount(now: now) == 3)

            h.state.markCompleted(upcoming)
            #expect(!h.state.announcementFoundItems(now: now).contains { $0.id == upcoming.id })
            #expect(h.state.announcementBadgeCount(now: now) == 2)
        }
    }

    @Test("the badge counts unread found items and unread posts from the past 7 days, and nothing the sheet cannot show")
    func badgeCountsOnlyWhatTheSheetShows() async throws {
        try await withHarness { h, now in
            // The first Ed rows an install sees count as seen, so give it one
            // to be seeded with, then add the two that are unread.
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [ed("9701", daysAgo: 1, now: now)])
            #expect(h.state.announcementBadgeCount(now: now) == 3, "only the three upcoming finds are unread")

            let inside = ed("9702", daysAgo: 3, now: now)
            let outside = ed("9703", daysAgo: 10, now: now)
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [ed("9701", daysAgo: 1, now: now), inside, outside])

            // The log holds all three Ed rows, but the sheet lists two.
            #expect(h.state.announcementRecordsOnPage.count == 3)
            #expect(h.state.announcementSheetRecords(now: now).map(\.id) == [ed("9701", daysAgo: 1, now: now).id, inside.id])
            // Three finds + the one unread post in the window. Not the ten-day-old
            // post, and not the past task the page still holds.
            #expect(h.state.announcementBadgeCount(now: now) == 4)
            #expect(h.state.unreadAnnouncementCount == 4)
        }
    }

    @Test("a class's newest post is listed and counted even when it is older than 7 days; the post before it is not")
    func newestPostOutsideTheWindowIsListedAndCounted() async throws {
        try await withHarness { h, now in
            // The first Ed row an install sees counts as seen; the newer one
            // arrives later and is unread.
            let seeded = ed("9721", daysAgo: 25, now: now)
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [seeded])
            #expect(h.state.announcementBadgeCount(now: now) == 3, "only the three upcoming finds are unread")

            let newest = ed("9722", daysAgo: 20, now: now)
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [seeded, newest])

            // Neither is within 7 days. The class's newest is listed (and
            // unread, so counted); the 25-day-old one before it is not.
            #expect(h.state.announcementRecordsOnPage.count == 2)
            #expect(h.state.announcementSheetRecords(now: now).map(\.id) == [newest.id])
            #expect(h.state.announcementBadgeCount(now: now) == 4)
            #expect(h.state.unreadAnnouncementCount == 4)
        }
    }

    @Test("opening the sheet marks only what it shows as seen, and reports those as new")
    func openingMarksOnlyShownRows() async throws {
        try await withHarness { h, now in
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [ed("9711", daysAgo: 1, now: now)])
            let inside = ed("9712", daysAgo: 3, now: now)
            let outside = ed("9713", daysAgo: 10, now: now)
            h.state.courseKnowledge = CourseKnowledgeBase(
                documents: [ed("9711", daysAgo: 1, now: now), inside, outside]
            )

            let newIDs = h.state.openAnnouncementsSheet(now: now)
            #expect(newIDs == [
                h.rows["upcoming"]!.id, h.rows["ed"]!.id, h.rows["exam"]!.id,
                AnnouncementReadState.edKey(inside.id),
            ])
            #expect(h.state.announcementBadgeCount(now: now) == 0)

            let seen = h.seenOnDisk
            #expect(seen.contains(h.rows["exam"]!.id))
            #expect(seen.contains(AnnouncementReadState.edKey(inside.id)))
            // Not shown, so not marked: the past task and the ten-day-old post.
            #expect(!seen.contains(h.rows["past"]!.id))
            #expect(!seen.contains(AnnouncementReadState.edKey(outside.id)))
        }
    }

    @Test("an undated task a week past its post leaves the found list and the badge, as it leaves the dashboard; a later one stays")
    func agedUndatedTaskLeavesFoundAndBadge() async throws {
        try await withHarness(extra: { now in [
            "undated": task("announcement-71010003-0", title: "Read chapter 4", due: nil),
            "late": task("announcement-71010004-0", title: "Submit the term paper", due: now + 20 * Self.day),
        ] }) { h, now in
            let undated = h.rows["undated"]!, late = h.rows["late"]!
            // Today the ledger first saw the undated row a moment ago, so it is in.
            #expect(h.state.announcementFoundItems(now: now).contains { $0.id == undated.id })
            #expect(h.state.announcementBadgeCount(now: now) == 5)

            // Eight days on, everything dated but the term paper is past and the
            // undated task is a week old. The page still holds them all (it is
            // not narrowed); the found list and the badge are.
            let later = now + 8 * Self.day
            #expect(h.state.announcementFoundItems(now: later).map(\.id) == [late.id])
            #expect(h.state.announcementBadgeCount(now: later) == 1)
            #expect(h.state.announcementPageItems.contains { $0.id == undated.id })
        }
    }

    @Test("a same-day be-there reminder is off the found list and the badge once its post's date is known; the page still holds the row")
    func reminderLeavesFoundAndBadge() async throws {
        try await withHarness(extra: { now in [
            "reminder": task("ed-7101-92-0", title: "Attend the weekly rotation quiz", due: now + 2 * 3600),
        ] }) { h, now in
            let reminder = h.rows["reminder"]!
            // Posted an hour ago, in Ed. The document is what gives the rule the
            // post's time; without it the card is kept.
            #expect(h.state.announcementFoundItems(now: now).contains { $0.id == reminder.id })
            h.state.courseKnowledge = CourseKnowledgeBase(
                documents: [ed("92", daysAgo: 1.0 / 24, now: now)]
            )
            #expect(h.state.announcementPageItems.contains { $0.id == reminder.id })
            #expect(!h.state.announcementFoundItems(now: now).contains { $0.id == reminder.id })
            #expect(h.state.announcementBadgeCount(now: now) == 3, "the three upcoming rows, not the reminder")
        }
    }

    @Test("a find whose real Canvas twin is finished leaves the page, the found list and the badge, with nothing written onto the find; un-finishing the twin brings it back")
    func finishedRealTwinTakesTheFindOffTheSheet() async throws {
        try await withHarness(extra: { now in [
            "worksheet": task("announcement-71010005-0", title: "Worksheet 6-7", due: now + 2 * Self.day),
        ] }) { h, now in
            let find = h.rows["worksheet"]!
            let real = Assignment(
                source: .canvas, sourceID: "\(Self.courseID)-ws67", kind: .assignment, course: Self.course,
                title: "Worksheet 6-7", dueAt: now + 2 * Self.day,
                url: URL(string: "https://canvas.upenn.edu/courses/\(Self.courseID)/assignments/67")
            )
            h.state.canvasItems.append(real)
            h.state.rebuildDashboardItemsForTesting(now: now)

            // Unfinished: the find is on the page and in the found list.
            #expect(h.state.announcementPageItems.contains { $0.id == find.id })
            #expect(h.state.announcementFoundItems(now: now).contains { $0.id == find.id })
            #expect(h.state.announcementBadgeCount(now: now) == 4)

            // The student turns in the real assignment.
            h.state.markCompleted(real)
            #expect(h.state.isCompleted(real))
            #expect(!h.state.announcementPageItems.contains { $0.id == find.id })
            #expect(!h.state.announcementFoundItems(now: now).contains { $0.id == find.id })
            #expect(h.state.announcementBadgeCount(now: now) == 3)
            // Display only: the find itself was never marked done.
            #expect(!h.state.completedAssignmentIDs.contains(find.id))
            #expect(!h.state.isCompleted(find))

            // Un-finish the twin and the find is back, so nothing was lost.
            h.state.markActive(real)
            #expect(h.state.announcementPageItems.contains { $0.id == find.id })
            #expect(h.state.announcementFoundItems(now: now).contains { $0.id == find.id })
            #expect(h.state.announcementBadgeCount(now: now) == 4)
        }
    }

    @Test("a hidden class's rows are on neither list nor in the badge")
    func hiddenClassIsOffTheBadge() async throws {
        try await withHarness { h, now in
            #expect(h.state.announcementBadgeCount(now: now) == 3)
            h.state.setCourse(Self.course, selected: false)
            #expect(h.state.announcementFoundItems(now: now).isEmpty)
            #expect(h.state.announcementBadgeCount(now: now) == 0)
        }
    }

    // MARK: The badge is stored, not recomputed per read (2026-10-20)

    @Test("a fresh AppState shows no badge, and refreshing stores exactly what the pure count says")
    func storedBadgeStartsAtZero() async throws {
        let fresh = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        #expect(fresh.unreadAnnouncementCount == 0)
        #expect(fresh.announcementBadge == 0)
        fresh.refreshAnnouncementBadge(now: Date())
        #expect(fresh.unreadAnnouncementCount == fresh.announcementBadgeCount(now: Date()))

        try await withHarness { h, now in
            // The harness's rebuild already stored it; no call from the test.
            #expect(h.state.unreadAnnouncementCount == 3)

            // Reading does not recompute: a clock that has moved on changes
            // nothing until something refreshes the stored number.
            let later = now + 8 * Self.day
            #expect(h.state.announcementBadgeCount(now: later) == 0)
            #expect(h.state.unreadAnnouncementCount == 3)

            h.state.refreshAnnouncementBadge(now: later)
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(h.state.unreadAnnouncementCount == h.state.announcementBadgeCount(now: later))

            h.state.refreshAnnouncementBadge(now: now)
            #expect(h.state.unreadAnnouncementCount == h.state.announcementBadgeCount(now: now))
            #expect(h.state.unreadAnnouncementCount == 3)
        }
    }

    @Test("marking the sheet's rows seen drops the stored badge with no explicit refresh")
    func openingTheSheetDropsTheStoredBadge() async throws {
        try await withHarness { h, now in
            #expect(h.state.unreadAnnouncementCount == 3)
            _ = h.state.openAnnouncementsSheet(now: now)
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(h.state.unreadAnnouncementCount == h.state.announcementBadgeCount(now: now))
        }
    }

    @Test("a rebuild updates the stored badge: finishing a found task lowers it")
    func rebuildUpdatesTheStoredBadge() async throws {
        try await withHarness { h, now in
            #expect(h.state.unreadAnnouncementCount == 3)
            // `markCompleted` ends in a rebuild; the test never refreshes.
            h.state.markCompleted(h.rows["upcoming"]!)
            #expect(h.state.unreadAnnouncementCount == 2)

            h.state.rebuildDashboardItemsForTesting(now: now)
            #expect(h.state.unreadAnnouncementCount == h.state.announcementBadgeCount(now: now))
        }
    }

    @Test("a rebuild at a later moment stores the count as of that moment")
    func rebuildAtALaterMomentAdvancesTheWindow() async throws {
        try await withHarness { h, now in
            #expect(h.state.unreadAnnouncementCount == 3)
            h.state.rebuildDashboardItemsForTesting(now: now + 8 * Self.day)
            #expect(h.state.unreadAnnouncementCount == 0)
        }
    }
}

/// The sheet's words and the shape of the view, pinned the way the other UI
/// suites pin theirs: by the source, which is skipped when the sources are not
/// beside the tests (a prebuilt bundle run elsewhere).
@Suite("Announcements sheet: copy and structure")
struct AnnouncementSheetStructureTests {

    @Test("the dismiss button says \"back to assignments\", and the view uses that word and not \"done\"")
    func dismissCopy() throws {
        #expect(AnnouncementSheetCopy.dismiss == "back to assignments")
        #expect(AnnouncementSheetCopy.dismiss == AnnouncementSheetCopy.dismiss.lowercased())

        let source = try GradeWatcherRemovalTests.uiSource("AnnouncementFindsView.swift")
        guard !source.isEmpty else { return }
        #expect(source.contains("Button(AnnouncementSheetCopy.dismiss)"))
        #expect(!source.contains("Button(\"done\")"))
    }

    @Test("the section words are short and lowercase, and an empty list still says one short line")
    func sectionCopy() {
        #expect(AnnouncementSheetCopy.foundHeader == "found")
        #expect(AnnouncementSheetCopy.announcementsHeader == "announcements")
        #expect(AnnouncementSheetCopy.emptyState == "no announcements")
        for line in [
            AnnouncementSheetCopy.foundHeader, AnnouncementSheetCopy.announcementsHeader,
            AnnouncementSheetCopy.emptyState, AnnouncementSheetCopy.dismiss,
        ] {
            #expect(line == line.lowercased())
        }
    }

    @Test("found comes before announcements, as dashboard cards, hidden when empty, under the dashboard's own class filter")
    func viewStructure() throws {
        let source = try GradeWatcherRemovalTests.uiSource("AnnouncementFindsView.swift")
        guard !source.isEmpty else { return }

        let found = try #require(source.range(of: "SmoothSectionHeader(AnnouncementSheetCopy.foundHeader"))
        let announcements = try #require(source.range(of: "SmoothSectionHeader(AnnouncementSheetCopy.announcementsHeader"))
        #expect(found.lowerBound < announcements.lowerBound)
        #expect(source.contains("AssignmentCardView("))
        #expect(source.contains("isExamOverride: item.examStyleOverride"))
        #expect(source.contains("if !foundNow.isEmpty"))
        #expect(source.contains("ClassFilterMenu("))
        #expect(source.contains("ClassFilterChip("))
        // The old plain rows and headers are gone.
        #expect(!source.contains("SmoothSectionHeader(\"tasks found\""))
        #expect(!source.contains("SmoothSectionHeader(\"all announcements\""))
    }

    @Test("the header megaphone is marigold and the dashboard's class filter is cobalt, and nothing else was repointed")
    func colours() throws {
        let content = try GradeWatcherRemovalTests.uiSource("ContentView.swift")
        let controls = try GradeWatcherRemovalTests.uiSource("DashboardControls.swift")
        let tokens = try GradeWatcherRemovalTests.uiSource("RedesignTokens.swift")
        guard !content.isEmpty, !controls.isEmpty, !tokens.isEmpty else { return }

        #expect(content.contains("headerCircle(icon: \"megaphone.fill\", color: .smoothMarigold)"))

        let menuStart = try #require(controls.range(of: "struct ClassFilterMenu: View"))
        let menuEnd = try #require(controls.range(of: "struct ClassFilterChip: View", range: menuStart.upperBound..<controls.endIndex))
        let menu = String(controls[menuStart.lowerBound..<menuEnd.lowerBound])
        #expect(menu.contains("Color.smoothCobalt.opacity("))
        #expect(menu.contains("foreground: Color.smoothCobaltInk"))

        // The sheet's own teal is where it was.
        #expect(tokens.contains("static let smoothAnnouncementAccent = Color.dynamic(light: 0x087D86, dark: 0x69DCE3)"))
    }
}
