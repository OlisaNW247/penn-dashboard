import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Ed Discussion announcements and pinned posts in the megaphone's "all
/// announcements" list, and the sheet's plainer rows. The pure half: which Ed
/// documents become rows, what a row says, the seen-set keys, and the read
/// state's carry rule. `AnnouncementEdSyncTests` below drives the same rules
/// through an `AppState`.
///
/// Nothing here touches the shared `UserDefaults` domain or real Application
/// Support: read state lives in scratch suites (CLAUDE.md's shared-defaults
/// trap).
@Suite("Announcement list: Ed rows, copy, read state")
struct AnnouncementEdRowsTests {
    private static let day: TimeInterval = 24 * 60 * 60
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// An Ed document as the builder writes it: a `[ed · reason] category`
    /// header line, then the body.
    static func edDocument(
        thread: String = "501",
        courseID: String = "9301",
        course: String = "ANED 9301",
        reason: String = "announcement",
        category: String? = "Homework / Hw 3",
        body: String = "Midterm moved to Friday.",
        daysAgo: Double? = 2,
        title: String = "Midterm moved",
        url: URL? = URL(string: "https://edstem.org/us/courses/1/discussion/501"),
        now: Date = AnnouncementEdRowsTests.now
    ) -> CourseDocument {
        let header = "[ed · \(reason)]" + (category.map { " " + $0 } ?? "")
        return CourseDocument(
            courseID: courseID, course: course, kind: .ed, sourceID: thread,
            title: title, url: url,
            text: body.isEmpty ? header : header + "\n" + body,
            updatedAt: daysAgo.map { now.addingTimeInterval(-$0 * day) },
            fetchedAt: now
        )
    }

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "announcement-ed-rows-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: Which Ed documents become rows

    @Test("an Ed announcement and a pinned post are listed; a plain staff post, an image-only post, a headerless one and a Canvas announcement are not")
    func onlyAnnouncementsAndPinnedAppear() {
        let announcement = Self.edDocument(thread: "1", reason: "announcement")
        let pinned = Self.edDocument(thread: "2", reason: "pinned")
        let staffPost = Self.edDocument(thread: "3", reason: "staff post")
        let imageOnly = Self.edDocument(thread: "4", reason: "announcement", body: "- [image]\n> [image]")
        let noBody = Self.edDocument(thread: "5", reason: "pinned", body: "")
        let headerless = CourseDocument(
            courseID: "9301", course: "ANED 9301", kind: .ed, sourceID: "6", title: "t", url: nil,
            text: "No header here, just words.", updatedAt: Self.now.addingTimeInterval(-Self.day), fetchedAt: Self.now
        )
        let canvasAnnouncement = CourseDocument(
            courseID: "9301", course: "ANED 9301", kind: .announcement, sourceID: "7", title: "t", url: nil,
            text: "[ed · announcement] looks like one but is a Canvas document",
            updatedAt: Self.now.addingTimeInterval(-Self.day), fetchedAt: Self.now
        )

        let rows = AnnouncementRecord.edRecords(
            from: [announcement, pinned, staffPost, imageOnly, noBody, headerless, canvasAnnouncement],
            now: Self.now
        )
        #expect(Set(rows.map(\.id)) == [announcement.id, pinned.id])
        #expect(AnnouncementRecord.edRecord(from: staffPost, now: Self.now) == nil)
        #expect(AnnouncementRecord.edRecord(from: imageOnly, now: Self.now) == nil)
    }

    @Test("an Ed post older than 60 days, or undated, is out; one just inside is in")
    func edWindow() {
        func row(daysAgo: Double?) -> AnnouncementRecord? {
            AnnouncementRecord.edRecord(from: Self.edDocument(daysAgo: daysAgo), now: Self.now)
        }
        #expect(row(daysAgo: 70) == nil)
        #expect(row(daysAgo: 61) == nil)
        #expect(row(daysAgo: 59) != nil)
        #expect(row(daysAgo: 0) != nil)
        #expect(row(daysAgo: nil) == nil)
    }

    @Test("an Ed row's snippet is the body only: no [ed · header, no [image] marks, and a plain-text < is not eaten as a tag")
    func edSnippet() {
        let document = Self.edDocument(
            reason: "pinned", category: "Quiz / Q1",
            body: "Quiz when x < 3 and y > 2.\n\n- [image]\nBring a pencil."
        )
        let row = AnnouncementRecord.edRecord(from: document, now: Self.now)
        #expect(row?.snippet == "Quiz when x < 3 and y > 2. - Bring a pencil.")
        #expect(row?.snippet.contains("[ed") == false)
        #expect(row?.snippet.contains("Quiz / Q1") == false)
        #expect(row?.snippet.contains("[image]") == false)

        // The same 280-character rule as Canvas rows, at a word boundary.
        let long = Self.edDocument(body: (0..<120).map { "word\($0)" }.joined(separator: " "))
        let longRow = AnnouncementRecord.edRecord(from: long, now: Self.now)
        #expect((longRow?.snippet.count ?? 0) <= AnnouncementRecord.snippetLimit)
        #expect((longRow?.snippet.count ?? 0) > AnnouncementRecord.snippetLimit - 12)
    }

    @Test("an Ed row takes its id, class, date, title and link from the document, and the link obeys the https rule")
    func edRowFields() throws {
        let document = Self.edDocument(thread: "88", daysAgo: 3, title: "  Midterm moved \n")
        let row = try #require(AnnouncementRecord.edRecord(from: document, now: Self.now))
        #expect(row.id == document.id)
        #expect(row.id == "ed:9301:88")
        #expect(row.isEd)
        #expect(row.courseID == "9301")
        #expect(row.courseCode == "ANED 9301")
        #expect(row.title == "Midterm moved")
        #expect(row.postedAt == document.updatedAt)
        #expect(row.url == document.url)
        #expect(row.safeWebURL == document.url)

        let insecure = try #require(AnnouncementRecord.edRecord(
            from: Self.edDocument(url: URL(string: "http://edstem.org/us/courses/1/discussion/2")), now: Self.now
        ))
        #expect(insecure.safeWebURL == nil)
        let noLink = try #require(AnnouncementRecord.edRecord(from: Self.edDocument(url: nil), now: Self.now))
        #expect(noLink.safeWebURL == nil)
    }

    @Test("a Canvas row is not an Ed row, whatever its id")
    func canvasRowIsNotEd() {
        let canvas = AnnouncementRecord(
            id: "4821", courseID: "1", courseCode: "X 1", title: "t", postedAt: Self.now,
            url: nil, snippet: "", recordedAt: Self.now
        )
        #expect(!canvas.isEd)
    }

    @Test("the same Ed document twice is one row, and rows come newest first")
    func edRecordsDeduplicateAndSort() {
        let older = Self.edDocument(thread: "1", daysAgo: 5)
        let newer = Self.edDocument(thread: "2", daysAgo: 1)
        let rows = AnnouncementRecord.edRecords(from: [older, newer, older], now: Self.now)
        #expect(rows.map(\.id) == [newer.id, older.id])
    }

    @Test("Canvas and Ed rows interleave by date, newest first, and a hidden class's rows of either kind are out")
    func interleaveAndHide() throws {
        func canvas(_ id: String, daysAgo: Double, course: String = "ANED 9301") -> AnnouncementRecord {
            AnnouncementRecord(
                id: id, courseID: "9301", courseCode: course, title: id,
                postedAt: Self.now.addingTimeInterval(-daysAgo * Self.day), url: nil, snippet: "", recordedAt: Self.now
            )
        }
        let ed1 = try #require(AnnouncementRecord.edRecord(from: Self.edDocument(thread: "1", daysAgo: 2), now: Self.now))
        let ed2 = try #require(AnnouncementRecord.edRecord(from: Self.edDocument(thread: "2", daysAgo: 0.5), now: Self.now))
        let hiddenEd = try #require(AnnouncementRecord.edRecord(
            from: Self.edDocument(thread: "3", course: "HIDE 1000", daysAgo: 0.1), now: Self.now
        ))
        let rows = [canvas("100", daysAgo: 3), canvas("101", daysAgo: 1), ed1, ed2, hiddenEd,
                    canvas("102", daysAgo: 0.2, course: "HIDE 1000")]

        let page = AppState.announcementRecordsForPage(rows) { $0 != "HIDE 1000" }
        #expect(page.map(\.id) == [ed2.id, "101", ed1.id, "100"])
    }

    // MARK: Seen-set keys

    @Test("an Ed row's seen key has its own prefix and can never equal a Canvas record key or an assignment id")
    func keysAreDistinct() throws {
        let ed = try #require(AnnouncementRecord.edRecord(from: Self.edDocument(thread: "9"), now: Self.now))
        let canvas = AnnouncementRecord(
            id: "9", courseID: "1", courseCode: "X 1", title: "t", postedAt: nil,
            url: nil, snippet: "", recordedAt: Self.now
        )
        let edKey = AnnouncementReadState.key(for: ed)
        let canvasKey = AnnouncementReadState.key(for: canvas)
        #expect(edKey == "ed-announcement:ed:9301:9")
        #expect(canvasKey == "announcement:9")
        #expect(edKey != canvasKey)
        #expect(AnnouncementReadState.isEdKey(edKey))
        #expect(!AnnouncementReadState.isRecordKey(edKey))
        #expect(!AnnouncementReadState.isEdKey(canvasKey))
        for source in [Assignment.Source.canvas, .gradescope, .manual, .canvasSuggestion, .canvasModules, .canvasAnnouncement] {
            let id = Assignment(source: source, sourceID: "9", kind: .assignment,
                                course: "X 1", title: "t", dueAt: nil, url: nil).id
            #expect(id != edKey)
            #expect(!AnnouncementReadState.isEdKey(id))
        }
    }

    @Test("unread, NEW ids and the badge count Ed rows through their own keys")
    func unreadCountsEdRows() throws {
        let ed1 = try #require(AnnouncementRecord.edRecord(from: Self.edDocument(thread: "1"), now: Self.now))
        let ed2 = try #require(AnnouncementRecord.edRecord(from: Self.edDocument(thread: "2"), now: Self.now))
        let seen: Set<String> = [AnnouncementReadState.key(for: ed1)]
        #expect(AnnouncementReadState.unreadCount(finds: [], records: [ed1, ed2], seen: seen) == 1)
        #expect(AnnouncementReadState.newIDs(finds: [], records: [ed1, ed2], seen: seen)
            == [AnnouncementReadState.key(for: ed2)])
        #expect(AnnouncementReadState.megaphoneVisible(finds: [], records: [ed1]))
    }

    // MARK: markAllSeen forgot ids of hidden classes

    @Test("markAllSeen keeps already-seen ids of rows still held but off the page, never newly marks them, and drops everything else")
    func markAllSeenKeepsKnownIDs() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let readState = AnnouncementReadState(defaults: defaults)
        func canvas(_ id: String) -> AnnouncementRecord {
            AnnouncementRecord(id: id, courseID: "1", courseCode: "X 1", title: id, postedAt: nil,
                               url: nil, snippet: "", recordedAt: Self.now)
        }
        let onPage = canvas("1")
        let hiddenSeen = canvas("2")      // its class is hidden, but it was read
        let hiddenUnseen = canvas("3")    // its class is hidden and it was never read
        let stale = AnnouncementReadState.recordKey("99")   // aged out of the log long ago

        readState.markSeen([AnnouncementReadState.key(for: hiddenSeen), stale])
        #expect(readState.seenIDs.contains(stale))

        let known = Set([onPage, hiddenSeen, hiddenUnseen].map(AnnouncementReadState.key(for:)))
        readState.markAllSeen([], records: [onPage], keeping: known)

        #expect(readState.seenIDs == [AnnouncementReadState.key(for: onPage), AnnouncementReadState.key(for: hiddenSeen)])
        #expect(!readState.seenIDs.contains(AnnouncementReadState.key(for: hiddenUnseen)))
        #expect(!readState.seenIDs.contains(stale))

        // Without `keeping` it is exactly the old behaviour: the page only.
        readState.markAllSeen([], records: [onPage])
        #expect(readState.seenIDs == [AnnouncementReadState.key(for: onPage)])
    }

    @Test("the Ed-seeded flag is its own, and forgetting the records clears it with the Ed and Canvas ids but keeps the finds")
    func edSeededFlag() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let readState = AnnouncementReadState(defaults: defaults)
        #expect(!readState.edSeeded)
        readState.markSeen(["canvasAnnouncement:announcement-1-0", "announcement:1", "ed-announcement:ed:1:1"])
        readState.markEdSeeded()
        #expect(readState.edSeeded)

        readState.forgetRecords()
        #expect(!readState.edSeeded)
        #expect(readState.seenIDs == ["canvasAnnouncement:announcement-1-0"])
    }

    // MARK: Sheet copy

    @Test("the sheet's words: an empty list says only \"no announcements\", a blank title reads \"untitled\", only Ed rows name their source, and the hint says where a tap goes")
    func sheetCopy() throws {
        #expect(AnnouncementSheetCopy.emptyState == "no announcements")
        #expect(!AnnouncementSheetCopy.emptyState.contains("60"))

        func canvas(title: String) -> AnnouncementRecord {
            AnnouncementRecord(id: "1", courseID: "1", courseCode: "X 1", title: title, postedAt: nil,
                               url: nil, snippet: "", recordedAt: Self.now)
        }
        #expect(AnnouncementSheetCopy.title(for: canvas(title: "")) == "untitled")
        #expect(AnnouncementSheetCopy.title(for: canvas(title: "  \n ")) == "untitled")
        #expect(AnnouncementSheetCopy.title(for: canvas(title: " Exam logistics ")) == "Exam logistics")

        let ed = try #require(AnnouncementRecord.edRecord(from: Self.edDocument(), now: Self.now))
        #expect(AnnouncementSheetCopy.sourceWord(for: ed) == "ed")
        #expect(AnnouncementSheetCopy.sourceWord(for: canvas(title: "t")) == nil)
        #expect(AnnouncementSheetCopy.linkHint(for: ed) == "opens the post in ed")
        #expect(AnnouncementSheetCopy.linkHint(for: canvas(title: "t")) == "opens the original announcement")
    }

    @Test("the sheet builds rows lazily, carries no \"open in canvas\" words, and keeps the preview to one line")
    func sheetSourceShape() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/AnnouncementFindsView.swift")
        // A prebuilt test bundle run away from the checkout has nothing to scan.
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains("LazyVStack"))
        #expect(!source.contains("SourceLink.canvasLabel"))
        #expect(!source.contains("open in canvas"))
        #expect(source.contains(".lineLimit(1)"))
    }

    // MARK: Posted-date label, cached

    @Test("the posted-date formatter is built once per locale and time zone and then reused, and different ones never share an answer")
    func postedFormatterIsCachedPerKey() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let us = Locale(identifier: "en_US")
        let gb = Locale(identifier: "en_GB")

        // 2026-10-03 23:30 UTC: already the 4th in Tokyo, still the 3rd in
        // Los Angeles. Far enough from `reference` to need the formatter.
        let posted = Date(timeIntervalSince1970: 1_791_070_200)
        let reference = posted.addingTimeInterval(30 * Self.day)
        func label(_ calendar: Calendar, _ locale: Locale) -> String? {
            AnnouncementRecord(id: "1", courseID: "1", courseCode: "X 1", title: "t", postedAt: posted,
                               url: nil, snippet: "", recordedAt: posted)
                .postedLabel(now: reference, calendar: calendar, locale: locale)
        }

        #expect(label(tokyo, us) == "oct 4")
        #expect(label(pacific, us) == "oct 3")
        #expect(label(pacific, gb) == "3 oct")

        // Reuse: after the first call there is a cached formatter, and a
        // hundred more calls leave the very same object in place.
        let first = AnnouncementRecord.postedFormatterIdentity(calendar: pacific, locale: us)
        #expect(first != nil)
        for _ in 0..<100 { _ = label(pacific, us) }
        #expect(AnnouncementRecord.postedFormatterIdentity(calendar: pacific, locale: us) == first)
        // And each key has its own formatter.
        let other = AnnouncementRecord.postedFormatterIdentity(calendar: tokyo, locale: us)
        #expect(other != nil && other != first)
        #expect(AnnouncementRecord.postedFormatterIdentity(calendar: pacific, locale: gb) != first)
    }
}

/// The same rules through an `AppState`: the list following the knowledge
/// base, Ed rows' seen state, the log file staying Canvas-only, and hidden
/// classes. Opted in to the announcement log with a temp directory and a
/// scratch defaults suite, as `AnnouncementLogSyncTests` does; under the test
/// runner an `AppState` that has not opted in lists nothing.
@MainActor
@Suite("Announcement list: Ed rows in an AppState", .serialized)
struct AnnouncementEdSyncTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let processedKey = "processedAnnouncementIDsV1"
    private static let extractionVersionKey = "announcementExtractionVersionV1"

    @MainActor
    private final class Harness {
        let state: AppState
        let directory: URL
        let scratch: UserDefaults
        var canvasResponse: [CanvasAnnouncement] = []

        init(state: AppState, directory: URL, scratch: UserDefaults) {
            self.state = state
            self.directory = directory
            self.scratch = scratch
        }

        var diskLog: [AnnouncementRecord]? { AnnouncementLogStore(directory: directory).loadIfPresent() }
        var seenOnDisk: Set<String> { AnnouncementReadState(defaults: scratch).seenIDs }
    }

    private static let courses: [(id: String, code: String)] = [("9301", "ANED 9301"), ("9302", "ANED 9302")]

    private func withHarness(
        optIn: Bool = true,
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let backup = [Self.processedKey, Self.extractionVersionKey].map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in backup {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: Self.extractionVersionKey)
        shared.removeObject(forKey: Self.processedKey)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("announcement-ed-sync-\(UUID().uuidString)", isDirectory: true)
        let scratchName = "announcement-ed-sync-\(UUID().uuidString)"
        let scratch = UserDefaults(suiteName: scratchName)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            scratch.removePersistentDomain(forName: scratchName)
        }

        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        state.forceFixtureDataForTesting(false)
        if optIn { state.enableAnnouncementLogForTesting(directory: directory, defaults: scratch) }
        state.canvasItems = Self.courses.map { course in
            Assignment(
                source: .canvas, sourceID: "seed-\(course.id)", kind: .assignment,
                course: course.code, title: "Seed \(course.code)", dueAt: nil,
                url: URL(string: "https://canvas.upenn.edu/courses/\(course.id)/assignments/1")
            )
        }
        for course in Self.courses { state.setCourse(course.code, selected: true) }
        defer {
            for course in Self.courses {
                state.restoreCourse(course.code)
                state.setCourse(course.code, selected: true)
                state.coursePreferences.setCanvasCourseID(course.code, nil)
            }
        }

        let harness = Harness(state: state, directory: directory, scratch: scratch)
        state.announcementFetchForTesting = { [harness] _, _, _ in harness.canvasResponse }
        state.announcementExtractorForTesting = { _ in NoTasks() }
        try await body(harness)
    }

    private struct NoTasks: AnnouncementAssignmentExtractor {
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] { [] }
    }

    private func ed(
        _ thread: String,
        course: (id: String, code: String) = AnnouncementEdSyncTests.courses[0],
        reason: String = "announcement",
        daysAgo: Double = 2
    ) -> CourseDocument {
        AnnouncementEdRowsTests.edDocument(
            thread: thread, courseID: course.id, course: course.code, reason: reason,
            body: "Body of \(thread).", daysAgo: daysAgo, title: "Post \(thread)", now: Date()
        )
    }

    private func knowledge(_ documents: [CourseDocument]) -> CourseKnowledgeBase {
        CourseKnowledgeBase(documents: documents)
    }

    private func canvasAnnouncement(_ id: String, daysAgo: Double, course: String = "9301") -> CanvasAnnouncement {
        CanvasAnnouncement(
            id: id, courseID: course, title: "Canvas \(id)", message: "Canvas body \(id).",
            postedAt: Date().addingTimeInterval(-daysAgo * Self.day),
            url: URL(string: "https://canvas.upenn.edu/courses/\(course)/discussion_topics/\(id)")
        )
    }

    // MARK: Refresh follows the knowledge base

    @Test("the list refreshes when the knowledge base gains, changes and loses an Ed document, with no sync involved")
    func listFollowsKnowledge() async throws {
        try await withHarness { h in
            #expect(h.state.announcementRecordsOnPage.isEmpty)
            #expect(!h.state.showsAnnouncementsButton)

            let first = ed("9200001")
            h.state.courseKnowledge = knowledge([first])
            #expect(h.state.announcementRecordsOnPage.map(\.id) == [first.id])
            #expect(h.state.announcementRecordsOnPage.first?.isEd == true)
            #expect(h.state.showsAnnouncementsButton)

            // A second Ed post and a plain staff post: only the first lands.
            let second = ed("9200002", daysAgo: 0.5)
            let staff = ed("9200003", reason: "staff post")
            h.state.courseKnowledge = knowledge([first, second, staff])
            #expect(h.state.announcementRecordsOnPage.map(\.id) == [second.id, first.id])

            h.state.courseKnowledge = .empty
            #expect(h.state.announcementRecordsOnPage.isEmpty)
            #expect(!h.state.showsAnnouncementsButton)
        }
    }

    @Test("an AppState that has not opted in to the announcement log lists no Ed rows either")
    func noOptInNoEdRows() async throws {
        try await withHarness(optIn: false) { h in
            h.state.courseKnowledge = knowledge([ed("9200010")])
            #expect(h.state.announcementRecordsOnPage.isEmpty)
            #expect(!h.state.showsAnnouncementsButton)
        }
    }

    // MARK: Classes

    @Test("a hidden or deleted class's Ed rows leave the list and return with the class")
    func hiddenClassEdRowsAreOut() async throws {
        try await withHarness { h in
            let a = ed("9200020", course: Self.courses[0])
            let b = ed("9200021", course: Self.courses[1], daysAgo: 1)
            h.state.courseKnowledge = knowledge([a, b])
            #expect(h.state.announcementRecordsOnPage.map(\.id) == [b.id, a.id])

            h.state.setCourse("ANED 9302", selected: false)
            #expect(h.state.announcementRecordsOnPage.map(\.id) == [a.id])

            h.state.deleteCourse("ANED 9301")
            #expect(h.state.announcementRecordsOnPage.isEmpty)

            h.state.restoreCourse("ANED 9301")
            h.state.setCourse("ANED 9302", selected: true)
            #expect(h.state.announcementRecordsOnPage.map(\.id) == [b.id, a.id])
        }
    }

    // MARK: Interleaving and the file

    @Test("Canvas and Ed rows interleave by date, and the log file holds the Canvas rows only")
    func interleaveAndFileStaysCanvasOnly() async throws {
        try await withHarness { h in
            let edNew = ed("9200030", daysAgo: 0.5)
            let edOld = ed("9200031", daysAgo: 2)
            h.state.courseKnowledge = knowledge([edNew, edOld])

            h.canvasResponse = [canvasAnnouncement("9100301", daysAgo: 3), canvasAnnouncement("9100302", daysAgo: 1)]
            await h.state.syncAnnouncements()

            #expect(h.state.announcementRecordsOnPage.map(\.id) == [edNew.id, "9100302", edOld.id, "9100301"])

            // On disk: Canvas only. Checked as records and as raw bytes.
            #expect(Set(h.diskLog?.map(\.id) ?? []) == ["9100301", "9100302"])
            let raw = try String(contentsOf: AnnouncementLogStore(directory: h.directory).fileURL, encoding: .utf8)
            #expect(!raw.contains("ed:9301"))
            #expect(!raw.contains("[ed"))
            #expect(!raw.contains("edstem.org"))
            #expect(!raw.contains("Post 9200030"))
        }
    }

    // MARK: Seen state

    @Test("the first Ed rows an install sees count as seen; one that arrives later is unread; opening the sheet marks it seen")
    func edFirstMergeIsSeen() async throws {
        try await withHarness { h in
            let a = ed("9200040"), b = ed("9200041", daysAgo: 1)
            h.state.courseKnowledge = knowledge([a, b])
            #expect(h.state.announcementRecordsOnPage.count == 2)
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(AnnouncementReadState(defaults: h.scratch).edSeeded)
            #expect(h.seenOnDisk.isSuperset(of: [AnnouncementReadState.edKey(a.id), AnnouncementReadState.edKey(b.id)]))

            let c = ed("9200042", daysAgo: 0.1)
            h.state.courseKnowledge = knowledge([a, b, c])
            #expect(h.state.unreadAnnouncementCount == 1)

            let newIDs = h.state.openAnnouncementsSheet()
            #expect(newIDs == [AnnouncementReadState.edKey(c.id)])
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(h.seenOnDisk.contains(AnnouncementReadState.edKey(c.id)))
        }
    }

    @Test("an install that already filled its Canvas log still gets the Ed first-merge once, and Canvas and Ed badges add")
    func edSeededSeparatelyFromCanvasFirstFill() async throws {
        try await withHarness { h in
            // Canvas fills first: its two rows are seen, the Ed seed has not happened.
            h.canvasResponse = [canvasAnnouncement("9100401", daysAgo: 2), canvasAnnouncement("9100402", daysAgo: 1)]
            await h.state.syncAnnouncements()
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(!AnnouncementReadState(defaults: h.scratch).edSeeded)

            // Ed rows then appear for the first time: seen, no jump.
            h.state.courseKnowledge = knowledge([ed("9200050"), ed("9200051", daysAgo: 1)])
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(AnnouncementReadState(defaults: h.scratch).edSeeded)

            // One new of each kind afterwards: the badge adds them.
            h.canvasResponse += [canvasAnnouncement("9100403", daysAgo: 0.1)]
            await h.state.syncAnnouncements(now: Date().addingTimeInterval(300))
            h.state.courseKnowledge = knowledge([ed("9200050"), ed("9200051", daysAgo: 1), ed("9200052", daysAgo: 0.1)])
            #expect(h.state.unreadAnnouncementCount == 2)
        }
    }

    @Test("clearing the log keeps Ed rows listed and does not turn them all unread")
    func clearKeepsEdSeen() async throws {
        try await withHarness { h in
            h.state.courseKnowledge = knowledge([ed("9200060"), ed("9200061", daysAgo: 1)])
            #expect(h.state.unreadAnnouncementCount == 0)

            h.state.clearAnnouncementLog()
            #expect(h.state.announcementRecordsOnPage.count == 2)
            #expect(h.state.unreadAnnouncementCount == 0)
            #expect(AnnouncementReadState(defaults: h.scratch).edSeeded)
        }
    }

    // MARK: markAllSeen forgot ids of hidden classes

    @Test("hiding a class, opening the sheet and showing it again does not re-badge its old posts; a post that arrived while it was hidden still does")
    func hidingAClassDoesNotRebadge() async throws {
        try await withHarness { h in
            // Class 9301 has a Canvas post and an Ed post, both read.
            h.canvasResponse = [canvasAnnouncement("9100501", daysAgo: 2, course: "9301")]
            await h.state.syncAnnouncements()
            let edOld = ed("9200070", course: Self.courses[0])
            h.state.courseKnowledge = knowledge([edOld])
            #expect(h.state.unreadAnnouncementCount == 0)
            _ = h.state.openAnnouncementsSheet()
            let readBefore: Set<String> = [
                AnnouncementReadState.recordKey("9100501"), AnnouncementReadState.edKey(edOld.id),
            ]
            #expect(h.seenOnDisk.isSuperset(of: readBefore))

            // Hide the class and open the sheet: its rows are off the page.
            h.state.setCourse("ANED 9301", selected: false)
            #expect(h.state.announcementRecordsOnPage.isEmpty)
            // A new Ed post for the hidden class arrives meanwhile.
            let edNew = ed("9200071", course: Self.courses[0], daysAgo: 0.1)
            h.state.courseKnowledge = knowledge([edOld, edNew])
            _ = h.state.openAnnouncementsSheet()

            // Already-read ids survived the sheet opening without their class.
            #expect(h.seenOnDisk.isSuperset(of: readBefore))
            // The unread one was not marked read just because the sheet opened.
            #expect(!h.seenOnDisk.contains(AnnouncementReadState.edKey(edNew.id)))

            // Show the class again: only the new post is unread.
            h.state.setCourse("ANED 9301", selected: true)
            #expect(h.state.announcementRecordsOnPage.count == 3)
            #expect(h.state.unreadAnnouncementCount == 1)
            #expect(h.state.openAnnouncementsSheet() == [AnnouncementReadState.edKey(edNew.id)])
        }
    }

    @Test("the stored seen set stays bounded: an Ed post that leaves the phone has its id dropped at the next open")
    func seenSetStaysBounded() async throws {
        try await withHarness { h in
            let gone = ed("9200080"), kept = ed("9200081", daysAgo: 1)
            h.state.courseKnowledge = knowledge([gone, kept])
            _ = h.state.openAnnouncementsSheet()
            #expect(h.seenOnDisk.contains(AnnouncementReadState.edKey(gone.id)))

            h.state.courseKnowledge = knowledge([kept])
            _ = h.state.openAnnouncementsSheet()
            #expect(!h.seenOnDisk.contains(AnnouncementReadState.edKey(gone.id)))
            #expect(h.seenOnDisk.contains(AnnouncementReadState.edKey(kept.id)))
        }
    }
}
