import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// The McGraw Hill reader's first pieces (2026-11-02): everything that needs no
// McGraw Hill endpoint. The remote kill switch (`ReaderSwitches`,
// `ReaderSwitchStore`, `ReaderGate`, `UpdateGateStore` recording it), the
// recognition of a Canvas assignment that launches Connect or ALEKS
// (`McGrawHillTool`, `GradeItem.externalToolHost`), the Smooth Sweeper leaving
// that work alone (`DashItem.completionNotVisible`), the enrichment pass
// (`McGrawHillEnricher`), the reauth rule, the Keychain service, and the ask
// boundary (`McGrawHillRow`). Every suite uses scratch `UserDefaults` suites;
// none touches `UserDefaults.lhf`, the Keychain or the notification center.
//
// What these cannot show: anything about McGraw Hill itself. No endpoint has
// been seen (`docs/mcgraw-hill/MARCO_BRIEFS.md`, brief 1), so the host list
// and the enrichment's inputs are built from the research, not from a real
// response.

private func scratchDefaults() -> (UserDefaults, String) {
    let name = "lhf.tests.mcgrawHill.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

private func destroy(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
}

// MARK: - The manifest's `readers` object

@Suite("McGraw Hill kill switch: decoding")
struct ReaderSwitchesDecodingTests {

    private func policy(_ json: String) throws -> UpdatePolicy {
        try JSONDecoder().decode(UpdatePolicy.self, from: Data(json.utf8))
    }

    @Test("only the JSON literal true under mcgrawHill turns the reader on")
    func literalTrueIsOn() throws {
        let decoded = try policy(#"{"minimumVersion":"3.4.0","readers":{"mcgrawHill":true}}"#)
        #expect(decoded.readers?.mcgrawHill == true)
    }

    @Test("every other value reads as off, and never costs minimumVersion", arguments: [
        #"{"minimumVersion":"3.4.0"}"#,
        #"{"minimumVersion":"3.4.0","readers":null}"#,
        #"{"minimumVersion":"3.4.0","readers":{}}"#,
        #"{"minimumVersion":"3.4.0","readers":{"mcgrawHill":false}}"#,
        #"{"minimumVersion":"3.4.0","readers":{"mcgrawHill":"true"}}"#,
        #"{"minimumVersion":"3.4.0","readers":{"mcgrawHill":1}}"#,
        #"{"minimumVersion":"3.4.0","readers":{"mcgrawHill":null}}"#,
        #"{"minimumVersion":"3.4.0","readers":{"mcgrawHill":{"on":true}}}"#,
        #"{"minimumVersion":"3.4.0","readers":{"McGrawHill":true}}"#,
        #"{"minimumVersion":"3.4.0","readers":{"aleks":true}}"#,
        #"{"minimumVersion":"3.4.0","readers":"on"}"#,
        #"{"minimumVersion":"3.4.0","readers":[true]}"#,
        #"{"minimumVersion":"3.4.0","readers":true}"#,
    ])
    func everythingElseIsOff(json: String) throws {
        let decoded = try policy(json)
        #expect(decoded.readers?.mcgrawHill != true)
        #expect(decoded.minimumVersion == AppVersion("3.4.0"),
                "a bad readers value must never cost the floor")
    }

    @Test("a readers object beside a bad feedback object still decodes, and the floor survives both")
    func besideBadFeedback() throws {
        let decoded = try policy(
            #"{"minimumVersion":"3.4.0","feedback":{"id":"x"},"readers":{"mcgrawHill":true}}"#
        )
        #expect(decoded.feedback == nil)
        #expect(decoded.readers?.mcgrawHill == true)
        #expect(decoded.minimumVersion == AppVersion("3.4.0"))
    }

    @Test("readers round-trips through the policy cache's encoding")
    func roundTrip() throws {
        let original = UpdatePolicy(minimumVersion: AppVersion("3.4.0"), readers: ReaderSwitches(mcgrawHill: true))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(UpdatePolicy.self, from: data) == original)
    }

    @Test("a policy without readers encodes no readers key, as an older build wrote it")
    func absentStaysAbsent() throws {
        let data = try JSONEncoder().encode(UpdatePolicy(minimumVersion: AppVersion("3.4.0")))
        #expect(!String(decoding: data, as: UTF8.self).contains("readers"))
    }
}

// MARK: - The last-known switch

@Suite("McGraw Hill kill switch: last-known store")
struct ReaderSwitchStoreTests {

    private static let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("a fresh install with no successful fetch is off")
    func nothingRecordedIsOff() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        #expect(ReaderSwitchStore(defaults: defaults).load(now: Self.fetchedAt) == .allOff)
    }

    @Test("a recorded on is on until the record is a week old, then off")
    func onUntilStale() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = ReaderSwitchStore(defaults: defaults)
        store.record(ReaderSwitches(mcgrawHill: true), at: Self.fetchedAt)

        #expect(store.load(now: Self.fetchedAt).mcgrawHill)
        #expect(store.load(now: Self.fetchedAt + ReaderSwitchStore.maximumTrustedAge).mcgrawHill)
        #expect(!store.load(now: Self.fetchedAt + ReaderSwitchStore.maximumTrustedAge + 1).mcgrawHill)
    }

    @Test("a record from the future (a clock moved back) is off")
    func futureRecordIsOff() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = ReaderSwitchStore(defaults: defaults)
        store.record(ReaderSwitches(mcgrawHill: true), at: Self.fetchedAt)
        #expect(!store.load(now: Self.fetchedAt - 60).mcgrawHill)
    }

    @Test("a fetch with no readers object switches a phone that was on, off")
    func missingKeyTurnsOff() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = ReaderSwitchStore(defaults: defaults)
        store.record(ReaderSwitches(mcgrawHill: true), at: Self.fetchedAt)
        store.record(nil, at: Self.fetchedAt + 60)
        #expect(!store.load(now: Self.fetchedAt + 120).mcgrawHill)
    }

    @Test("an undecodable stored blob is off")
    func garbageIsOff() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = ReaderSwitchStore(defaults: defaults)
        store.record(ReaderSwitches(mcgrawHill: true), at: Self.fetchedAt)
        defaults.set(Data("not json".utf8), forKey: "lhf.readerSwitchesV1")
        #expect(!store.load(now: Self.fetchedAt).mcgrawHill)
    }

    @Test("clear forgets the record")
    func clearIsOff() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = ReaderSwitchStore(defaults: defaults)
        store.record(ReaderSwitches(mcgrawHill: true), at: Self.fetchedAt)
        store.clear()
        #expect(!store.load(now: Self.fetchedAt).mcgrawHill)
    }
}

// MARK: - The gate

@Suite("McGraw Hill kill switch: gate")
struct ReaderGateTests {

    struct Row: Sendable, CustomTestStringConvertible {
        let compiledIn: Bool, manifest: Bool, forced: Bool, fixture: Bool, expected: Bool
        var testDescription: String {
            "compiledIn \(compiledIn) manifest \(manifest) forced \(forced) fixture \(fixture) -> \(expected)"
        }
    }

    static let rows: [Row] = [
        Row(compiledIn: true, manifest: true, forced: false, fixture: false, expected: true),
        Row(compiledIn: true, manifest: false, forced: true, fixture: false, expected: true),
        Row(compiledIn: true, manifest: false, forced: false, fixture: false, expected: false),
        Row(compiledIn: false, manifest: true, forced: false, fixture: false, expected: false),
        Row(compiledIn: false, manifest: true, forced: true, fixture: false, expected: false),
        Row(compiledIn: true, manifest: true, forced: false, fixture: true, expected: false),
        Row(compiledIn: true, manifest: false, forced: true, fixture: true, expected: false),
    ]

    @Test("the reader runs only when compiled in, switched on (or DEBUG-forced), and not on preview data",
          arguments: rows)
    func table(row: Row) {
        #expect(ReaderGate.mcgrawHill(
            compiledIn: row.compiledIn,
            switches: ReaderSwitches(mcgrawHill: row.manifest),
            debugForced: row.forced,
            isUsingFixtureData: row.fixture
        ) == row.expected)
    }

    @Test("the compile-time flag is off until the reader exists")
    func flagIsOff() {
        #expect(FeatureFlags.mcgrawHillReader == false)
    }
}

// MARK: - The update gate records the switch

@MainActor
@Suite("McGraw Hill kill switch: recorded by the update gate")
struct ReaderSwitchRecordingTests {

    /// Answers from the path alone (no shared mutable stub state).
    private final class ManifestURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let body: String
            switch request.url?.path {
            case "/on.json": body = #"{"minimumVersion":"0.1.0","readers":{"mcgrawHill":true}}"#
            case "/off.json": body = #"{"minimumVersion":"0.1.0"}"#
            default: body = "not json"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func store(path: String, defaults: UserDefaults) -> UpdateGateStore {
        UpdateGateStore(
            installedVersion: AppVersion("3.4.0"),
            manifestURL: URL(string: "https://example.com\(path)")!,
            session: session(),
            cache: UpdatePolicyCache(defaults: defaults),
            now: { Self.now },
            defaults: defaults,
            clearNotifications: {}
        )
    }

    @Test("a fetched manifest that says on records on")
    func recordsOn() async {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        await store(path: "/on.json", defaults: defaults).refresh()
        #expect(ReaderSwitchStore(defaults: defaults).load(now: Self.now).mcgrawHill)
    }

    @Test("a fetched manifest without readers records off over an earlier on")
    func recordsOffOverOn() async {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        ReaderSwitchStore(defaults: defaults).record(ReaderSwitches(mcgrawHill: true), at: Self.now - 60)
        await store(path: "/off.json", defaults: defaults).refresh()
        #expect(!ReaderSwitchStore(defaults: defaults).load(now: Self.now).mcgrawHill)
    }

    @Test("a manifest that fails to decode records nothing, and nothing recorded is off")
    func failedFetchRecordsNothing() async {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        await store(path: "/broken.json", defaults: defaults).refresh()
        #expect(defaults.object(forKey: "lhf.readerSwitchesV1") == nil)
        #expect(!ReaderSwitchStore(defaults: defaults).load(now: Self.now).mcgrawHill)
    }

    @Test("a cached policy that says on does not turn the reader on at launch: only a fetch does")
    func cacheAloneNeverTurnsOn() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let cache = UpdatePolicyCache(defaults: defaults)
        cache.save(UpdatePolicy(minimumVersion: AppVersion("0.1.0"), readers: ReaderSwitches(mcgrawHill: true)),
                   at: Self.now - 60)
        _ = UpdateGateStore(
            installedVersion: AppVersion("3.4.0"),
            manifestURL: nil,
            session: session(),
            cache: cache,
            now: { Self.now },
            defaults: defaults,
            clearNotifications: {}
        )
        #expect(!ReaderSwitchStore(defaults: defaults).load(now: Self.now).mcgrawHill)
    }
}

// MARK: - Recognising Connect and ALEKS launches

@Suite("McGraw Hill tool recognition")
struct McGrawHillToolTests {

    static let known: [(String, McGrawHillTool.Product)] = [
        ("newconnect.mheducation.com", .connect),
        ("connect.mheducation.com", .connect),
        ("lti.mheducation.com", .connect),
        ("mheducation.com", .connect),
        ("CONNECT.MHEDUCATION.COM", .connect),
        ("connect.mheducation.com.", .connect),
        ("connect.mcgraw-hill.com", .connect),
        ("mhcampus.com", .connect),
        ("www.aleks.com", .aleks),
        ("aleks.com", .aleks),
        ("aleks.mheducation.com", .aleks),
    ]

    @Test("McGraw Hill hosts are recognised, with their product", arguments: known)
    func recognised(host: String, product: McGrawHillTool.Product) {
        #expect(McGrawHillTool.product(forHost: host) == product)
    }

    @Test("other tools and look-alike hosts are not McGraw Hill", arguments: [
        "us.edstem.org", "www.gradescope.com", "canvas.upenn.edu", "mylab.pearson.com",
        "notmheducation.com", "mheducation.com.evil.example", "aleks.com.evil.example",
        "fakealeks.com", "", "   ",
    ])
    func notRecognised(host: String) {
        #expect(McGrawHillTool.product(forHost: host) == nil)
        #expect(!McGrawHillTool.isMcGrawHill(host: host))
    }

    @Test("nil is not McGraw Hill")
    func nilHost() {
        #expect(!McGrawHillTool.isMcGrawHill(host: nil))
    }

    @Test("only the host is kept from a launch URL")
    func hostOnly() {
        #expect(McGrawHillTool.host(fromLaunchURL:
            "https://LTI.mheducation.com/lti/launch?resource_link_id=abc&token=secret") == "lti.mheducation.com")
        #expect(McGrawHillTool.host(fromLaunchURL: "not a url") == nil)
        #expect(McGrawHillTool.host(fromLaunchURL: nil) == nil)
    }

    @Test("labels follow the app's lowercase copy")
    func labels() {
        #expect(McGrawHillTool.Product.connect.label == "in connect")
        #expect(McGrawHillTool.Product.aleks.label == "in aleks")
    }
}

// MARK: - Canvas decoding of external_tool_tag_attributes

@Suite("McGraw Hill: Canvas external_tool_tag_attributes")
struct ExternalToolTagDecodingTests {

    private static let courseJSON = Data(#"{"apply_assignment_group_weights": false, "enrollments": []}"#.utf8)

    private func items(assignmentsJSON: String) throws -> [GradeItem] {
        let groups = #"[{"id": 1, "name": "Group", "assignments": "# + assignmentsJSON + "}]"
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "1",
            courseJSON: Self.courseJSON,
            assignmentGroupPages: [Data(groups.utf8)]
        )
        return snapshot.categories.flatMap(\.items)
    }

    @Test("an LTI assignment's launch host decodes onto GradeItem, and nothing else of the url")
    func hostDecodes() throws {
        let decoded = try items(assignmentsJSON: """
        [{"id": 7, "name": "Chapter 4 Homework", "points_possible": 10,
          "submission_types": ["external_tool"],
          "external_tool_tag_attributes": {"url": "https://connect.mheducation.com/lti/launch?id=99", "new_tab": true},
          "submission": null}]
        """)
        let item = try #require(decoded.first)
        #expect(item.externalToolHost == "connect.mheducation.com")
        #expect(McGrawHillTool.isMcGrawHill(host: item.externalToolHost))
    }

    @Test("an ordinary assignment has no tool host")
    func ordinaryHasNone() throws {
        let decoded = try items(assignmentsJSON: """
        [{"id": 8, "name": "Essay", "submission_types": ["online_upload"], "submission": null}]
        """)
        #expect(decoded.first?.externalToolHost == nil)
    }

    @Test("a malformed external_tool_tag_attributes never fails the page", arguments: [
        #""external_tool_tag_attributes": null"#,
        #""external_tool_tag_attributes": "https://connect.mheducation.com""#,
        #""external_tool_tag_attributes": [1, 2]"#,
        #""external_tool_tag_attributes": {"url": 5}"#,
        #""external_tool_tag_attributes": {}"#,
    ])
    func malformedNeverThrows(field: String) throws {
        let decoded = try items(assignmentsJSON: """
        [{"id": 9, "name": "Quiz", "submission_types": ["external_tool"], \(field), "submission": null}]
        """)
        #expect(decoded.count == 1)
        #expect(decoded.first?.externalToolHost == nil)
    }

    @Test("a GradeItem encoded before the field existed still decodes")
    func oldSnapshotDecodes() throws {
        let old = #"{"id":"1","name":"HW","pointsPossible":10,"isExcused":false,"omitFromFinalGrade":false}"#
        let item = try JSONDecoder().decode(GradeItem.self, from: Data(old.utf8))
        #expect(item.externalToolHost == nil)
    }
}

// MARK: - The persisted id cache

@Suite("McGraw Hill: tool id cache")
struct McGrawHillToolIDCacheTests {

    private func snapshot(_ items: [GradeItem]) -> CourseGradeSnapshot {
        CourseGradeSnapshot(
            courseID: "1", courseUsesWeights: false,
            categories: [GradeCategory(id: "c", name: "All", items: items)],
            canvasComputedCurrentScore: nil, submissions: [], fetchedAt: Date()
        )
    }

    @Test("observed items enter or leave per item; unobserved ids are kept")
    func perItemReplace() {
        let snap = snapshot([
            GradeItem(id: "connect", name: "Ch 4", pointsPossible: 10, externalToolHost: "connect.mheducation.com"),
            GradeItem(id: "aleks", name: "Pie 1", pointsPossible: 10, externalToolHost: "www.aleks.com"),
            GradeItem(id: "ed", name: "Ed", pointsPossible: 0, externalToolHost: "us.edstem.org"),
            GradeItem(id: "was-connect", name: "Moved", pointsPossible: 10),
        ])
        let next = AppState.updatedMcGrawHillToolIDs(
            cached: ["was-connect", "other-course"],
            snapshots: [snap]
        )
        #expect(next == ["connect", "aleks", "other-course"])
    }
}

// MARK: - The Sweeper leaves McGraw Hill work alone

@MainActor
@Suite("McGraw Hill: the Sweeper")
struct McGrawHillSweeperTests {

    private func withScheduler(_ body: (NotificationScheduler, CoursePreferencesStore, Date) -> Void) {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        body(NotificationScheduler(defaults: defaults), CoursePreferencesStore(defaults: defaults), Date())
    }

    private func item(_ id: String, due: Date, completionNotVisible: Bool) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: "ECON 0100", title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil,
            completionNotVisible: completionNotVisible
        )
    }

    @Test("no alarm and no loud buzz for McGraw Hill work Canvas cannot see finished; ordinary work still gets both")
    func excluded() {
        withScheduler { scheduler, prefs, now in
            let due = now + 6 * 3600
            let items = [
                item("connect", due: due, completionNotVisible: true),
                item("essay", due: due + 60, completionNotVisible: false),
            ]
            let loud = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
                .filter { $0.identifier.hasPrefix("loud:") }
            #expect(loud.contains { $0.identifier.contains("canvas:essay") })
            #expect(!loud.contains { $0.identifier.contains("canvas:connect") })

            let alarms = scheduler.plannedAlarms(from: items, now: now, preferences: prefs)
            #expect(alarms.map(\.assignmentID) == ["canvas:essay"])
        }
    }

    @Test("the plain lead-time reminders still come for McGraw Hill work")
    func plainRemindersStay() {
        withScheduler { scheduler, prefs, now in
            let items = [item("connect", due: now + 2 * 86_400, completionNotVisible: true)]
            let plain = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
                .filter { !$0.identifier.hasPrefix("loud:") }
            #expect(!plain.isEmpty)
        }
    }
}

// MARK: - Enrichment

@Suite("McGraw Hill: enrichment of Canvas rows")
struct McGrawHillEnrichmentTests {

    private static let due = Date(timeIntervalSince1970: 2_000_000_000)

    private func canvasRow(_ id: String, title: String, course: String = "ECON 0100", due: Date? = due) -> Assignment {
        Assignment(source: .canvas, sourceID: "event-assignment-\(id)", kind: .assignment,
                   course: course, title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    private func mh(_ key: String, title: String, course: String = "ECON 0100", due: Date? = due,
                    done: Bool = true, canvasID: String? = nil) -> McGrawHillItem {
        McGrawHillItem(key: key, product: .connect, course: course, title: title,
                       dueAt: due, isDone: done, canvasAssignmentID: canvasID)
    }

    @Test("a Connect item Canvas lists enriches that row: done, the label, no date change when they agree")
    func enrichesMatchingRow() {
        let result = McGrawHillEnricher.enrich(
            canvas: [canvasRow("11", title: "Chapter 4 Homework")],
            items: [mh("a", title: "Chapter 4 Homework")],
            mcgrawHillCanvasAssignmentIDs: ["11"]
        )
        #expect(result.enrichments["11"] == McGrawHillEnrichment(
            canvasAssignmentID: "11", isDone: true, studentDueAt: nil, label: "in connect"))
        #expect(result.unmatched.isEmpty)
    }

    @Test("the student's own due date rides along only when it differs from Canvas's")
    func extensionDate() {
        let extended = Self.due + 2 * 86_400
        let result = McGrawHillEnricher.enrich(
            canvas: [canvasRow("11", title: "Chapter 4 Homework")],
            items: [mh("a", title: "Chapter 4 Homework", due: extended)],
            mcgrawHillCanvasAssignmentIDs: ["11"]
        )
        #expect(result.enrichments["11"]?.studentDueAt == extended)
        #expect(McGrawHillEnricher.differingDue(mcgrawHill: Self.due + 30, canvas: Self.due) == nil)
    }

    @Test("an ordinary Canvas assignment with the same title is never enriched")
    func onlyRecognisedRows() {
        let result = McGrawHillEnricher.enrich(
            canvas: [canvasRow("22", title: "Homework 3")],
            items: [mh("a", title: "Homework 3")],
            mcgrawHillCanvasAssignmentIDs: []
        )
        #expect(result.enrichments.isEmpty)
        #expect(result.unmatched.map(\.key) == ["a"])
    }

    @Test("McGraw Hill's own link to the Canvas id wins over a title match")
    func explicitLinkWins() {
        let result = McGrawHillEnricher.enrich(
            canvas: [canvasRow("11", title: "Homework 3"), canvasRow("12", title: "Something else")],
            items: [mh("a", title: "Homework 3", canvasID: "12")],
            mcgrawHillCanvasAssignmentIDs: ["11", "12"]
        )
        #expect(Set(result.enrichments.keys) == ["12"])
    }

    @Test("a different class is never matched")
    func otherCourse() {
        let result = McGrawHillEnricher.enrich(
            canvas: [canvasRow("11", title: "Chapter 4 Homework", course: "ACCT 1010")],
            items: [mh("a", title: "Chapter 4 Homework", course: "ECON 0100")],
            mcgrawHillCanvasAssignmentIDs: ["11"]
        )
        #expect(result.enrichments.isEmpty)
        #expect(result.unmatched.count == 1)
    }

    @Test("each row takes one item and each item one row, in a fixed order")
    func oneToOne() {
        let result = McGrawHillEnricher.enrich(
            canvas: [canvasRow("11", title: "Chapter 4 Homework")],
            items: [mh("b", title: "Chapter 4 Homework", done: false), mh("a", title: "Chapter 4 Homework")],
            mcgrawHillCanvasAssignmentIDs: ["11"]
        )
        #expect(result.enrichments["11"]?.isDone == true, "key a is taken first")
        #expect(result.unmatched.map(\.key) == ["b"])
    }

    @Test("an unfinished item says not done")
    func notDone() {
        let result = McGrawHillEnricher.enrich(
            canvas: [canvasRow("11", title: "Chapter 4 Homework")],
            items: [mh("a", title: "Chapter 4 Homework", done: false)],
            mcgrawHillCanvasAssignmentIDs: ["11"]
        )
        #expect(result.enrichments["11"]?.isDone == false)
    }
}

// MARK: - Reauth

@Suite("McGraw Hill: reauth rule")
struct McGrawHillReauthRuleTests {

    private static let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    @Test("one sign-in page is a sighting, not a verdict")
    func oneSighting() {
        let state = McGrawHillReauthRule.advance(.clear, after: .loginPage, now: Self.t0)
        #expect(state.firstLoginPageAt == Self.t0)
        #expect(!state.needsReauth)
    }

    @Test("two sightings inside the hour are one event; an hour apart is the verdict")
    func twoSightings() {
        var state = McGrawHillReauthRule.advance(.clear, after: .loginPage, now: Self.t0)
        state = McGrawHillReauthRule.advance(state, after: .loginPage, now: Self.t0 + 59 * 60)
        #expect(!state.needsReauth)
        state = McGrawHillReauthRule.advance(state, after: .loginPage, now: Self.t0 + 60 * 60)
        #expect(state.needsReauth)
    }

    @Test("an accepted session clears everything; an inconclusive run changes nothing")
    func clearsAndHolds() {
        let sighted = McGrawHillReauthRule.State(firstLoginPageAt: Self.t0, needsReauth: true)
        #expect(McGrawHillReauthRule.advance(sighted, after: .inconclusive, now: Self.t0 + 7200) == sighted)
        #expect(McGrawHillReauthRule.advance(sighted, after: .sessionAccepted, now: Self.t0 + 7200) == .clear)
    }

    @Test("a sighting from the future restarts the count")
    func clockBack() {
        let future = McGrawHillReauthRule.State(firstLoginPageAt: Self.t0 + 3600)
        let state = McGrawHillReauthRule.advance(future, after: .loginPage, now: Self.t0)
        #expect(state.firstLoginPageAt == Self.t0)
        #expect(!state.needsReauth)
    }

    @Test("the store round-trips and resets, under its own keys")
    func store() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let state = McGrawHillReauthRule.State(firstLoginPageAt: Self.t0, needsReauth: true)
        McGrawHillReauthStore.save(state, defaults: defaults)
        #expect(McGrawHillReauthStore.load(defaults: defaults) == state)
        #expect(defaults.object(forKey: GradescopeReauthStore.needsReauthKey) == nil,
                "a McGraw Hill verdict must never be Gradescope's")
        McGrawHillReauthStore.reset(defaults: defaults)
        #expect(McGrawHillReauthStore.load(defaults: defaults) == .clear)
    }
}

// MARK: - Session storage and the ask boundary

@Suite("McGraw Hill: session store and ask boundary")
struct McGrawHillBoundaryTests {

    @Test("McGraw Hill has its own Keychain service with no 24-hour clock")
    func keychainService() {
        #expect(SessionCookieStore.Service.allCases.contains(.mcgrawHill))
        #expect(SessionCookieStore.Service.mcgrawHill.rawValue == "mcgrawHill")
        #expect(SessionCookieStore.maxAge(for: .mcgrawHill) == nil)
    }

    @Test("an mh- row is a McGraw Hill row; Canvas, Ed and syllabus rows are not")
    func rowPredicate() {
        func row(_ source: Assignment.Source, _ id: String) -> Assignment {
            Assignment(source: source, sourceID: id, kind: .assignment, course: "ECON 0100",
                       title: "HW", dueAt: nil, url: nil)
        }
        #expect(McGrawHillRow.isRow(row(.canvasAnnouncement, "mh-1-abc")))
        #expect(!McGrawHillRow.isRow(row(.canvasAnnouncement, "ed-1-2-0")))
        #expect(!McGrawHillRow.isRow(row(.canvasAnnouncement, "syllabus-1-midterm")))
        #expect(!McGrawHillRow.isRow(row(.canvasAnnouncement, "announcement-1-0")))
        #expect(!McGrawHillRow.isRow(row(.canvas, "mh-1-abc")), "the prefix means nothing outside announcement rows")
    }

    @Test("an mh- row never reaches the ask context document")
    func askDocumentLeavesItOut() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/LowHangingFruitUI/AssistantContextAssembly.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".filter { !McGrawHillRow.isRow($0) }"))
    }
}
