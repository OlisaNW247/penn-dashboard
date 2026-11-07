import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The announcement keep-check, in four pure parts: what the server's
/// `relevance` decodes to (and that a bad one never costs the tasks beside
/// it), the extractor seam that carries it out, the on-phone store that keeps
/// it, and the rule that decides which posts the megaphone sheet lists.
///
/// Nothing here touches shared state: the wire and rule tests are pure, and the
/// store tests use a scratch `UserDefaults` suite. The same rules through an
/// `AppState` are in `AnnouncementRelevanceSyncTests`.

// MARK: - Wire

@Suite("Announcement relevance: what the server's answer decodes to")
struct AnnouncementRelevanceWireTests {
    /// 2026-10-31T03:59:00Z.
    private static let untilInstant = Date(timeIntervalSince1970: 1_793_419_140)

    private func decode(_ json: String) throws -> ExtractAnnouncementResponse {
        try BackendJSON.decoder().decode(ExtractAnnouncementResponse.self, from: Data(json.utf8))
    }

    private let task = #"{"title":"Lab 4","dueAt":"2026-10-30T20:00:00Z","kind":"submission"}"#

    @Test("each of the four kinds decodes, with its until")
    func eachKindDecodes() throws {
        for kind in AnnouncementRelevance.Kind.allCases {
            let response = try decode(
                #"{"assignments":[\#(task)],"relevance":{"kind":"\#(kind.rawValue)","until":"2026-10-31T03:59:00Z"}}"#
            )
            #expect(response.relevance == AnnouncementRelevance(kind: kind, until: Self.untilInstant), "\(kind)")
            #expect(response.assignments.map(\.title) == ["Lab 4"], "\(kind)")
        }
    }

    @Test("until reads with a Z, with a numeric offset, and with fractional seconds")
    func untilFormats() throws {
        let cases: [(String, Date)] = [
            ("2026-10-31T03:59:00Z", Self.untilInstant),
            ("2026-10-30T23:59:00-04:00", Self.untilInstant),
            ("2026-10-31T05:59:00+02:00", Self.untilInstant),
            ("2026-10-31T03:59:00.500Z", Self.untilInstant.addingTimeInterval(0.5)),
            ("2026-10-30T23:59:00.500-04:00", Self.untilInstant.addingTimeInterval(0.5)),
        ]
        for (raw, expected) in cases {
            let response = try decode(#"{"assignments":[],"relevance":{"kind":"event","until":"\#(raw)"}}"#)
            #expect(response.relevance?.until == expected, "\(raw)")
        }
    }

    @Test("standing and news decode with no until")
    func kindsWithoutUntil() throws {
        let standing = try decode(#"{"assignments":[],"relevance":{"kind":"standing"}}"#)
        let news = try decode(#"{"assignments":[],"relevance":{"kind":"news"}}"#)
        #expect(standing.relevance == AnnouncementRelevance(kind: .standing, until: nil))
        #expect(news.relevance == AnnouncementRelevance(kind: .news, until: nil))
    }

    @Test("an unknown kind is no relevance, and the tasks are untouched")
    func unknownKind() throws {
        for kind in ["deadline", "EVENT", "Event", "", "events"] {
            let response = try decode(
                #"{"assignments":[\#(task)],"relevance":{"kind":"\#(kind)","until":"2026-10-31T03:59:00Z"}}"#
            )
            #expect(response.relevance == nil, "kind \"\(kind)\"")
            #expect(response.assignments.map(\.title) == ["Lab 4"], "kind \"\(kind)\"")
        }
    }

    @Test("a kind that is not a string, or missing, is no relevance")
    func kindOfTheWrongType() throws {
        for relevance in [#"{"kind":3}"#, #"{"kind":["event"]}"#, #"{"kind":null}"#, #"{"until":"2026-10-31T03:59:00Z"}"#, "{}"] {
            let response = try decode(#"{"assignments":[\#(task)],"relevance":\#(relevance)}"#)
            #expect(response.relevance == nil, "\(relevance)")
            #expect(response.assignments.count == 1, "\(relevance)")
        }
    }

    @Test("an until that cannot be read is dropped and the kind survives")
    func badUntil() throws {
        let unreadable = [
            #""next Friday""#,
            #""2026-10-30T23:59:00""#,       // a date-time with no offset: a different instant on every phone
            #""2026-10-26T14:00:00""#,
            #""2026-10-26T14:00:00.250""#,
            #""2026-10-26 14:00""#,
            #""2026-02-31""#,                // a day that does not exist
            #""2026-13-01""#,
            #""2026-1-5""#,                  // not the shape of a date
            #""20261026""#,
            #""2026/10/26""#,
            #"" 2026-10-26""#,
            #""2026-10-26 ""#,
            #""Oct 26""#,
            #""soon""#,
            #""""#,
            "42",
            #"["2026-10-31T03:59:00Z"]"#,
            "null",
            "{}",
        ]
        for until in unreadable {
            let response = try decode(
                #"{"assignments":[\#(task)],"relevance":{"kind":"event","until":\#(until)}}"#
            )
            #expect(response.relevance == AnnouncementRelevance(kind: .event, until: nil), "until \(until)")
            #expect(response.assignments.map(\.title) == ["Lab 4"], "until \(until)")
        }
    }

    @Test("a bare date is the end of that day in the given zone, to the second")
    func bareDateIsEndOfDay() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        // 2026-10-26 23:59:59 EDT (UTC-4) = 2026-10-27T03:59:59Z.
        #expect(AnnouncementRelevance(wireKind: "event", wireUntil: "2026-10-26", timeZone: newYork)?.until
            == Date(timeIntervalSince1970: 1_793_073_599))
        // 23:59:59 UTC is 2026-10-26T23:59:59Z.
        #expect(AnnouncementRelevance(wireKind: "event", wireUntil: "2026-10-26", timeZone: .gmt)?.until
            == Date(timeIntervalSince1970: 1_793_059_199))
        // The same date is an earlier instant the further east the phone is.
        #expect(AnnouncementRelevance(wireKind: "event", wireUntil: "2026-10-26", timeZone: tokyo)?.until
            == Date(timeIntervalSince1970: 1_793_059_199 - 9 * 3600))
        // The day after daylight saving ends in New York: 23:59:59 EST (UTC-5).
        #expect(AnnouncementRelevance(wireKind: "task", wireUntil: "2026-11-01", timeZone: newYork)?.until
            == Date(timeIntervalSince1970: 1_793_595_599))
        // A leap day is a day.
        #expect(AnnouncementRelevance(wireKind: "event", wireUntil: "2028-02-29", timeZone: .gmt)?.until
            == Date(timeIntervalSince1970: 1_835_481_599))
    }

    @Test("a bare date read off the wire is the end of that day on this phone")
    func bareDateOffTheWire() throws {
        let response = try decode(#"{"assignments":[\#(task)],"relevance":{"kind":"event","until":"2026-10-26"}}"#)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 59, second: 59)))
        #expect(response.relevance == AnnouncementRelevance(kind: .event, until: expected))
        #expect(response.assignments.map(\.title) == ["Lab 4"])
    }

    @Test("a date-time with no offset keeps the kind and drops the until, where a bare date keeps it")
    func offsetlessDateTimeIsDroppedButBareDateIsNot() {
        #expect(AnnouncementRelevance(wireKind: "event", wireUntil: "2026-10-26T14:00:00", timeZone: .gmt)
            == AnnouncementRelevance(kind: .event, until: nil))
        #expect(AnnouncementRelevance(wireKind: "event", wireUntil: "2026-10-26", timeZone: .gmt)?.until != nil)
        // With an offset it is that instant, whatever zone the phone is in.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(AnnouncementRelevance(wireKind: "event", wireUntil: "2026-10-26T14:00:00Z", timeZone: tokyo)?.until
            == Date(timeIntervalSince1970: 1_793_023_200))
    }

    @Test("a relevance that is not an object is dropped without failing the response or the tasks")
    func malformedRelevance() throws {
        for relevance in [#""event""#, "42", "true", "null", #"["event"]"#, "[]"] {
            let response = try decode(#"{"assignments":[\#(task)],"relevance":\#(relevance)}"#)
            #expect(response.relevance == nil, "\(relevance)")
            #expect(response.assignments.map(\.title) == ["Lab 4"], "\(relevance)")
        }
    }

    @Test("a response with no relevance key decodes as before, with none")
    func absent() throws {
        let response = try decode(#"{"assignments":[\#(task)]}"#)
        #expect(response.relevance == nil)
        #expect(response.assignments.map(\.title) == ["Lab 4"])
        let empty = try decode(#"{"assignments":[]}"#)
        #expect(empty.relevance == nil && empty.assignments.isEmpty)
    }

    @Test("assignments are still required: a relevance does not stand in for them")
    func assignmentsStillRequired() {
        #expect(throws: (any Error).self) {
            try decode(#"{"relevance":{"kind":"news"}}"#)
        }
    }

    @Test("the extraction the sync consumes carries the tasks (kind resolved) and the relevance")
    func extractionFromResponse() throws {
        let response = try decode(
            #"{"assignments":[{"title":"Bring a calculator","kind":"preparation"},{"title":"Lab 4","dueAt":"2026-10-30T20:00:00Z"}],"relevance":{"kind":"task","until":"2026-10-31T03:59:00Z"}}"#
        )
        let extraction = AnnouncementExtraction(response: response)
        #expect(extraction.assignments.map(\.title) == ["Bring a calculator", "Lab 4"])
        #expect(extraction.assignments.map(\.kind) == [.preparation, .submission])
        #expect(extraction.assignments[1].dueAt == Date(timeIntervalSince1970: 1_793_390_400))
        #expect(extraction.relevance == AnnouncementRelevance(kind: .task, until: Self.untilInstant))
    }

    @Test("a relevance survives a round trip through its own Codable form")
    func codableRoundTrip() throws {
        let original = [
            AnnouncementRelevance(kind: .event, until: Self.untilInstant.addingTimeInterval(0.25)),
            AnnouncementRelevance(kind: .news),
        ]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([AnnouncementRelevance].self, from: data) == original)
    }
}

// MARK: - Extractor seam

@Suite("Announcement relevance: the extractor seam")
struct AnnouncementRelevanceExtractorSeamTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let source = AnnouncementSourceText(
        announcementID: "1", courseCode: "SEAM 100", title: "Lab 4 due Friday",
        body: "Please submit Lab 4 by Friday at 5pm.", postedAt: now
    )

    /// Written before the judgment existed: only `extract`.
    private struct OldStyle: AnnouncementAssignmentExtractor {
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            [ExtractedAssignment(title: "Old", dueAt: nil, kind: .preparation)]
        }
    }

    /// Overrides the new requirement and answers something `extract` does not.
    private struct Judging: AnnouncementAssignmentExtractor {
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            []
        }
        func extractWithRelevance(from announcement: AnnouncementSourceText, now: Date) async throws -> AnnouncementExtraction {
            AnnouncementExtraction(
                assignments: [ExtractedAssignment(title: "Judged", dueAt: nil)],
                relevance: AnnouncementRelevance(kind: .standing)
            )
        }
    }

    @Test("the default carries what extract finds and no relevance")
    func defaultImplementation() async throws {
        let extraction = try await OldStyle().extractWithRelevance(from: Self.source, now: Self.now)
        #expect(extraction == AnnouncementExtraction(
            assignments: [ExtractedAssignment(title: "Old", dueAt: nil, kind: .preparation)],
            relevance: nil
        ))
    }

    @Test("called through the existential, as the sync calls it, an override is reached and the default still serves the rest")
    func dispatchThroughTheExistential() async throws {
        // The sync holds every extractor as `any AnnouncementAssignmentExtractor`.
        // A method that was only in the protocol extension would run the default
        // here and never the override.
        let judging: any AnnouncementAssignmentExtractor = Judging()
        let extraction = try await judging.extractWithRelevance(from: Self.source, now: Self.now)
        #expect(extraction.assignments.map(\.title) == ["Judged"])
        #expect(extraction.relevance == AnnouncementRelevance(kind: .standing))

        let oldStyle: any AnnouncementAssignmentExtractor = OldStyle()
        let fallback = try await oldStyle.extractWithRelevance(from: Self.source, now: Self.now)
        #expect(fallback.assignments.map(\.title) == ["Old"])
        #expect(fallback.relevance == nil)
    }

    @Test("the on-device heuristic keeps the default: the same tasks as extract, and no relevance")
    func heuristicHasNoRelevance() async throws {
        let heuristic: any AnnouncementAssignmentExtractor = HeuristicAnnouncementExtractor()
        let plain = try await heuristic.extract(from: Self.source, now: Self.now)
        let extraction = try await heuristic.extractWithRelevance(from: Self.source, now: Self.now)
        #expect(extraction.assignments == plain)
        #expect(extraction.relevance == nil)
    }
}

// MARK: - Store

@Suite("Announcement relevance: the on-phone store")
struct AnnouncementRelevanceStoreTests {
    private func withScratch(_ body: (UserDefaults, AnnouncementRelevanceStore) throws -> Void) rethrows {
        let name = "announcement-relevance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, AnnouncementRelevanceStore(defaults: defaults))
    }

    private static let until = Date(timeIntervalSince1970: 1_793_419_140.25)

    @Test("what is merged is read back, with the date intact, by a store over the same defaults")
    func roundTrip() {
        withScratch { defaults, store in
            #expect(store.all.isEmpty)
            let saved = store.merge([
                AnnouncementReadState.recordKey("42"): AnnouncementRelevance(kind: .event, until: Self.until),
                AnnouncementReadState.edKey("ed:9:7"): AnnouncementRelevance(kind: .news),
            ])
            #expect(saved.count == 2)
            let reread = AnnouncementRelevanceStore(defaults: defaults).all
            #expect(reread == saved)
            #expect(reread[AnnouncementReadState.recordKey("42")]?.until == Self.until)
        }
    }

    @Test("a newer judgment for a post replaces the older one and leaves the others")
    func mergeReplaces() {
        withScratch { _, store in
            let key = AnnouncementReadState.recordKey("42")
            let other = AnnouncementReadState.recordKey("43")
            store.merge([key: AnnouncementRelevance(kind: .news), other: AnnouncementRelevance(kind: .standing)])
            let merged = store.merge([key: AnnouncementRelevance(kind: .task, until: Self.until)])
            #expect(merged[key] == AnnouncementRelevance(kind: .task, until: Self.until))
            #expect(merged[other] == AnnouncementRelevance(kind: .standing))
        }
    }

    @Test("replacing with nothing, or clearing, removes the key from the defaults")
    func emptyRemovesTheKey() {
        withScratch { defaults, store in
            store.merge([AnnouncementReadState.recordKey("42"): AnnouncementRelevance(kind: .news)])
            #expect(defaults.object(forKey: AnnouncementRelevanceStore.key) != nil)
            store.replace(with: [:])
            #expect(defaults.object(forKey: AnnouncementRelevanceStore.key) == nil)

            store.merge([AnnouncementReadState.recordKey("42"): AnnouncementRelevance(kind: .news)])
            store.clear()
            #expect(defaults.object(forKey: AnnouncementRelevanceStore.key) == nil)
            #expect(store.all.isEmpty)
        }
    }

    @Test("an entry this build cannot read is skipped and the rest survive; an unreadable blob is empty")
    func lossyRead() {
        withScratch { defaults, store in
            let blob = #"{"announcement:1":{"kind":"event","until":1000},"announcement:2":{"kind":"from-the-future"},"announcement:3":{"kind":"news"}}"#
            defaults.set(Data(blob.utf8), forKey: AnnouncementRelevanceStore.key)
            #expect(Set(store.all.keys) == ["announcement:1", "announcement:3"])

            defaults.set(Data("not json".utf8), forKey: AnnouncementRelevanceStore.key)
            #expect(store.all.isEmpty)
            defaults.set("a string, not data", forKey: AnnouncementRelevanceStore.key)
            #expect(store.all.isEmpty)
        }
    }
}

// MARK: - The rule

@Suite("Announcement records: staff mark and find states")
struct AnnouncementKeepCheckRuleTests {
    static let day: TimeInterval = 24 * 60 * 60
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ id: String,
        course: String = "KEEP 7300",
        daysAgo: Double,
        staff: Bool = false
    ) -> AnnouncementRecord {
        let posted = Self.now.addingTimeInterval(-daysAgo * Self.day)
        return AnnouncementRecord(
            id: id, courseID: "7300", courseCode: course, title: "Post \(id)", postedAt: posted,
            url: nil, snippet: "", recordedAt: posted, isStaffPost: staff
        )
    }

    // MARK: The record's staff mark

    @Test("a stored record from before the staff mark decodes as not a staff post, and a Canvas record encodes without the key")
    func staffMarkIsBackwardCompatible() throws {
        let legacy = #"{"id":"1","courseID":"9","courseCode":"KEEP 7300","title":"t","snippet":"s","recordedAt":1000}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(AnnouncementRecord.self, from: Data(legacy.utf8))
        #expect(decoded.isStaffPost == false)
        #expect(decoded.postedAt == nil && decoded.url == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let plain = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        #expect(!plain.contains("isStaffPost"))

        let staff = record("2", daysAgo: 1, staff: true)
        let staffJSON = try encoder.encode(staff)
        #expect(String(decoding: staffJSON, as: UTF8.self).contains("\"isStaffPost\":true"))
        #expect(try decoder.decode(AnnouncementRecord.self, from: staffJSON) == staff)
    }

    @Test("an Ed staff post is a marked row; one with no text, or past 60 days, is not; an announcement or pin is not marked")
    func edStaffRows() {
        let now = AnnouncementEdRowsTests.now
        func row(_ reason: String, body: String = "Midterm is Thursday.", daysAgo: Double = 2) -> AnnouncementRecord? {
            AnnouncementRecord.edRecord(
                from: AnnouncementEdRowsTests.edDocument(reason: reason, body: body, daysAgo: daysAgo, now: now), now: now
            )
        }
        #expect(row("staff post")?.isStaffPost == true)
        #expect(row("announcement")?.isStaffPost == false)
        #expect(row("pinned")?.isStaffPost == false)
        #expect(row("staff post", body: "- [image]") == nil)
        #expect(row("staff post", daysAgo: 61) == nil)
        #expect(row("staff post", daysAgo: 59) != nil)
        #expect(row("question") == nil)
    }

    @Test("hundreds of staff posts do not push an announcement out of the Ed rows")
    func staffPostsAreBoundedOnTheirOwn() {
        let now = AnnouncementEdRowsTests.now
        let announcement = AnnouncementEdRowsTests.edDocument(
            thread: "1", reason: "announcement", daysAgo: 50, now: now
        )
        let staff = (0..<320).map { index in
            AnnouncementEdRowsTests.edDocument(
                thread: "\(1000 + index)", reason: "staff post", daysAgo: 1 + Double(index) / 10, now: now
            )
        }
        let rows = AnnouncementRecord.edRecords(from: staff + [announcement], now: now)
        #expect(rows.contains { $0.id == announcement.id }, "one `pruned` over both would cut it at 300")
        #expect(rows.filter(\.isStaffPost).count == AnnouncementLogStore.maxRecords)
        #expect(rows == rows.sorted(by: AnnouncementRecord.isNewer(_:than:)))
    }

    // MARK: Where a post's finds stand

    private func find(_ sourceID: String) -> Assignment {
        Assignment(
            source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment, course: "KEEP 7300",
            title: sourceID, dueAt: nil, url: nil
        )
    }

    @Test("a post is open if any find from it is to do, all done if every one is done, and has no entry without finds")
    func findStates() {
        let finds = [
            find("announcement-100-0"), find("announcement-100-1"),
            find("announcement-101-0"),
            find("announcement-102-0"), find("announcement-102-1"),
        ]
        let done: Set<String> = [
            "announcement-100-0", "announcement-100-1",
            "announcement-101-0",
            "announcement-102-1",
        ]
        let states = AppState.announcementFindStates(finds) { done.contains($0.sourceID) }
        #expect(states[AnnouncementReadState.recordKey("100")] == .allDone)
        #expect(states[AnnouncementReadState.recordKey("101")] == .allDone)
        #expect(states[AnnouncementReadState.recordKey("102")] == .open)
        #expect(states[AnnouncementReadState.recordKey("103")] == nil)
        // Order does not matter: an open find after a done one still opens the post.
        let reversed = AppState.announcementFindStates(finds.reversed()) { done.contains($0.sourceID) }
        #expect(reversed == states)
    }

    @Test("an Ed find is filed under the Ed key of its document, and a syllabus exam or any other row under no post")
    func findStateKeys() {
        let states = AppState.announcementFindStates([
            find("ed-9501-77-0"),
            find("syllabus-9501-midterm-1"),
            find("something-else"),
            find("announcement-notanumber"),
        ]) { _ in false }
        #expect(states == [AnnouncementReadState.edKey("ed:9501:77"): .open])
        #expect(AppState.announcementPostKey(forFindSourceID: "announcement-55-2") == AnnouncementReadState.recordKey("55"))
        #expect(AppState.announcementPostKey(forFindSourceID: "ed-9501-77-0") == AnnouncementReadState.edKey("ed:9501:77"))
        #expect(AppState.announcementPostKey(forFindSourceID: "syllabus-9501-final") == nil)
    }

    @Test("the key an Ed find maps to is the key of the Ed row the sheet lists")
    func edFindKeyMatchesTheEdRow() throws {
        let document = AnnouncementEdRowsTests.edDocument(thread: "77", courseID: "9501", course: "KEEP 9501", daysAgo: 1)
        let row = try #require(AnnouncementRecord.edRecord(from: document, now: document.fetchedAt))
        let sourceID = AnnouncementRecord.edFindSourceID(courseID: document.courseID, threadID: document.sourceID, index: 0)
        #expect(AppState.announcementPostKey(forFindSourceID: sourceID) == AnnouncementReadState.key(for: row))
    }
}

// MARK: - The staff-post budget and the reading order

@Suite("Ed staff-post budget: a daily cap on reads")
struct RelevanceReadBudgetTests {
    private func withScratch(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "ed-staff-budget-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// 2026-10-23T00:00:00Z.
    private static let midnight = Date(timeIntervalSince1970: 1_792_713_600)

    @Test("the day is the UTC day: the last second of one day and the first of the next are different days")
    func utcDay() {
        let before = Self.midnight.addingTimeInterval(-1)
        #expect(RelevanceReadBudget.utcDay(of: Self.midnight) == RelevanceReadBudget.utcDay(of: before) + 1)
        #expect(RelevanceReadBudget.utcDay(of: Self.midnight.addingTimeInterval(86_399)) == RelevanceReadBudget.utcDay(of: Self.midnight))
        #expect(RelevanceReadBudget.utcDay(of: Date(timeIntervalSince1970: 0)) == 0)
    }

    private func exerciseTheLimit(_ budget: RelevanceReadBudget) {
        #expect(budget.remaining(on: Self.midnight) == 6)
        for call in 1...6 {
            #expect(budget.remaining(on: Self.midnight) > 0)
            budget.recordCall(on: Self.midnight.addingTimeInterval(Double(call)))
        }
        #expect(budget.used(on: Self.midnight) == 6)
        #expect(budget.remaining(on: Self.midnight.addingTimeInterval(86_399)) == 0)
        // The next UTC day starts again; the old day's count does not follow.
        #expect(budget.remaining(on: Self.midnight.addingTimeInterval(86_400)) == 6)
        budget.recordCall(on: Self.midnight.addingTimeInterval(86_400))
        #expect(budget.used(on: Self.midnight.addingTimeInterval(86_400)) == 1)
        #expect(budget.used(on: Self.midnight) == 0, "only the latest day is kept")
    }

    @Test("the limit is six a day, and the count runs out exactly there, in memory and in defaults")
    func limit() {
        #expect(RelevanceReadBudget.dailyLimit == 6)
        exerciseTheLimit(RelevanceReadBudget(defaults: nil))
        withScratch { exerciseTheLimit(RelevanceReadBudget(defaults: $0)) }
    }

    @Test("a budget with no defaults keeps its count in itself only, and two budgets do not share it")
    func memoryOnly() {
        let one = RelevanceReadBudget(defaults: nil)
        let two = RelevanceReadBudget(defaults: nil)
        one.recordCall(on: Self.midnight)
        #expect(one.used(on: Self.midnight) == 1)
        #expect(two.used(on: Self.midnight) == 0)
    }

    @Test("an unreadable stored value counts as nothing used")
    func unreadableStoredValue() {
        withScratch { defaults in
            let budget = RelevanceReadBudget(defaults: defaults)
            for junk: Any in ["text", 7, ["day": "x"], ["count": 3], ["day": RelevanceReadBudget.utcDay(of: Self.midnight)]] {
                defaults.set(junk, forKey: RelevanceReadBudget.key)
                #expect(budget.used(on: Self.midnight) == 0, "\(junk)")
            }
            defaults.set(["day": RelevanceReadBudget.utcDay(of: Self.midnight), "count": -4], forKey: RelevanceReadBudget.key)
            #expect(budget.used(on: Self.midnight) == 0)
            #expect(budget.remaining(on: Self.midnight) == 6)
        }
    }

    @Test("the reading order keeps announcements and pins as they came and puts staff posts after them, newest first")
    func readingOrder() {
        let now = AnnouncementEdRowsTests.now
        func doc(_ thread: String, _ reason: String, daysAgo: Double) -> CourseDocument {
            AnnouncementEdRowsTests.edDocument(thread: thread, reason: reason, daysAgo: daysAgo, now: now)
        }
        let oldStaff = doc("10", "staff post", daysAgo: 9)
        let announcement = doc("11", "announcement", daysAgo: 8)
        let newStaff = doc("12", "staff post", daysAgo: 1)
        let pinned = doc("13", "pinned", daysAgo: 12)
        let midStaff = doc("14", "staff post", daysAgo: 4)
        let sameDayHigherID = doc("15", "staff post", daysAgo: 4)

        let order = AppState.edReadOrder([oldStaff, announcement, newStaff, pinned, midStaff, sameDayHigherID])
        #expect(order.map(\.id) == [
            announcement.id, pinned.id,                                  // as they came
            newStaff.id, sameDayHigherID.id, midStaff.id, oldStaff.id,   // newest first, ties by id descending
        ])
        #expect(AppState.edReadOrder([]).isEmpty)
        #expect(AppState.edReadOrder([announcement, pinned]).map(\.id) == [announcement.id, pinned.id])
    }
}
