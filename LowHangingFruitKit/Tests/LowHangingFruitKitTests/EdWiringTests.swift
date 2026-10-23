import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The app-side wiring of Ed Discussion ingestion: the flag, the session
/// store's new `.ed` service, and the pure merge helpers
/// `EdDiscussionCoordinator` uses.
///
/// Deliberately pure. Nothing here touches the Keychain, `UserDefaults.lhf`
/// or a WebView: `SessionCookieStoreTests` owns the process-wide Keychain
/// items under `.serialized`, and a second suite writing them would race it
/// (see that suite's header). So the 24-hour rule is pinned through its pure
/// seam, `SessionCookieStore.isStale`, rather than by saving a cookie and
/// ageing it, which the store has no seam for on any service but `.canvas`
/// (`ageCanvasSessionForTesting`, which is itself a no-op under `swift test`).
@Suite("Ed Discussion wiring")
struct EdWiringTests {

    @Test("the Ed Discussion feature flag is on")
    func flagIsOn() {
        #expect(FeatureFlags.edDiscussion == true)
    }

    @Test("the Ed session token store is inert under the test runner")
    func tokenStoreIsInertUnderTests() {
        // `SessionCookieStore.merge` writes nothing under `isTestRunner`, and
        // `EdSessionTokenStore` goes further: save, load and remove are all
        // no-ops, because an unsandboxed macOS run would otherwise read and
        // delete the developer's real Ed token. So this pins the guard, not a
        // Keychain round trip, and touches no real Keychain item.
        #expect(SharedDefaults.isTestRunner)
        EdSessionTokenStore.save("x")
        #expect(EdSessionTokenStore.hasToken == false)
        #expect(EdSessionTokenStore.load() == nil)
        EdSessionTokenStore.remove()
        #expect(EdSessionTokenStore.hasToken == false)
    }

    @Test("a stored or launched Ed session is token-first, cookies second, else nil")
    func authenticationPrefersToken() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "state", .value: "v", .domain: "us.edstem.org", .path: "/",
        ]))

        if case .token(let value)? = EdDiscussionCoordinator.authentication(token: "t", cookies: [cookie]) {
            #expect(value == "t")
        } else {
            Issue.record("a token should win over cookies")
        }
        if case .cookies(let cookies)? = EdDiscussionCoordinator.authentication(token: nil, cookies: [cookie]) {
            #expect(cookies.count == 1)
        } else {
            Issue.record("cookies should be the fallback when there is no token")
        }
        // An empty token string is not a token.
        if case .cookies? = EdDiscussionCoordinator.authentication(token: "", cookies: [cookie]) {
        } else {
            Issue.record("an empty token should fall back to cookies")
        }
        #expect(EdDiscussionCoordinator.authentication(token: nil, cookies: []) == nil)
        #expect(EdDiscussionCoordinator.authentication(token: "", cookies: []) == nil)
    }

    @Test("EdSession's description never contains the token")
    func sessionDescriptionRedactsToken() {
        let session = EdSessionLauncher.EdSession(token: "super-secret-token", cookies: [])
        #expect(!session.description.contains("super-secret-token"))
        #expect(!"\(session)".contains("super-secret-token"))
        #expect(session.description.contains("present"))
    }

    @Test("SessionCookieStore.Service.allCases contains .ed")
    func edServiceIsInAllCases() {
        #expect(SessionCookieStore.Service.allCases.contains(.ed))
        #expect(SessionCookieStore.Service.ed.rawValue == "ed")
    }

    @Test("an Ed cookie never goes stale on a clock; Canvas and Gradescope still do at 24 hours")
    func staleness() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let twentyFiveHoursAgo = now.addingTimeInterval(-25 * 3600)
        let oneHourAgo = now.addingTimeInterval(-3600)
        let aMonthAgo = now.addingTimeInterval(-30 * 24 * 3600)

        #expect(SessionCookieStore.maxAge(for: .ed) == nil)
        #expect(!SessionCookieStore.isStale(capturedAt: twentyFiveHoursAgo, now: now, service: .ed))
        #expect(!SessionCookieStore.isStale(capturedAt: aMonthAgo, now: now, service: .ed))

        #expect(SessionCookieStore.isStale(capturedAt: twentyFiveHoursAgo, now: now, service: .canvas))
        #expect(!SessionCookieStore.isStale(capturedAt: oneHourAgo, now: now, service: .canvas))
        #expect(SessionCookieStore.isStale(capturedAt: twentyFiveHoursAgo, now: now, service: .gradescope))
        // The boundary is the old `< sessionCookieMaxAge` rule: exactly 24h is stale.
        #expect(SessionCookieStore.isStale(capturedAt: now.addingTimeInterval(-24 * 3600), now: now, service: .canvas))
    }

    @Test("isStale boundaries: 23h59m is fresh and 24h01m is stale for Canvas; Ed is fresh at both")
    func stalenessBoundaries() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let justUnder = now.addingTimeInterval(-(23 * 3600 + 59 * 60))
        let justOver = now.addingTimeInterval(-(24 * 3600 + 60))

        #expect(!SessionCookieStore.isStale(capturedAt: justUnder, now: now, service: .canvas))
        #expect(SessionCookieStore.isStale(capturedAt: justOver, now: now, service: .canvas))
        #expect(!SessionCookieStore.isStale(capturedAt: justUnder, now: now, service: .ed))
        #expect(!SessionCookieStore.isStale(capturedAt: justOver, now: now, service: .ed))
    }

    // MARK: - merge

    private static let t0 = Date(timeIntervalSince1970: 1_000)
    private static let t1 = Date(timeIntervalSince1970: 2_000)

    private static let course1 = CourseSummary(courseID: "1", code: "CIS 2400", name: "CIS 2400 Intro", url: nil)

    private func doc(_ course: String = "1", kind: CourseDocument.Kind, id: String, text: String, fetchedAt: Date) -> CourseDocument {
        CourseDocument(courseID: course, course: "CIS \(course)", kind: kind, sourceID: id, title: "Doc \(id)", url: nil, text: text, fetchedAt: fetchedAt)
    }

    private func base() -> CourseKnowledgeBase {
        CourseKnowledgeBase(
            courses: [Self.course1],
            documents: [
                doc(kind: .syllabus, id: "s", text: "syllabus", fetchedAt: Self.t0),
                doc(kind: .page, id: "p", text: "page", fetchedAt: Self.t0),
                doc(kind: .ed, id: "kept", text: "same", fetchedAt: Self.t0),
                doc(kind: .ed, id: "changed", text: "old", fetchedAt: Self.t0),
                doc(kind: .ed, id: "removed", text: "gone", fetchedAt: Self.t0),
                doc("2", kind: .ed, id: "other", text: "other course", fetchedAt: Self.t0),
            ],
            lastSyncedAt: Self.t0
        )
    }

    @Test("merging Ed documents keeps the course's other kinds, replaces changed Ed threads and drops removed ones")
    func mergePreservesOtherKinds() {
        var knowledge = base()
        let added = EdDiscussionCoordinator.mergeEdDocuments(
            [
                doc(kind: .ed, id: "kept", text: "same", fetchedAt: Self.t1),
                doc(kind: .ed, id: "changed", text: "new", fetchedAt: Self.t1),
                doc(kind: .ed, id: "fresh", text: "brand new", fetchedAt: Self.t1),
            ],
            into: &knowledge,
            course: Self.course1,
            now: Self.t1
        )
        let byID = Dictionary(uniqueKeysWithValues: knowledge.documents.map { ($0.id, $0) })

        // The reason the helper exists: `merge` treats what it is given as
        // the course's complete set, so the syllabus and page must survive.
        #expect(byID["syllabus:1:s"]?.fetchedAt == Self.t0)
        #expect(byID["page:1:p"]?.fetchedAt == Self.t0)

        #expect(byID["ed:1:kept"]?.fetchedAt == Self.t0)   // unchanged keeps its fetch time
        #expect(byID["ed:1:changed"]?.text == "new")
        #expect(byID["ed:1:fresh"] != nil)
        #expect(byID["ed:1:removed"] == nil)
        #expect(byID["ed:2:other"] != nil)                 // other course untouched
        #expect(added == 2)                                // changed + fresh, not kept
        #expect(knowledge.lastSyncedAt == Self.t0)         // the Canvas sync's clock is not advanced
        #expect(knowledge.courses == [Self.course1])
    }

    @Test("merging the same Ed documents twice adds nothing the second time")
    func mergeIsIdempotent() {
        var knowledge = base()
        let edDocs = [doc(kind: .ed, id: "kept", text: "same", fetchedAt: Self.t1)]
        _ = EdDiscussionCoordinator.mergeEdDocuments(edDocs, into: &knowledge, course: Self.course1, now: Self.t1)
        let snapshot = knowledge
        let added = EdDiscussionCoordinator.mergeEdDocuments(edDocs, into: &knowledge, course: Self.course1, now: Self.t1)
        #expect(added == 0)
        #expect(knowledge == snapshot)
    }

    @Test("an empty Ed result clears that course's Ed documents and nothing else")
    func emptyResultClearsOnlyEd() {
        var knowledge = base()
        _ = EdDiscussionCoordinator.mergeEdDocuments([], into: &knowledge, course: Self.course1, now: Self.t1)
        #expect(knowledge.documents.filter { $0.courseID == "1" }.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.page, .syllabus])
        #expect(knowledge.documents.contains { $0.id == "ed:2:other" })
    }

    @Test("restoring puts back Ed documents a Canvas resync dropped, only for known courses, without duplicates")
    func restoring() {
        let prior = [
            doc(kind: .ed, id: "a", text: "a", fetchedAt: Self.t0),
            doc(kind: .ed, id: "b", text: "b", fetchedAt: Self.t0),
            doc("9", kind: .ed, id: "stranger", text: "x", fetchedAt: Self.t0),
            doc(kind: .page, id: "p", text: "not ed", fetchedAt: Self.t0),
        ]
        // The collector kept "b" (somehow) and dropped "a".
        var knowledge = CourseKnowledgeBase(
            courses: [Self.course1],
            documents: [doc(kind: .syllabus, id: "s", text: "syllabus", fetchedAt: Self.t1),
                        doc(kind: .ed, id: "b", text: "b", fetchedAt: Self.t1)],
            lastSyncedAt: Self.t1
        )
        EdDiscussionCoordinator.restoringEdDocuments(prior, into: &knowledge, courseIDs: ["1"])
        let ids = knowledge.documents.map(\.id).sorted()
        #expect(ids == ["ed:1:a", "ed:1:b", "syllabus:1:s"])
        #expect(knowledge.documents.first { $0.id == "ed:1:b" }?.fetchedAt == Self.t1)
        #expect(knowledge.lastSyncedAt == Self.t1)
    }

    @Test("dropping removes only the named courses' Ed documents")
    func dropping() {
        var knowledge = base()
        EdDiscussionCoordinator.droppingEdDocuments(from: &knowledge, courseIDs: ["1"])
        let ids = Set(knowledge.documents.map(\.id))
        #expect(ids == ["syllabus:1:s", "page:1:p", "ed:2:other"])
        #expect(knowledge.lastSyncedAt == Self.t0)
        #expect(knowledge.documents.first { $0.id == "syllabus:1:s" }?.fetchedAt == Self.t0)

        // Nothing to drop is a no-op.
        let snapshot = knowledge
        EdDiscussionCoordinator.droppingEdDocuments(from: &knowledge, courseIDs: ["1"])
        #expect(knowledge == snapshot)
    }
}

/// What the Ed run does to a class's stored Ed documents when the run stops
/// early (2026-10-23). Until then a sign-out partway through the classes
/// left every class after it out of the matched set, so the drop rule
/// deleted their stored Ed documents. Pure: the network is a fake reader and
/// no store, Keychain or defaults is touched.
@Suite("Ed run: stopped early restores, never drops")
struct EdRunStopTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static let a = CourseSummary(courseID: "1", code: "CIS 1000", name: "A", url: nil)
    private static let b = CourseSummary(courseID: "2", code: "CIS 2000", name: "B", url: nil)
    private static let c = CourseSummary(courseID: "3", code: "CIS 3000", name: "C", url: nil)

    private static let targets = [
        EdDiscussionCoordinator.ReadTarget(edCourseID: 11, code: "CIS 1000", course: a),
        EdDiscussionCoordinator.ReadTarget(edCourseID: 12, code: "CIS 2000", course: b),
        EdDiscussionCoordinator.ReadTarget(edCourseID: 13, code: "CIS 3000", course: c),
    ]

    private static func doc(_ course: CourseSummary, kind: CourseDocument.Kind, id: String) -> CourseDocument {
        CourseDocument(
            courseID: course.courseID, course: course.code, kind: kind, sourceID: id,
            title: "Doc \(id)", url: nil, text: "text \(id)", fetchedAt: now
        )
    }

    /// The Ed documents the knowledge base held before the Canvas sync.
    private static let prior = [
        doc(a, kind: .ed, id: "oldA"),
        doc(b, kind: .ed, id: "oldB"),
        doc(c, kind: .ed, id: "oldC"),
    ]

    /// What the Canvas collector leaves behind: it re-fetched every course
    /// and, knowing nothing of Ed, dropped all their Ed documents.
    private static func collected() -> CourseKnowledgeBase {
        CourseKnowledgeBase(
            courses: [a, b, c],
            documents: [doc(a, kind: .syllabus, id: "s"), doc(b, kind: .syllabus, id: "s"), doc(c, kind: .syllabus, id: "s")],
            lastSyncedAt: now
        )
    }

    private static func freshResponse(edCourseID: Int) -> EdThreadsResponse {
        EdThreadsResponse(
            threads: [EdThread(
                id: 900, userID: 7, courseID: edCourseID, type: "announcement", title: "New",
                content: "<p>fresh</p>", isPrivate: false, createdAt: now.addingTimeInterval(-86_400)
            )],
            users: []
        )
    }

    /// A fake network: a result per Ed course id, and a record of who was asked.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private let results: [Int: Result<EdThreadsResponse, EdClient.Error>]
        private var askedStore: [Int] = []
        init(_ results: [Int: Result<EdThreadsResponse, EdClient.Error>]) { self.results = results }
        var asked: [Int] { lock.lock(); defer { lock.unlock() }; return askedStore }
        func read(_ id: Int) throws -> EdThreadsResponse {
            lock.lock(); askedStore.append(id); lock.unlock()
            return try (results[id] ?? .failure(.http(404))).get()
        }
    }

    /// The whole rule, as `perform` applies it after the reads.
    private static func run(_ reader: Reader) async -> (
        knowledge: CourseKnowledgeBase,
        tally: EdDiscussionCoordinator.ReadTally,
        plan: (drop: Set<String>, restore: Set<String>)
    ) {
        var knowledge = collected()
        let tally = await EdDiscussionCoordinator.readTargets(targets, knowledge: &knowledge, now: now) { id in
            try reader.read(id)
        }
        let matched = Set(targets.map { $0.course.courseID })
        let plan = EdDiscussionCoordinator.restoreDropPlan(allIDs: ["1", "2", "3"], matched: matched, read: tally.readIDs)
        EdDiscussionCoordinator.droppingEdDocuments(from: &knowledge, courseIDs: plan.drop)
        EdDiscussionCoordinator.restoringEdDocuments(prior, into: &knowledge, courseIDs: plan.restore)
        return (knowledge, tally, plan)
    }

    private func edIDs(_ knowledge: CourseKnowledgeBase) -> Set<String> {
        Set(knowledge.documents.filter { $0.kind == .ed }.map(\.id))
    }

    @Test("a sign-out on the second of three classes: the first is replaced, the second and third are restored, nothing is dropped")
    func signOutOnTheSecondClass() async {
        let reader = Reader([
            11: .success(Self.freshResponse(edCourseID: 11)),
            12: .failure(.sessionExpired),
            13: .success(Self.freshResponse(edCourseID: 13)),
        ])
        let result = await Self.run(reader)

        // The run stopped at the 401: the third class was never asked.
        #expect(reader.asked == [11, 12])
        #expect(result.tally.signedOutCode == "CIS 2000")
        #expect(result.tally.firstFailure == "sessionExpired")
        #expect(result.tally.readIDs == ["1"])

        #expect(result.plan.drop.isEmpty)
        #expect(result.plan.restore == ["2", "3"])

        // Class 1 holds the fresh thread and not its old one; classes 2 and
        // 3 hold exactly what they held before the run.
        #expect(edIDs(result.knowledge) == ["ed:1:900", "ed:2:oldB", "ed:3:oldC"])
        // The syllabi are untouched either way.
        #expect(result.knowledge.documents.filter { $0.kind == .syllabus }.count == 3)
    }

    @Test("the old rule would have dropped the unreached class: a plan built from the classes the loop reached deletes it")
    func theOldShapeDropped() {
        // Documents what the bug was, against the pure rule: when the matched
        // set holds only the classes reached before the break, class 3 lands
        // in `drop`.
        let reachedOnly: Set<String> = ["1", "2"]
        let plan = EdDiscussionCoordinator.restoreDropPlan(allIDs: ["1", "2", "3"], matched: reachedOnly, read: ["1"])
        #expect(plan.drop == ["3"])
    }

    @Test("a sign-out on the first class restores all three")
    func signOutOnTheFirstClass() async {
        let reader = Reader([11: .failure(.sessionExpired)])
        let result = await Self.run(reader)
        #expect(reader.asked == [11])
        #expect(result.plan.drop.isEmpty)
        #expect(result.plan.restore == ["1", "2", "3"])
        #expect(edIDs(result.knowledge) == ["ed:1:oldA", "ed:2:oldB", "ed:3:oldC"])
    }

    @Test("an ordinary failure on one class restores that class and the run goes on to the next")
    func ordinaryFailureContinues() async {
        let reader = Reader([
            11: .success(Self.freshResponse(edCourseID: 11)),
            12: .failure(.http(500)),
            13: .success(Self.freshResponse(edCourseID: 13)),
        ])
        let result = await Self.run(reader)
        #expect(reader.asked == [11, 12, 13])
        #expect(result.tally.signedOutCode == nil)
        #expect(result.tally.firstFailure == "http(500)")
        #expect(result.plan.restore == ["2"])
        #expect(result.plan.drop.isEmpty)
        #expect(edIDs(result.knowledge) == ["ed:1:900", "ed:2:oldB", "ed:3:900"])
    }

    @Test("a class with no Ed match is still dropped: that is Ed saying it has nothing")
    func unmatchedClassIsDropped() {
        let plan = EdDiscussionCoordinator.restoreDropPlan(allIDs: ["1", "2", "3"], matched: ["1", "2"], read: ["1", "2"])
        #expect(plan.drop == ["3"])
        #expect(plan.restore.isEmpty)
    }

    // MARK: status line

    @Test("the status line leads with the counts and the first failure's kind")
    func statusLineCounts() {
        let line = EdDiscussionCoordinator.statusLine(
            matched: 3, read: 1, restored: 2, dropped: 0,
            firstFailure: "sessionExpired", detail: "signed out; reconnecting next sync"
        )
        #expect(line == "matched 3 \u{00B7} read 1 \u{00B7} restored 2 \u{00B7} dropped 0 \u{00B7} first failure sessionExpired \u{00B7} signed out; reconnecting next sync")
    }

    @Test("with no failure the line has no failure part, and the counts survive the summary's length cap")
    func statusLineNoFailureAndCap() {
        let line = EdDiscussionCoordinator.statusLine(
            matched: 12, read: 12, restored: 12, dropped: 12, firstFailure: nil,
            detail: "connected: " + (0..<20).map { "CIS \(1000 + $0)" }.joined(separator: ", ")
        )
        #expect(line.hasPrefix("matched 12 \u{00B7} read 12 \u{00B7} restored 12 \u{00B7} dropped 12 \u{00B7} connected: "))
        #expect(!line.contains("first failure"))
        // Counts lead, so the cap cuts the class list and never the numbers.
        let scrubbed = AppState.scrubbedForSummary(line)
        #expect(scrubbed.hasPrefix("matched 12 \u{00B7} read 12 \u{00B7} restored 12 \u{00B7} dropped 12"))
    }

    @Test("failure kinds are fixed words and never a message")
    func failureKinds() {
        #expect(EdDiscussionCoordinator.failureKind(EdClient.Error.sessionExpired) == "sessionExpired")
        #expect(EdDiscussionCoordinator.failureKind(EdClient.Error.http(503)) == "http(503)")
        #expect(EdDiscussionCoordinator.failureKind(EdClient.Error.notHTTP) == "notHTTP")
        #expect(EdDiscussionCoordinator.failureKind(EdClient.Error.invalidJSON("a thread body")) == "invalidJSON")
        #expect(EdDiscussionCoordinator.failureKind(URLError(.notConnectedToInternet)) == "other")
    }

    @Test("a report's counts start at zero with no failure")
    func reportDefaults() {
        let report = EdDiscussionCoordinator.Report(statusLine: "")
        #expect(report.matchedClasses == 0 && report.readClasses == 0)
        #expect(report.restoredClasses == 0 && report.droppedClasses == 0)
        #expect(report.firstFailure == nil)
    }
}
