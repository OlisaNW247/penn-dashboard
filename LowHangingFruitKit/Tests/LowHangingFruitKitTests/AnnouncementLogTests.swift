import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The pure half of the megaphone's "all announcements" list: the record and
/// its snippet, the on-disk store and its retention rules, the date label, the
/// join with the extractor's finds, and the unread/visibility rules. Nothing
/// here touches the shared `UserDefaults` domain or the real Application
/// Support directory: stores live in a per-test temp directory and read state
/// in a scratch suite (CLAUDE.md's shared-defaults trap).
@Suite("Announcement log: records, store, rules")
struct AnnouncementLogTests {
    private static let day: TimeInterval = 24 * 60 * 60
    /// A whole-second instant, since the store's date encoding is exact for
    /// whole seconds and the tests compare records for equality.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("announcement-log-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func record(
        _ id: String,
        daysAgo: Double? = 1,
        course: String = "CIS 1200",
        title: String = "Title",
        url: URL? = URL(string: "https://canvas.upenn.edu/courses/1/discussion_topics/1"),
        snippet: String = "snippet",
        recordedAt: Date? = nil
    ) -> AnnouncementRecord {
        AnnouncementRecord(
            id: id,
            courseID: "1",
            courseCode: course,
            title: title,
            postedAt: daysAgo.map { Self.now.addingTimeInterval(-$0 * Self.day) },
            url: url,
            snippet: snippet,
            recordedAt: recordedAt ?? Self.now
        )
    }

    // MARK: Store

    @Test("a saved log reads back identically, and an empty save still counts as filled")
    func storeRoundTrip() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnouncementLogStore(directory: directory)
        #expect(store.loadIfPresent(now: Self.now) == nil)

        let records = [record("2", daysAgo: 1), record("1", daysAgo: 3)]
        try store.save(records, now: Self.now)
        #expect(store.loadIfPresent(now: Self.now) == records)
        #expect(store.load(now: Self.now) == records)

        // The file's existence is the "filled once" flag, so an empty list is
        // written, not skipped.
        try store.save([], now: Self.now)
        #expect(store.loadIfPresent(now: Self.now) == [])

        store.clear()
        #expect(store.loadIfPresent(now: Self.now) == nil)
    }

    @Test("the log file sits beside the course-knowledge file")
    func fileSitsBesideCourseKnowledge() {
        let directory = tempDirectory()
        #expect(CourseKnowledgeStore(directory: directory).fileURL.deletingLastPathComponent()
            == AnnouncementLogStore(directory: directory).fileURL.deletingLastPathComponent())
        #expect(AnnouncementLogStore.default().fileURL.deletingLastPathComponent()
            == CourseKnowledgeStore.default().fileURL.deletingLastPathComponent())
    }

    @Test("saving drops records older than 60 days and loading prunes against its own clock")
    func sixtyDayPrune() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnouncementLogStore(directory: directory)

        let kept = try store.save(
            [record("fresh", daysAgo: 59), record("stale", daysAgo: 61)],
            now: Self.now
        )
        #expect(kept.map(\.id) == ["fresh"])
        #expect(store.load(now: Self.now).map(\.id) == ["fresh"])

        // 59 days old when saved, 62 when read: gone without another save.
        #expect(store.load(now: Self.now.addingTimeInterval(3 * Self.day)).isEmpty)
    }

    @Test("saving keeps at most 300 records, newest first")
    func threeHundredCap() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnouncementLogStore(directory: directory)

        // 305 records, one per hour back from now, all inside 60 days.
        let records = (0..<305).map { index -> AnnouncementRecord in
            AnnouncementRecord(
                id: String(index),
                courseID: "1", courseCode: "CIS 1200", title: "t",
                postedAt: Self.now.addingTimeInterval(-Double(index) * 3_600),
                url: nil, snippet: "", recordedAt: Self.now
            )
        }
        try store.save(records.shuffled(), now: Self.now)
        let loaded = store.load(now: Self.now)
        #expect(loaded.count == AnnouncementLogStore.maxRecords)
        #expect(loaded.first?.id == "0")
        #expect(loaded.last?.id == "299")
        #expect(!loaded.contains { $0.id == "304" })
    }

    @Test("a damaged or foreign file reads as nothing, never a crash")
    func damagedFileIsTolerated() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnouncementLogStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for garbage in ["not json at all", "{\"version\":1,\"records\":[{\"id\":", "[1,2,3]", "{}", ""] {
            try Data(garbage.utf8).write(to: store.fileURL)
            #expect(store.loadIfPresent(now: Self.now) == nil, "\(garbage)")
            #expect(store.load(now: Self.now).isEmpty, "\(garbage)")
        }

        // And a save over the damage works.
        try store.save([record("1")], now: Self.now)
        #expect(store.load(now: Self.now).map(\.id) == ["1"])
    }

    @Test("merging replaces a re-fetched record's text but keeps when it was first logged")
    func mergeKeepsFirstSeen() {
        let first = Self.now.addingTimeInterval(-5 * Self.day)
        let existing = [record("7", title: "old title", snippet: "old", recordedAt: first)]
        let incoming = [record("7", title: "edited", snippet: "new", recordedAt: Self.now),
                        record("8", recordedAt: Self.now)]
        let merged = AnnouncementLogStore.merged(existing: existing, incoming: incoming, now: Self.now)
        #expect(merged.count == 2)
        let seven = merged.first { $0.id == "7" }
        #expect(seven?.title == "edited")
        #expect(seven?.snippet == "new")
        #expect(seven?.recordedAt == first)
    }

    @Test("an undated record is aged and sorted by when it was first logged")
    func undatedRecordUsesRecordedAt() {
        let old = record("old", daysAgo: nil, recordedAt: Self.now.addingTimeInterval(-61 * Self.day))
        let recent = record("recent", daysAgo: nil, recordedAt: Self.now.addingTimeInterval(-1 * Self.day))
        let dated = record("dated", daysAgo: 2)
        let pruned = AnnouncementLogStore.pruned([old, dated, recent], now: Self.now)
        #expect(pruned.map(\.id) == ["recent", "dated"])
    }

    @Test("newest first, with the numeric id as the tiebreak")
    func ordering() {
        let a = record("9", daysAgo: 2)
        let b = record("10", daysAgo: 2)
        let c = record("3", daysAgo: 1)
        let sorted = [a, b, c].sorted(by: AnnouncementRecord.isNewer(_:than:))
        #expect(sorted.map(\.id) == ["3", "10", "9"])
    }

    // MARK: Snippet

    @Test("snippet strips tags and a multi-line style block, decodes entities, and collapses whitespace")
    func snippetStripsHTML() {
        let html = """
        <style type="text/css">
        p.MsoNormal { margin: 0in;
          font-size: 11pt; }
        </style>
        <p>Hello&nbsp;class,</p>
        <p>The   midterm is <strong>Friday</strong> &amp; covers weeks 1&ndash;4.</p>
        <script>alert(1)</script>
        """
        let snippet = AnnouncementRecord.snippet(fromHTML: html)
        #expect(snippet == "Hello class, The midterm is Friday & covers weeks 1–4.")
        #expect(!snippet.contains("MsoNormal"))
        #expect(!snippet.contains("alert"))
        #expect(!snippet.contains("\n"))
    }

    @Test("snippet over 280 characters is cut at a word boundary, never mid-word")
    func snippetCutsAtWordBoundary() {
        let words = (0..<120).map { "word\($0)" }
        let text = words.joined(separator: " ")
        let snippet = AnnouncementRecord.snippet(fromHTML: "<p>\(text)</p>")
        #expect(snippet.count <= AnnouncementRecord.snippetLimit)
        #expect(snippet.count > AnnouncementRecord.snippetLimit - 12)
        #expect(text.hasPrefix(snippet))
        // Ends on a whole word: the next character of the source is a space.
        let next = text[text.index(text.startIndex, offsetBy: snippet.count)]
        #expect(next == " ")
        #expect(!snippet.hasSuffix(" "))
    }

    @Test("snippet exactly at the limit is left whole, and a single huge word is hard-cut rather than emptied")
    func snippetLimitEdges() {
        let exact = String(repeating: "a", count: 140) + " " + String(repeating: "b", count: 139)
        #expect(exact.count == 280)
        #expect(AnnouncementRecord.snippet(fromHTML: exact) == exact)

        let url = "https://example.com/" + String(repeating: "x", count: 400)
        let snippet = AnnouncementRecord.snippet(fromHTML: url)
        #expect(snippet.count == AnnouncementRecord.snippetLimit)
        #expect(url.hasPrefix(snippet))

        // The limit landing exactly on a space keeps the whole words before it.
        let head = String(repeating: "a", count: 100) + " " + String(repeating: "b", count: 179)
        #expect(head.count == 280)
        #expect(AnnouncementRecord.snippet(fromHTML: head + " tail") == head)
    }

    @Test("an empty or markup-only message gives an empty snippet")
    func snippetEmpty() {
        #expect(AnnouncementRecord.snippet(fromHTML: "") == "")
        #expect(AnnouncementRecord.snippet(fromHTML: "   \n\t ") == "")
        #expect(AnnouncementRecord.snippet(fromHTML: "<p></p><br/><style>x{}</style>") == "")
    }

    @Test("a record built from a fetched announcement carries the course code, a trimmed title and a snippet, and nothing else of the body")
    func recordFromAnnouncement() {
        let announcement = CanvasAnnouncement(
            id: "55", courseID: "1010", title: "  Exam logistics \n",
            message: String(repeating: "long body text ", count: 100),
            postedAt: Self.now, url: URL(string: "https://canvas.upenn.edu/courses/1010/discussion_topics/55")
        )
        let built = AnnouncementRecord(announcement: announcement, courseCode: "CIS 1010", recordedAt: Self.now)
        #expect(built.id == "55")
        #expect(built.courseID == "1010")
        #expect(built.courseCode == "CIS 1010")
        #expect(built.title == "Exam logistics")
        #expect(built.snippet.count <= AnnouncementRecord.snippetLimit)
        #expect(built.postedAt == Self.now)
    }

    // MARK: Date label

    @Test("posted label reads today, yesterday, then a short lowercase date, and nothing when undated")
    func postedLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        // 2026-10-09 15:00 UTC.
        let reference = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 15))!

        func label(_ date: Date?) -> String? {
            AnnouncementRecord(
                id: "1", courseID: "1", courseCode: "X 1", title: "t", postedAt: date,
                url: nil, snippet: "", recordedAt: reference
            ).postedLabel(now: reference, calendar: calendar, locale: locale)
        }

        #expect(label(calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 0, minute: 5))) == "today")
        #expect(label(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 23, minute: 59))) == "yesterday")
        #expect(label(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12))) == "oct 3")
        #expect(label(calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 12))) == "sep 21")
        #expect(label(nil) == nil)
    }

    // MARK: Link

    @Test("only an https URL with a host is offered as a link")
    func safeWebURL() {
        func link(_ string: String?) -> URL? {
            record("1", url: string.flatMap { URL(string: $0) }).safeWebURL
        }
        #expect(link("https://canvas.upenn.edu/courses/1/discussion_topics/2") != nil)
        #expect(link("HTTPS://canvas.upenn.edu/x") != nil)
        #expect(link("http://canvas.upenn.edu/x") == nil)
        #expect(link("javascript:alert(1)") == nil)
        #expect(link("file:///etc/passwd") == nil)
        #expect(link("/courses/1/discussion_topics/2") == nil)
        #expect(link("https:///nohost") == nil)
        #expect(link(nil) == nil)
    }

    // MARK: Join with finds

    @Test("a find's sourceID names the announcement it came from, round-tripping what the ledger writes")
    @MainActor
    func findJoin() {
        let announcement = CanvasAnnouncement(
            id: "4821", courseID: "1", title: "t", message: "m", postedAt: nil, url: nil
        )
        let found = AppState.announcementAssignments(
            from: [
                ExtractedAssignment(title: "A", dueAt: nil, kind: .submission),
                ExtractedAssignment(title: "B", dueAt: nil, kind: .preparation),
            ],
            announcement: announcement,
            courseCode: "CIS 1200"
        )
        #expect(found.map(\.sourceID) == ["announcement-4821-0", "announcement-4821-1"])
        for item in found {
            #expect(AnnouncementRecord.announcementID(fromFindSourceID: item.sourceID) == "4821")
        }
        #expect(AnnouncementRecord.findSourceID(announcementID: "4821", index: 3) == "announcement-4821-3")

        #expect(AnnouncementRecord.announcementID(fromFindSourceID: "announcement-4821") == nil)
        #expect(AnnouncementRecord.announcementID(fromFindSourceID: "announcement--0") == nil)
        #expect(AnnouncementRecord.announcementID(fromFindSourceID: "announcement-12-x") == nil)
        #expect(AnnouncementRecord.announcementID(fromFindSourceID: "hw-12-0") == nil)
    }

    // MARK: Read state and megaphone rules

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "announcement-log-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func find(_ sourceID: String) -> Assignment {
        Assignment(source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment,
                   course: "CIS 1200", title: sourceID, dueAt: nil, url: nil)
    }

    @Test("a record's stored id can never equal an assignment's")
    func recordKeysDoNotCollide() {
        let key = AnnouncementReadState.recordKey("42")
        #expect(key == "announcement:42")
        #expect(AnnouncementReadState.isRecordKey(key))
        for source in [Assignment.Source.canvas, .gradescope, .manual, .canvasSuggestion, .canvasModules, .canvasAnnouncement] {
            let id = Assignment(source: source, sourceID: "42", kind: .assignment,
                                course: "X 1", title: "t", dueAt: nil, url: nil).id
            #expect(id != key)
            #expect(!AnnouncementReadState.isRecordKey(id))
        }
    }

    @Test("the badge adds unread finds and unread records; the megaphone shows for either")
    func badgeAndMegaphoneRule() {
        let finds = [find("announcement-1-0"), find("announcement-2-0")]
        let records = [record("1"), record("2"), record("3")]

        #expect(!AnnouncementReadState.megaphoneVisible(finds: [], records: []))
        #expect(AnnouncementReadState.megaphoneVisible(finds: finds, records: []))
        #expect(AnnouncementReadState.megaphoneVisible(finds: [], records: records))
        #expect(AnnouncementReadState.megaphoneVisible(finds: finds, records: records))

        #expect(AnnouncementReadState.unreadCount(finds: [], records: [], seen: []) == 0)
        #expect(AnnouncementReadState.unreadCount(finds: finds, records: [], seen: []) == 2)
        #expect(AnnouncementReadState.unreadCount(finds: [], records: records, seen: []) == 3)
        #expect(AnnouncementReadState.unreadCount(finds: finds, records: records, seen: []) == 5)

        let seen: Set<String> = [finds[0].id, AnnouncementReadState.recordKey("2")]
        #expect(AnnouncementReadState.unreadCount(finds: finds, records: records, seen: seen) == 3)
        #expect(AnnouncementReadState.newIDs(finds: finds, records: records, seen: seen)
            == [finds[1].id, AnnouncementReadState.recordKey("1"), AnnouncementReadState.recordKey("3")])
    }

    @Test("marking seen stores both kinds of id under the one key and keeps only what is on the page")
    func markAllSeenBothKinds() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let readState = AnnouncementReadState(defaults: defaults)
        let finds = [find("announcement-1-0")]

        readState.markAllSeen(finds, records: [record("1"), record("2")])
        #expect(readState.seenIDs == [finds[0].id, "announcement:1", "announcement:2"])

        // Record 1 drops off the page: its id goes with it.
        readState.markAllSeen(finds, records: [record("2")])
        #expect(readState.seenIDs == [finds[0].id, "announcement:2"])

        // markSeen adds without disturbing, and still honours the page bound.
        readState.markSeen(["announcement:9", "announcement:99"], keepingOnly: [finds[0].id, "announcement:2", "announcement:9"])
        #expect(readState.seenIDs == [finds[0].id, "announcement:2", "announcement:9"])

        readState.forgetRecords()
        #expect(readState.seenIDs == [finds[0].id])
    }

    @Test("a class rename applies to a record's label, and an empty code reads Misc")
    func recordCourseLabel() {
        let r = record("1", course: "PHYS 0151")
        #expect(r.displayCourse(overrides: [:]) == "PHYS 0151")
        #expect(r.displayCourse(overrides: ["PHYS 0151": "  physics  "]) == "physics")
        #expect(r.displayCourse(overrides: ["PHYS 0151": "   "]) == "PHYS 0151")
        #expect(record("2", course: " ").displayCourse(overrides: [:]) == "Misc")
    }

    @Test("records of a hidden or deleted class are not listed, and the rest come newest first")
    func pageRecordsFollowClassSelection() {
        let records = [
            record("1", daysAgo: 5, course: "CIS 1200"),
            record("2", daysAgo: 1, course: "HIDE 1000"),
            record("3", daysAgo: 2, course: "CIS 1200"),
            record("4", daysAgo: 3, course: "GONE 2000"),
            record("5", daysAgo: 0.5, course: "MATH 1400"),
        ]
        let page = AppState.announcementRecordsForPage(records) { !["HIDE 1000", "GONE 2000"].contains($0) }
        #expect(page.map(\.id) == ["5", "3", "1"])
    }
}
