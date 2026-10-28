import Foundation
import Testing
@testable import LowHangingFruitKit

/// The hardening plan's fuzz suite (`docs/HARDENING_PLAN_2026-10-25.md`,
/// "Tests and gates"): everything that takes outside data is fed random and
/// malformed input, must never trap, and must finish inside a time budget.
///
/// Outside data here means: a school's calendar feed (ICS), Ed's JSON, a
/// Canvas modules response, grade groups as Canvas names them, announcement
/// text as a professor pastes it, and the update manifest, a static file
/// anyone with commit access can edit. A trap in any of these is a crash on
/// every launch (the duplicate-name `Dictionary(uniqueKeysWithValues:)` in the
/// grade engine was exactly that, found on a student's phone); a stall is a
/// frozen app with nothing to read.
///
/// Each suite uses a fixed seed (see `Fuzz` in `FuzzSupport.swift`), so a
/// failure reproduces. Set `LHF_FUZZ_TRACE=1` to print each iteration before
/// it runs; after a crash the last line printed is the one to replay.
/// Iteration counts are chosen so the whole file runs in well under a minute.

// MARK: - ICS

@Suite("Fuzz: ICS calendar feeds")
struct ICSFuzzTests {

    private static let valid = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:event-assignment-123\r
        SUMMARY:Problem Set 3 [CIS 1200-001 202630]\r
        DTSTART:20261027T235900Z\r
        URL:https://canvas.upenn.edu/calendar?include_contexts=course_1&month=10&year=2026#assignment_123\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        UID:event-calendar-event-9\r
        SUMMARY:Lecture\\, week 4 [MATH 1410-002 202630]\r
        DTSTART;VALUE=DATE:20261030\r
        END:VEVENT\r
        END:VCALENDAR\r

        """

    private static func randomEvent(_ rng: inout SeededGenerator) -> String {
        var lines = ["BEGIN:VEVENT"]
        if rng.chance(0.9) { lines.append("UID:" + rng.pick(["event-assignment-\(rng.int(0...999_999))", rng.unicode(rng.int(0...30)), ""])) }
        if rng.chance(0.9) { lines.append("SUMMARY:" + rng.pick([
            "Homework \(rng.int(0...20)) [CIS 1200-001 202630]", "[]", "[[[[", rng.unicode(rng.int(0...80)),
            String(repeating: "x", count: rng.int(0...3_000)), "Quiz\\nwith\\, escapes\\\\ and a trailing slash\\",
        ])) }
        if rng.chance(0.9) {
            let value = rng.pick([
                "20261027", "20261027T235959Z", "20261027T235959", "00000000", "99999999", "20261332T256199Z",
                "20260229", "2026", "T", "", rng.string(rng.int(0...20), from: "0123456789TZ-:"), rng.unicode(8),
            ])
            let params = rng.pick(["", ";VALUE=DATE", ";TZID=America/New_York", ";TZID=Not/AZone", ";TZID=", ";X=;Y;=Z"])
            lines.append("DTSTART\(params):\(value)")
        }
        if rng.chance(0.6) { lines.append("URL:" + rng.pick([
            "https://canvas.upenn.edu/calendar#assignment_1", "not a url", "", "http://[::1", "https://a b/ c", rng.unicode(10),
        ])) }
        if rng.chance(0.3) { lines.append(" folded continuation " + rng.unicode(5)) }
        if rng.chance(0.2) { lines.append("\t\tX-JUNK;A=B:" + rng.unicode(4)) }
        if rng.chance(0.9) { lines.append("END:VEVENT") }
        return lines.joined(separator: rng.pick(["\r\n", "\n", "\r"]))
    }

    @Test("random and malformed feeds never trap and always finish")
    func feeds() {
        Fuzz.run("ics", seed: 0x1C5, iterations: 400) { rng, _ in
            let input: Data
            switch rng.int(0...6) {
            case 0: input = rng.bytes(rng.int(0...4_096))
            case 1: input = Data(rng.unicode(rng.int(0...4_096)).utf8)
            case 2: input = rng.mutate(Data(Self.valid.utf8))
            case 3:
                let events = (0..<rng.int(0...60)).map { _ in Self.randomEvent(&rng) }
                input = Data((["BEGIN:VCALENDAR"] + events + ["END:VCALENDAR"]).joined(separator: "\r\n").utf8)
            case 4:   // many events, none closed; and one very long line
                input = Data((String(repeating: "BEGIN:VEVENT\nSUMMARY:x\n", count: rng.int(0...2_000))
                    + "SUMMARY:" + String(repeating: "y", count: rng.int(0...200_000))).utf8)
            case 5:   // a long run of folded continuation lines
                input = Data(("BEGIN:VEVENT\nSUMMARY:a\n" + String(repeating: " b\n", count: rng.int(0...50_000)) + "END:VEVENT\n").utf8)
            default:  // invalid UTF-8 spliced into an otherwise valid feed
                var bytes = Data(Self.valid.utf8)
                bytes.insert(contentsOf: [0xC3, 0x28, 0xFF, 0xFE, 0x00], at: rng.int(0...bytes.count))
                input = bytes
            }
            let events = ICSParser.parse(input)
            let items = CanvasICSClient.calendarItems(from: input)
            #expect(items.count == events.count)
        }
    }
}

// MARK: - Ed wire

@Suite("Fuzz: Ed wire decoding")
struct EdWireFuzzTests {

    private static let threads = """
        {"threads": [
          {"id": 1, "user_id": 7, "course_id": 101, "type": "announcement", "title": "Welcome",
           "document": "<document version=\\"2.0\\"><paragraph>Hi</paragraph></document>",
           "is_pinned": true, "is_private": false, "is_anonymous": false,
           "created_at": "2026-03-05T14:21:55.123456+11:00", "updated_at": null, "number": 3, "reply_count": 2},
          {"id": 2, "course_id": 101, "type": "question", "title": "Q", "created_at": "2026-03-05T14:21:55Z"}
        ], "users": [{"id": 7, "name": "A", "course_role": "admin"}, {"id": 8}]}
        """

    private static let user = """
        {"courses": [{"course": {"id": 101, "code": "CIS 1200", "name": "Programming", "year": "2026", "session": "Fall", "status": "active"},
                      "role": {"role": "student"}}, {"course": {"id": 102, "code": "X", "name": "Y"}}]}
        """

    @Test("Ed's JSON, random or damaged, decodes or throws but never traps")
    func bodies() {
        Fuzz.run("ed-json", seed: 0xED, iterations: 500) { rng, _ in
            let data: Data
            switch rng.int(0...4) {
            case 0: data = rng.bytes(rng.int(0...2_048))
            case 1: data = rng.jsonData(depth: 4)
            case 2: data = rng.mutate(Data(Self.threads.utf8))
            case 3: data = rng.mutate(Data(Self.user.utf8))
            default:
                // Ed-shaped, with fields of the wrong type and values at the edges.
                let thread: [String: Any] = [
                    "id": rng.jsonValue(depth: 1), "user_id": rng.jsonValue(depth: 1), "course_id": rng.jsonValue(depth: 1),
                    "type": rng.jsonValue(depth: 1), "title": rng.jsonValue(depth: 1),
                    "is_pinned": rng.jsonValue(depth: 1), "is_private": rng.jsonValue(depth: 1),
                    "is_anonymous": rng.jsonValue(depth: 1), "created_at": rng.jsonValue(depth: 1),
                ]
                let body: [String: Any] = ["threads": [thread, thread], "users": rng.jsonValue(depth: 2)]
                data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            }
            if let response = try? EdJSON.decoder().decode(EdThreadsResponse.self, from: data) {
                _ = EdThreadFilter.keptThreads(response)
            }
            _ = try? EdJSON.decoder().decode(EdUserResponse.self, from: data)
        }
    }

    @Test("Ed's timestamps, however they are spelled, parse or return nil")
    func timestamps() {
        Fuzz.run("ed-dates", seed: 0xDA7E, iterations: 3_000, perCase: 1) { rng, _ in
            let raw: String
            switch rng.int(0...3) {
            case 0: raw = rng.string(rng.int(0...40), from: "0123456789-:+.TZ ")
            case 1: raw = rng.unicode(rng.int(0...40))
            case 2:
                let fraction = String(repeating: "7", count: rng.int(0...30))
                raw = "2026-03-05T14:21:55" + (fraction.isEmpty ? "" : "." + fraction) + rng.pick(["Z", "+11:00", "+1100", "-0500", "+99:99", "", " UTC"])
            default: raw = rng.pick(["", " ", "T", "Z", "0", "2026", "2026-13-45T25:61:61Z", "+", "-", "."])
            }
            _ = EdJSON.parseDate(raw)
        }
    }
}

// MARK: - Canvas modules

@Suite("Fuzz: Canvas modules")
struct ModulesFuzzTests {

    private static func moduleItem(_ rng: inout SeededGenerator, id: Int) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "title": "Item \(id)",
            "type": rng.pick(["Page", "Assignment", "File", "ExternalUrl", "Quiz", "Discussion", "SubHeader", "ExternalTool"]),
        ]
        if rng.chance(0.5) { item["content_id"] = rng.int(1...100_000) }
        if rng.chance(0.4) { item["content_details"] = ["due_at": rng.pick(["2026-10-27T23:59:00Z", "2026-10-27T23:59:00.123Z", "garbage", ""])] }
        if rng.chance(0.3) { item["external_url"] = rng.pick(["https://example.edu/course", "not a url", "http://[::1"]) }
        return item
    }

    @Test("a well-formed modules response decodes exactly, with nothing dropped")
    func wellFormedIsExact() throws {
        Fuzz.run("modules-valid", seed: 0x40D, iterations: 200) { rng, _ in
            var expected = 0
            var nextID = 1
            let modules: [[String: Any]] = (0..<rng.int(0...6)).map { moduleIndex in
                let items: [[String: Any]] = (0..<rng.int(0...8)).map { _ in
                    defer { nextID += 1 }
                    let item = Self.moduleItem(&rng, id: nextID)
                    if (item["type"] as? String) != "SubHeader" { expected += 1 }
                    return item
                }
                return ["id": moduleIndex, "name": "Week \(moduleIndex)", "items": items]
            }
            let page = try! JSONSerialization.data(withJSONObject: modules)
            let prefixed = rng.chance(0.5) ? Data("while(1);".utf8) + page : page
            let result = CanvasModulesClient.decodeModules(fromPages: [prefixed])
            #expect(result.droppedCount == 0)
            #expect(result.items.count == expected)
        }
    }

    @Test("corrupting k items drops exactly k and keeps every other item")
    func corruptionIsCountedExactly() throws {
        Fuzz.run("modules-corrupt", seed: 0xC0DE, iterations: 200) { rng, _ in
            var modules: [[String: Any]] = []
            var survivors = 0
            var corrupted = 0
            var nextID = 1
            for moduleIndex in 0..<rng.int(1...5) {
                var items: [[String: Any]] = []
                for _ in 0..<rng.int(0...8) {
                    var item = Self.moduleItem(&rng, id: nextID)
                    nextID += 1
                    let isHeader = (item["type"] as? String) == "SubHeader"
                    if rng.chance(0.25) {
                        // Each of these makes `ModuleItemDTO` fail to decode.
                        switch rng.int(0...3) {
                        case 0: item["id"] = "not-a-number"
                        case 1: item["title"] = NSNull()
                        case 2: item["type"] = 7
                        default: item["id"] = [1, 2]
                        }
                        corrupted += 1
                    } else if !isHeader {
                        survivors += 1
                    }
                    items.append(item)
                }
                modules.append(["name": "Week \(moduleIndex)", "items": items])
            }
            let page = try! JSONSerialization.data(withJSONObject: modules)
            let result = CanvasModulesClient.decodeModules(fromPages: [page])
            #expect(result.droppedCount == corrupted)
            #expect(result.items.count == survivors)
        }
    }

    @Test("random and damaged modules and planner pages never trap")
    func damagedPages() {
        Fuzz.run("modules-random", seed: 0x9A6E, iterations: 500) { rng, _ in
            var pages: [Data] = []
            for _ in 0..<rng.int(0...4) {
                switch rng.int(0...5) {
                case 0: pages.append(rng.bytes(rng.int(0...1_024)))
                case 1: pages.append(rng.jsonData(depth: 4))
                case 2:
                    let items = (0..<rng.int(0...5)).map { Self.moduleItem(&rng, id: $0) }
                    let page = (try? JSONSerialization.data(withJSONObject: [["name": "W", "items": items]])) ?? Data()
                    pages.append(rng.mutate(page))
                case 3: pages.append(Data("while(1);".utf8) + rng.jsonData(depth: 3))
                case 4: pages.append(Data(String(repeating: "[", count: rng.int(0...20_000)).utf8))   // deeply nested
                default: pages.append(Data())
                }
            }
            let decoded = CanvasModulesClient.decodeModules(fromPages: pages)
            #expect(decoded.droppedCount >= 0)
            _ = CanvasModulesClient.plannerDatedItems(fromPages: pages, courseID: String(rng.int(0...5)))
            let planner = [PlannerDatedItem(
                plannableType: "wiki_page", plannableID: "1",
                plannedAt: Date(timeIntervalSince1970: Double(rng.int(0...2_000_000_000))), title: rng.unicode(5)
            )]
            _ = CanvasModulesClient.overlayDates(decoded.items, planner: planner)
        }
    }
}

// MARK: - Grade groups

@Suite("Fuzz: grade groups with duplicate names")
struct GradeFuzzTests {

    /// Names that slug to the same id as another entry in the list: case,
    /// spacing, punctuation and non-Latin text, the ways Canvas lets two
    /// groups collide.
    private static let names = [
        "Homework", "homework", "HOMEWORK", "Home work", "Quiz (EC)", "Quiz - EC", "Quiz  EC", "Quiz EC",
        "Exams", "Assignments", "Assignments", "", " ", "---", "日本語", "A/B", "A\\B", "a.b", "Participation", "Final Exam",
    ]

    private static func category(_ rng: inout SeededGenerator, index: Int) -> GradeCategory {
        let items: [GradeItem] = (0..<rng.int(0...7)).map { itemIndex in
            GradeItem(
                id: rng.chance(0.2) ? "dup" : "\(index)-\(itemIndex)",
                name: rng.pick(names),
                pointsPossible: rng.pick([0, 1, 5, 10, 100, 0.0001, 1e12, -5, 1e300, .nan, .infinity]),
                score: rng.chance(0.3) ? nil : rng.pick([0, 1, 4.5, 10, 11, 100, -3, 1e12, 1e300, .nan, -.infinity]),
                scoreSource: nil,
                isExcused: rng.chance(0.1),
                omitFromFinalGrade: rng.chance(0.1),
                dueAt: rng.chance(0.3) ? nil : Date(timeIntervalSince1970: Double(rng.int(-1_000_000...2_000_000_000))),
                submissionTypes: rng.chance(0.5) ? nil : [rng.pick(["online_upload", "none", "on_paper", ""])]
            )
        }
        return GradeCategory(
            // Few distinct ids, so some courses carry the same group id twice.
            id: String(rng.int(0...4)),
            name: rng.pick(names),
            weight: rng.pick([nil, 0, 25, 33.3, 100, -10, 1e9, .nan, .infinity]),
            dropLowest: rng.int(0...6),
            dropHighest: rng.int(0...6),
            neverDropIDs: rng.chance(0.3) ? ["dup", "0-0"] : [],
            items: items
        )
    }

    @Test("mirroring Canvas and computing a grade never traps, and mirrored ids are unique")
    func duplicateGroups() {
        Fuzz.run("grades", seed: 0x6AD, iterations: 600) { rng, _ in
            let categories = (0..<rng.int(0...9)).map { Self.category(&rng, index: $0) }
            let usesWeights = rng.chance(0.5)

            let map = GradeCategoryMapBuilder.mirroringCanvas(categories, courseUsesWeights: usesWeights)
            #expect(map.categories.count == categories.count)
            let ids = map.categories.map(\.id)
            #expect(Set(ids).count == ids.count, "mirrored ids collide: \(ids)")

            for categoryMap in [nil, map] as [GradeCategoryMap?] {
                let input = GradeEngine.Input(
                    courseUsesWeights: usesWeights,
                    categories: categories,
                    manualWeights: rng.chance(0.3) ? Dictionary(uniqueKeysWithValues: ids.prefix(3).map { ($0, 20.0) }) : [:],
                    dropLowestOverrides: rng.chance(0.2) ? ["0": rng.int(0...9)] : [:],
                    now: Date(timeIntervalSince1970: 1_790_000_000),
                    expectedCounts: rng.chance(0.3) ? ["0": rng.int(0...50)] : [:],
                    itemOverrides: rng.chance(0.3) ? ["dup": GradeItemOverride(score: 5, pointsPossible: rng.chance(0.5) ? 0 : nil)] : [:],
                    modeOverride: rng.pick([nil, .weighted, .points]),
                    categoryMap: categoryMap,
                    termWeeks: rng.pick([14, 0, 1, 52])
                )
                let breakdown = GradeEngine.compute(input)
                _ = GradeExplanation.make(from: breakdown, canvasScore: rng.chance(0.5) ? nil : rng.pick([0, 91.5, 1e9, -3]))
            }
        }
    }
}

// MARK: - Announcement text

@Suite("Fuzz: very long announcement text")
struct AnnouncementFuzzTests {

    private static let words = [
        "please", "submit", "turn", "in", "homework", "due", "by", "Friday", "Monday", "tomorrow", "before", "class",
        "9/12", "Sep", "12", "11:59", "pm", "midnight", "read", "chapter", "pp.", "ch.", "attend", "bring", "the", "a",
        "slides", "were", "posted", "no", "class", "exam", "quiz", "project", "you", "must", "should", "not",
    ]

    private static func prose(_ rng: inout SeededGenerator, words count: Int) -> String {
        var out = ""
        out.reserveCapacity(count * 6)
        for index in 0..<count {
            out += rng.pick(words)
            out += rng.chance(0.08) ? rng.pick([". ", "! ", "? ", ".\n", ".\n\n"]) : " "
            if index % 1_000 == 999, rng.chance(0.5) { out += rng.unicode(3) }
        }
        return out
    }

    private static func pathological(_ rng: inout SeededGenerator) -> String {
        switch rng.int(0...7) {
        case 0: return String(repeating: "due ", count: rng.int(1_000...60_000))
        case 1: return String(repeating: "a.", count: rng.int(1_000...60_000))
        case 2: return String(repeating: "9/", count: rng.int(1_000...60_000))
        case 3: return String(repeating: "Sep ", count: rng.int(1_000...40_000))
        case 4: return String(repeating: "pp. ch. ", count: rng.int(1_000...30_000))
        case 5: return String(repeating: "1", count: rng.int(10_000...200_000))
        case 6: return String(repeating: "please submit the homework due Friday at 11:59 pm. ", count: rng.int(500...5_000))
        default: return String(repeating: "\n", count: rng.int(1_000...100_000)) + "due"
        }
    }

    @Test("long and hostile announcement text goes through every rule and finishes")
    func longText() async throws {
        let extractor = HeuristicAnnouncementExtractor(calendar: Calendar(identifier: .gregorian))
        var rng = SeededGenerator(seed: 0xA11C)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<30 {
            Fuzz.trace("fuzz announcements seed=\(0xA11C) iteration=\(index)")
            let body = index % 2 == 0 ? Self.prose(&rng, words: rng.int(1_000...40_000)) : Self.pathological(&rng)
            let title = index % 3 == 0 ? Self.prose(&rng, words: rng.int(0...200)) : "Announcement \(index)"
            let started = Date()

            _ = HeuristicAnnouncementExtractor.mightContainTask(title: title, body: body)
            _ = HeuristicAnnouncementExtractor.isLikelyInformational(title: title, body: body)
            _ = AnnouncementTaskClassifier.isInformational(body)
            _ = AnnouncementTaskClassifier.taskKind(in: body)
            _ = AnnouncementClassReminder.isAttendanceInstruction(body)
            let found = try await extractor.extract(
                from: AnnouncementSourceText(announcementID: "\(index)", courseCode: "CIS 1200", title: title, body: body, postedAt: now),
                now: now
            )
            #expect(found.count <= 3, "the per-announcement cap held")

            let html = "<p>" + body.replacingOccurrences(of: ". ", with: "</p><p>") + "</p>"
            _ = CanvasAnnouncementsClient.plainText(fromHTML: html)

            let took = Date().timeIntervalSince(started)
            #expect(took < 10, "iteration \(index) (\(body.count) characters) took \(took)s")
        }
    }

    @Test("markup that is deeply nested or never closed is flattened without stalling")
    func hostileHTML() {
        Fuzz.run("announcement-html", seed: 0x47B1, iterations: 110, perCase: 5) { rng, _ in
            let html: String
            switch rng.int(0...10) {
            case 0: html = String(repeating: "<div>", count: rng.int(1_000...30_000))
            case 1: html = String(repeating: "<", count: rng.int(1_000...50_000))
            case 2: html = "<p " + String(repeating: "a=\"b\" ", count: rng.int(1_000...20_000))
            case 3: html = String(repeating: "&amp;&#x41;&#9999999999;&bogus; ", count: rng.int(500...10_000))
            // Openings that never close, in front of the closing token that
            // does exist once at the end, which is the shape a scan that only
            // checks "is there a terminator somewhere" still goes quadratic on.
            case 4: html = String(repeating: "<script", count: rng.int(1_000...30_000)) + "</script>"
            case 5: html = String(repeating: "<style ", count: rng.int(1_000...30_000))
            case 6: html = String(repeating: "<!--", count: rng.int(1_000...30_000))
            case 7: html = String(repeating: "<li ", count: rng.int(1_000...30_000))
            case 8: html = String(repeating: "<td ", count: rng.int(1_000...30_000)) + "x>"
            case 9: html = String(repeating: "<a", count: rng.int(1_000...30_000)) + String(repeating: "<", count: rng.int(0...30_000))
            default: html = rng.unicode(rng.int(0...50_000))
            }
            _ = CanvasAnnouncementsClient.plainText(fromHTML: html)
            _ = HTMLText.plainText(from: html)
        }
    }
}

// MARK: - Update manifest

@Suite("Fuzz: the update manifest")
struct ManifestFuzzTests {

    private static let valid = """
        {"minimumVersion": "3.0.0", "latestVersion": "3.2.1", "message": "Please update.", "appStoreURL": "https://apps.apple.com/app/id6783911002"}
        """

    @Test("random bytes, JSON and damaged manifests decode or throw, and a decoded policy always gives a verdict")
    func manifests() {
        let installed = AppVersion("3.1.0")!
        Fuzz.run("manifest", seed: 0xB0A7, iterations: 1_500, perCase: 2) { rng, _ in
            let data: Data
            switch rng.int(0...4) {
            case 0: data = rng.bytes(rng.int(0...512))
            case 1: data = rng.jsonData(depth: 3)
            case 2: data = rng.mutate(Data(Self.valid.utf8))
            case 3:
                let object: [String: Any] = [
                    "minimumVersion": rng.jsonValue(depth: 1), "latestVersion": rng.jsonValue(depth: 1),
                    "message": rng.jsonValue(depth: 1), "appStoreURL": rng.jsonValue(depth: 1),
                    rng.unicode(4): rng.jsonValue(depth: 2),
                ]
                data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            default:
                let version = rng.pick([
                    "3.0.0", "99999999999999999999999.1", "1." + String(repeating: "0.", count: rng.int(0...5_000)) + "1",
                    "٣.٤", "1.2.3.4.5.6.7.8", "-1", "+1", "1e3", " 3.0 ", "\u{0}3.0", rng.string(rng.int(0...30), from: "0123456789.- "),
                ])
                let message = rng.pick(["ok", rng.unicode(rng.int(0...2_000)), "\u{1B}[31mred\u{1B}[0m\n\n\tx", String(repeating: " ", count: 5_000)])
                let url = rng.pick([
                    "https://apps.apple.com/app/id1", "javascript:alert(1)", "http://example.com", "not a url", "",
                    "https://" + String(repeating: "a", count: 3_000) + ".com", rng.unicode(12),
                ])
                data = (try? JSONSerialization.data(withJSONObject: [
                    "minimumVersion": version, "latestVersion": version, "message": message, "appStoreURL": url,
                ])) ?? Data()
            }
            if let policy = try? UpdateManifestClient.policy(from: data) {
                _ = policy.verdict(forInstalled: installed)
                if let encoded = try? JSONEncoder().encode(policy) {
                    let roundTripped = try? JSONDecoder().decode(UpdatePolicy.self, from: encoded)
                    #expect(roundTripped == policy)
                }
            }
        }
    }

    @Test("version strings of any shape parse or return nil, and order consistently")
    func versions() {
        Fuzz.run("versions", seed: 0x5E7, iterations: 4_000, perCase: 1) { rng, _ in
            let a = AppVersion(rng.string(rng.int(0...24), from: "0123456789.. -+") )
            let b = AppVersion(rng.pick(["3.1.0", "3.1", "3", "0", rng.string(rng.int(1...12), from: "0123456789.")]))
            if let a, let b {
                #expect((a < b) == !(a >= b))
                #expect((a == b) == (b == a))
                if a == b { #expect(a.hashValue == b.hashValue) }
                _ = a.description
            }
        }
    }
}
