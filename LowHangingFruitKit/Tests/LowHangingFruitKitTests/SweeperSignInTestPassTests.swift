import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// The hostile test pass of 2026-11-22 over the Sweeper accuracy work and the
// Duo work (`docs/TEST_SWEEPER_SIGNIN_2026-11-22.md`). Each suite pins one
// finding of that report by its number. Nothing here touches the network,
// WebKit, the Keychain or the real App Group container.

/// Source files read by the scans below, from the package root.
private enum TestPassSources {
    static var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }
    static var repoRoot: URL { packageRoot.deletingLastPathComponent() }

    static func ui(_ name: String) throws -> String {
        try HardeningSourceScan.codeOnly(String(
            contentsOf: packageRoot.appendingPathComponent("Sources/LowHangingFruitUI/\(name)"), encoding: .utf8))
    }

    static func repo(_ path: String) throws -> String {
        try HardeningSourceScan.codeOnly(String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8))
    }
}

// MARK: - H1: a plain assignment's planner row is keyed by plannable_id

@Suite("Test pass 2026-11-22: planner ids (H1)")
struct TestPassPlannerIDTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func decode(_ json: String) -> [CanvasPlannerItem] {
        CanvasStructuredDecoding.decode(CanvasPlannerItem.self, fromPages: [Data(json.utf8)]).elements
    }

    @Test("a plain assignment, as Canvas sends it (no plannable.assignment_id), produces a read keyed by plannable_id")
    func plainAssignment() {
        // The shape Canvas's planner returns for an assignment: the id is
        // `plannable_id` (and `plannable.id`); `assignment_id` is a quiz's and
        // a graded discussion's field, absent here.
        let items = decode("""
        [{"plannable_type":"assignment","plannable_id":55,"course_id":7,
          "html_url":"/courses/7/assignments/55",
          "plannable":{"id":55,"title":"PSet 7","due_at":"2026-11-18T16:00:00Z","points_possible":10},
          "submissions":{"submitted":true,"graded":false}}]
        """)
        let reads = SubmissionRead.verdicts(fromPlanner: items, readAt: at)
        #expect(reads.count == 1)
        #expect(reads.first?.assignmentID == "55")
        #expect(reads.first?.verdict == .submitted)
        #expect(reads.first?.cancels == true)
    }

    @Test("the extension's decision sees the same read: a submitted plain assignment cancels its own entry")
    func throughSweepCheck() {
        let items = decode("""
        [{"plannable_type":"assignment","plannable_id":55,"course_id":7,
          "plannable":{"id":55,"title":"PSet 7"},"submissions":{"submitted":true}}]
        """)
        let reads = SubmissionRead.verdicts(fromPlanner: items, readAt: at)
        let alarm = UUID()
        let entry = SweepManifest.Entry(itemID: "event-assignment-55", canvasAssignmentID: "55", title: "PSet 7",
                                        fireDate: at, alarmIDs: [alarm], requestIDs: ["due:x:600"])
        let other = SweepManifest.Entry(itemID: "event-assignment-56", canvasAssignmentID: "56", title: "PSet 8",
                                        fireDate: at, alarmIDs: [UUID()], requestIDs: ["due:y:600"])
        let outcome = SweepCheck.decide(entries: [entry, other], reads: reads, honourProbe: false)
        #expect(outcome.submitted == [entry])
        #expect(outcome.unknown == [other])
        #expect(outcome.alarmIDsToCancel == [alarm])
        #expect(outcome.requestIDsToRemove == ["due:x:600"])
    }

    @Test("a quiz is keyed by the assignment that backs it, never by its own quiz id")
    func quiz() {
        let items = decode("""
        [{"plannable_type":"quiz","plannable_id":777,"course_id":7,
          "plannable":{"id":777,"title":"Quiz 3","assignment_id":901},"submissions":{"submitted":true}},
         {"plannable_type":"quiz","plannable_id":778,"course_id":7,
          "plannable":{"id":778,"title":"Quiz 4"},"submissions":{"submitted":true}}]
        """)
        let reads = SubmissionRead.verdicts(fromPlanner: items, readAt: at)
        #expect(reads.map(\.assignmentID) == ["901"])
        #expect(!reads.contains { $0.assignmentID == "777" || $0.assignmentID == "778" })
    }

    @Test("a graded discussion is keyed by its assignment; an ungraded one, a page and a note give no read")
    func otherTypes() {
        let items = decode("""
        [{"plannable_type":"discussion_topic","plannable_id":10,"plannable":{"assignment_id":300},"submissions":{"submitted":true}},
         {"plannable_type":"discussion_topic","plannable_id":11,"plannable":{"title":"Chat"},"submissions":{"submitted":true}},
         {"plannable_type":"wiki_page","plannable_id":12,"plannable":{"title":"Notes"},"planner_override":{"marked_complete":true}},
         {"plannable_type":"planner_note","plannable_id":13,"plannable":{"title":"todo"},"planner_override":{"marked_complete":true}},
         {"plannable_type":"calendar_event","plannable_id":14,"plannable":{"title":"Lecture"}}]
        """)
        let reads = SubmissionRead.verdicts(fromPlanner: items, readAt: at)
        #expect(reads.map(\.assignmentID) == ["300"])
    }

    @Test("the resolver agrees with the structured run's own rule, type by type")
    func resolverTable() {
        func item(_ type: String, plannable: String?, assignment: String?) -> CanvasPlannerItem {
            CanvasPlannerItem(plannableType: type, plannableID: plannable, assignmentID: assignment)
        }
        #expect(SubmissionRead.canvasAssignmentID(of: item("assignment", plannable: "55", assignment: nil)) == "55")
        #expect(SubmissionRead.canvasAssignmentID(of: item("assignment", plannable: "55", assignment: "55")) == "55")
        #expect(SubmissionRead.canvasAssignmentID(of: item("assignment", plannable: nil, assignment: "55")) == "55")
        #expect(SubmissionRead.canvasAssignmentID(of: item("quiz", plannable: "777", assignment: "901")) == "901")
        #expect(SubmissionRead.canvasAssignmentID(of: item("quiz", plannable: "777", assignment: nil)) == nil)
        #expect(SubmissionRead.canvasAssignmentID(of: item("discussion_topic", plannable: "10", assignment: nil)) == nil)
        #expect(SubmissionRead.canvasAssignmentID(of: item("wiki_page", plannable: "12", assignment: nil)) == nil)
        #expect(SubmissionRead.canvasAssignmentID(of: item("planner_note", plannable: "13", assignment: nil)) == nil)
        // An unknown or differently cased type is not an assignment.
        #expect(SubmissionRead.canvasAssignmentID(of: item("Assignment", plannable: "55", assignment: nil)) == nil)
        #expect(SubmissionRead.canvasAssignmentID(of: item("", plannable: "55", assignment: nil)) == nil)
    }
}

/// H1 end to end on the phone side: the applier marks the ledger row done and
/// reaches the canceller from a plain assignment's planner row.
@MainActor
@Suite("Test pass 2026-11-22: planner apply with a plain assignment (H1)")
struct TestPassPlannerApplyTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!

    private final class Seen: @unchecked Sendable { var calls: [(Set<String>, WakeSource)] = [] }

    private func rig() throws -> (AppState, Assignment, Seen, String) {
        let suite = "TestPassPlannerApplyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let row = Assignment(
            source: .canvas, sourceID: "event-assignment-55", kind: .assignment,
            course: "STRW 0151", title: "PSet 55", dueAt: now.addingTimeInterval(3600),
            url: URL(string: "https://canvas.upenn.edu/courses/7/assignments/55"))
        let store = try AssignmentStore(inMemory: true)
        store.upsert([row])
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.structuredDefaults = defaults
        state.sweeperCountsDefaults = defaults
        let seen = Seen()
        state.submissionCanceller = { ids, source in seen.calls.append((ids, source)) }
        return (state, row, seen, suite)
    }

    @Test("a plain assignment row (plannable_id only) completes the card and cancels at observation")
    func plainAssignmentCancels() async throws {
        let (state, row, seen, suite) = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let item = CanvasPlannerItem(plannableType: "assignment", plannableID: "55", submitted: true)
        let reads = state.applyPlannerWindow(PlannerWindowResult(items: [item], completed: true), now: now)
        #expect(reads.map(\.verdict) == [.submitted])
        #expect(state.structuredCompletedItemIDs.contains(row.id))
        for _ in 0..<200 where seen.calls.isEmpty { await Task.yield() }
        #expect(seen.calls.count == 1)
        #expect(seen.calls.first?.0.contains(row.id) == true)
        #expect(seen.calls.first?.0.contains("55") == true)
        #expect(seen.calls.first?.1 == .poll)
    }

    @Test("a quiz row whose quiz id happens to equal an assignment id never completes that assignment")
    func quizIDSpace() async throws {
        let (state, row, seen, suite) = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let quiz = CanvasPlannerItem(plannableType: "quiz", plannableID: "55", submitted: true)
        let reads = state.applyPlannerWindow(PlannerWindowResult(items: [quiz], completed: true), now: now)
        #expect(reads.isEmpty)
        #expect(!state.structuredCompletedItemIDs.contains(row.id))
        for _ in 0..<50 { await Task.yield() }
        #expect(seen.calls.isEmpty)
    }
}

// MARK: - Hostile planner payloads never read as submitted

@Suite("Test pass 2026-11-22: hostile planner payloads")
struct TestPassHostilePlannerTests {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func reads(_ json: String) -> [SubmissionRead] {
        let items = CanvasStructuredDecoding.decode(CanvasPlannerItem.self, fromPages: [Data(json.utf8)]).elements
        return SubmissionRead.verdicts(fromPlanner: items, readAt: at)
    }

    @Test("a submitted flag that is not a JSON boolean is unknown, never submitted and never unsubmitted",
          arguments: [
            #""submitted":"true""#, #""submitted":1"#, #""submitted":null"#, #""submitted":"yes""#,
            #""submitted":[true]"#, #""submitted":{"value":true}"#, #""submitted":0"#, #""submitted":"false""#,
          ])
    func submittedShapes(flag: String) {
        let r = reads(#"[{"plannable_type":"assignment","plannable_id":55,"plannable":{"id":55},"submissions":{\#(flag)}}]"#)
        #expect(r.map(\.verdict) == [.unknown])
        #expect(r.allSatisfy { !$0.cancels })
    }

    @Test("a submissions, plannable or override that is the wrong shape is unknown",
          arguments: [
            #""submissions":null"#, #""submissions":[]"#, #""submissions":true"#, #""submissions":"submitted""#,
            #""planner_override":{"marked_complete":"true"}"#, #""planner_override":{"marked_complete":1}"#,
            #""planner_override":[true]"#, #""submissions":{"excused":"true"}"#, #""submissions":{"excused":1}"#,
            #""submissions":{"graded":true}"#, #""submissions":{"missing":false}"#,
          ])
    func wrongShapes(field: String) {
        let r = reads(#"[{"plannable_type":"assignment","plannable_id":55,"plannable":{"id":55},\#(field)}]"#)
        #expect(r.map(\.verdict) == [.unknown])
    }

    @Test("ids of the wrong kind never resolve onto a real one")
    func hostileIDs() {
        // A fractional, negative, empty or boolean id is not "55".
        let r = reads("""
        [{"plannable_type":"assignment","plannable_id":55.5,"submissions":{"submitted":true}},
         {"plannable_type":"assignment","plannable_id":-55,"submissions":{"submitted":true}},
         {"plannable_type":"assignment","plannable_id":"","submissions":{"submitted":true}},
         {"plannable_type":"assignment","plannable_id":true,"submissions":{"submitted":true}},
         {"plannable_type":"assignment","plannable_id":"55 ","submissions":{"submitted":true}},
         {"plannable_type":"quiz","plannable_id":55,"plannable":{"assignment_id":true},"submissions":{"submitted":true}},
         {"plannable_type":"quiz","plannable_id":55,"plannable":{"assignment_id":1e300},"submissions":{"submitted":true}}]
        """)
        #expect(!r.contains { $0.assignmentID == "55" })
        // Whatever they did resolve to, each is at least well formed.
        #expect(r.allSatisfy { $0.source == .planner && $0.readAt == at })
    }

    @Test("a page that is not an array, or has junk among the rows, yields no false read")
    func junkPages() {
        #expect(reads(#"{"plannable_type":"assignment","plannable_id":55,"submissions":{"submitted":true}}"#).isEmpty)
        #expect(reads("null").isEmpty)
        #expect(reads("").isEmpty)
        let r = reads(#"[1, null, "x", {"plannable_type":"assignment","plannable_id":55,"submissions":{"submitted":false}}]"#)
        #expect(r.map(\.verdict) == [.unsubmitted])
    }

    @Test("two rows for one assignment: a submitted one wins for the apply, and nothing partial is believed")
    func duplicateRows() {
        let r = reads("""
        [{"plannable_type":"assignment","plannable_id":55,"submissions":{"submitted":false}},
         {"plannable_type":"assignment","plannable_id":55,"submissions":{"submitted":true}}]
        """)
        #expect(r.map(\.verdict) == [.unsubmitted, .submitted])
        let entry = SweepManifest.Entry(itemID: "i", canvasAssignmentID: "55", title: "t", fireDate: at,
                                        alarmIDs: [UUID()], requestIDs: [])
        #expect(SweepCheck.decide(entries: [entry], reads: r, honourProbe: false).submitted == [entry])
        // The extension believes nothing from a page that was cut short, rate
        // limited or answered to an expired session: the service passes nil.
        #expect(SweepCheck.decide(entries: [entry], reads: nil, honourProbe: false).alarmIDsToCancel.isEmpty)
    }
}

// MARK: - M1: every live cookie read warms the store first

@Suite("Test pass 2026-11-22: the live cookie read warms the store (M1)")
struct TestPassCookieWarmTests {
    @Test("canvasCookies(forHost:) attaches a web view to the store before asking it for cookies")
    func warmBeforeRead() throws {
        let code = try TestPassSources.ui("AutoSyncCoordinator.swift")
        let body = try HardeningSourceScan.body(ofFunctionDeclaredWith: "static func canvasCookies(forHost", in: code)
        let warm = try #require(body.range(of: "LoginDataStores.warmCanvasStore()"))
        let read = try #require(body.range(of: "httpCookieStore.getAllCookies"))
        #expect(warm.lowerBound < read.lowerBound)
    }

    @Test("the warm is a no-op under the test runner, so this suite opened no WebKit process")
    @MainActor
    func inertUnderTests() {
        LoginDataStores.warmCanvasStore()
        #expect(SharedDefaults.isTestRunner)
    }
}

// MARK: - L1: a forced Duo-trust renewal is not "slow connection · reconnecting"

@Suite("Test pass 2026-11-22: the status line during a forced renewal (L1)")
struct TestPassForcedStatusLineTests {
    private func line(forced: Bool, pushSent: Bool = false, seconds: TimeInterval = 10) -> AppState.CanvasSessionStatusLine {
        AppState.canvasSessionStatusLine(
            renewalInFlight: true, inFlightFor: seconds, duoPushSent: pushSent, awaitingDuo: false,
            passwordRejected: false, loginMissing: false, hasSavedCredentials: true,
            sessionExpired: false, saveFailed: false, forcedRenewal: forced)
    }

    @Test("ten seconds into an ordinary renewal: reconnecting; into a forced one: nothing")
    func forcedIsSilent() {
        #expect(line(forced: false) == .reconnecting)
        #expect(line(forced: true) == .none)
        #expect(line(forced: true, seconds: 120) == .none)
    }

    @Test("a push the forced attempt sent is still the student's to approve")
    func pushStillShown() {
        #expect(line(forced: true, pushSent: true) == .duoPush)
    }

    @Test("the state passes its own forced flag, set at the start and cleared at the end of an attempt")
    func wiring() throws {
        let code = try TestPassSources.ui("AppState.swift")
        let caller = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func canvasSessionStatusLine(at now: Date", in: code)
        #expect(caller.contains("forcedRenewal: silentRenewalIsForced"))
        let start = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func startSilentCanvasRenewal(cooldown:", in: code)
        #expect(start.contains("silentRenewalIsForced = forceReauthentication"))
        let finish = try HardeningSourceScan.body(ofFunctionDeclaredWith: "private func finishSilentCanvasRenewal(", in: code)
        #expect(finish.contains("silentRenewalIsForced = false"))
    }
}

// MARK: - L2: no copy of the login is kept while nothing is armed

@MainActor
@Suite("Test pass 2026-11-22: the handoff with nothing armed (L2)")
struct TestPassEmptyHandoffTests {
    private let now = ISO8601DateFormatter().date(from: "2026-11-18T15:00:00Z")!

    private func rig() throws -> (AppState, Assignment, URL, String) {
        let suite = "TestPassEmptyHandoffTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let row = Assignment(source: .canvas, sourceID: "event-assignment-55", kind: .assignment, course: "STRW 0151",
                             title: "PSet 55", dueAt: now.addingTimeInterval(7200),
                             url: URL(string: "https://canvas.upenn.edu/courses/7/assignments/55"))
        let store = try AssignmentStore(inMemory: true)
        store.upsert([row])
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.structuredDefaults = defaults
        state.sweeperCountsDefaults = defaults
        state.submissionCanceller = { _, _ in }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (state, row, dir, suite)
    }

    @Test("an empty plan deletes the manifest instead of writing an empty one")
    func emptyPlan() async throws {
        let (state, row, dir, suite) = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: dir) }
        let planned = PlannedAlarm(id: UUID(), assignmentID: row.id, fireDate: now.addingTimeInterval(600),
                                   title: row.title, course: row.course, dueAt: row.dueAt ?? now, link: nil)
        await state.writeSweepHandoff(plan: [planned], wakeReachable: true, directory: dir, canvasConnected: true, now: now)
        #expect(SweepFiles.loadManifest(in: dir)?.entries.count == 1)
        await state.writeSweepHandoff(plan: [], wakeReachable: true, directory: dir, canvasConnected: true, now: now)
        #expect(SweepFiles.loadManifest(in: dir) == nil)
    }

    @Test("the cookie copy goes with it (the Keychain call is inert here, so the source is read)")
    func copyGoesToo() throws {
        let code = try TestPassSources.ui("AppState+SweepHandoff.swift")
        let body = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func writeSweepHandoff(", in: code)
        let guardRange = try #require(body.range(of: "guard !entries.isEmpty else {"))
        let tail = body[guardRange.upperBound...]
        let close = try #require(tail.range(of: "}"))
        let block = tail[..<close.lowerBound]
        #expect(block.contains("SweepCookieMirror.deleteAll()"))
        #expect(block.contains("SweepFiles.deleteManifest(in: directory)"))
        // And the copy is still only ever written after the manifest, from the
        // live-merged jar, never from an empty one.
        let save = try #require(body.range(of: "SweepCookieMirror.save(cookies: cookies"))
        let emptyGuard = try #require(body.range(of: "if !cookies.isEmpty {"))
        #expect(emptyGuard.lowerBound < save.lowerBound)
        #expect(guardRange.lowerBound < save.lowerBound)
    }
}

// MARK: - The DEBUG traces of this week's files carry words and counts only

@Suite("Test pass 2026-11-22: trace lines")
struct TestPassTraceTests {
    /// A log statement is one call, possibly continued over lines joined by
    /// `+`; this gathers the call's text up to its closing line.
    private func statements(matching call: String, in code: String) -> [String] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if lines[i].contains(call) {
                var text = lines[i]
                var depth = lines[i].filter { $0 == "(" }.count - lines[i].filter { $0 == ")" }.count
                var j = i + 1
                while depth > 0, j < lines.count {
                    text += "\n" + lines[j]
                    depth += lines[j].filter { $0 == "(" }.count - lines[j].filter { $0 == ")" }.count
                    j += 1
                }
                out.append(text)
            }
            i += 1
        }
        return out
    }

    @Test("no wake, sweep or renewal trace in the files under test interpolates a title, an id, a URL or a cookie",
          arguments: [
            "LowHangingFruitKit/Sources/LowHangingFruitUI/LastHourPoller.swift",
            "LowHangingFruitKit/Sources/LowHangingFruitUI/AppState+LastHourPoll.swift",
            "LowHangingFruitKit/Sources/LowHangingFruitUI/AppState+SweepHandoff.swift",
            "LowHangingFruitKit/Sources/LowHangingFruitUI/AppState+SweeperWake.swift",
            "LowHangingFruitKit/Sources/LowHangingFruitUI/DuoWaitNotice.swift",
            "LowHangingFruitKit/Sources/LowHangingFruitUI/BackgroundRefresh.swift",
            "LHFSweeperCheck/NotificationService.swift",
          ])
    func traces(path: String) throws {
        let code = try TestPassSources.repo(path)
        let calls = ["DebugWakeLog.record(", "DebugRenewalLog.record(", "SweepDebugLog.append(", "log(\"", "print("]
        let forbidden = ["title", "canvasAssignmentID", "itemID", ".url", "URL(", "cookies[", ".value", "assignmentID:",
                         "manifest.canvasBaseURL", "\\(id)", "\\(ids"]
        for call in calls {
            for statement in statements(matching: call, in: code) {
                for word in forbidden {
                    #expect(!statement.contains(word), "\(path): a trace carries \(word): \(statement)")
                }
            }
        }
    }

    @Test("the Duo trust check's words are a fixed vocabulary plus day counts")
    func duoTrustWords() throws {
        let code = try TestPassSources.ui("AppState.swift")
        let body = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func renewDuoTrustIfDue(now: Date", in: code)
        for statement in statements(matching: "DebugRenewalLog.record(", in: body) {
            for word in ["password", "credential.", "cookie.", "name", "value", ".host"] {
                #expect(!statement.contains(word), "\(statement)")
            }
        }
    }
}

// MARK: - Rules re-pinned from the pass that did not need a change

@Suite("Test pass 2026-11-22: unchanged rules, re-pinned")
struct TestPassUnchangedRulesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the poller backs off on a nil read and never arms, disarms or counts a poll for it")
    @MainActor
    func nilReadBacksOff() async {
        let suite = "TestPassUnchangedRulesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        final class Clock { var now: Date; init(_ d: Date) { now = d } }
        let clock = Clock(now)
        let poller = LastHourPoller(clock: { clock.now }, countsDefaults: defaults, log: { _ in })
        let ring = now.addingTimeInterval(1800)
        var fetches = 0
        let d1 = await poller.tick(nextRing: ring) { _ in fetches += 1; return nil }
        #expect(d1 == .poll)
        clock.now = now.addingTimeInterval(61)
        let d2 = await poller.tick(nextRing: ring) { _ in fetches += 1; return nil }
        if case .wait = d2 {} else { Issue.record("expected a wait during the back-off") }
        #expect(fetches == 1)
        #expect(SweeperCounts.snapshot(defaults: defaults)[SweeperCounts.polls] == nil)
        #expect(SweeperCounts.snapshot(defaults: defaults)[SweeperCounts.pollsBackedOff] == nil)
    }

    @Test("the missed-push notice never fires over a live session, a cleared latch or a latch in the future")
    func noticeGuards() {
        let latch = now.addingTimeInterval(-2 * 3600)
        #expect(DuoWaitNotice.shouldPost(awaitingDuo: true, sessionExpired: true, latchedAt: latch, now: now,
                                         postedForLatchAt: nil, fixtureData: false))
        #expect(!DuoWaitNotice.shouldPost(awaitingDuo: true, sessionExpired: false, latchedAt: latch, now: now,
                                          postedForLatchAt: nil, fixtureData: false))
        #expect(!DuoWaitNotice.shouldPost(awaitingDuo: false, sessionExpired: true, latchedAt: latch, now: now,
                                          postedForLatchAt: nil, fixtureData: false))
        #expect(!DuoWaitNotice.shouldPost(awaitingDuo: true, sessionExpired: true, latchedAt: nil, now: now,
                                          postedForLatchAt: nil, fixtureData: false))
        #expect(!DuoWaitNotice.shouldPost(awaitingDuo: true, sessionExpired: true, latchedAt: now.addingTimeInterval(60),
                                          now: now, postedForLatchAt: nil, fixtureData: false))
        #expect(!DuoWaitNotice.shouldPost(awaitingDuo: true, sessionExpired: true, latchedAt: latch, now: now,
                                          postedForLatchAt: latch, fixtureData: false))
    }

    @Test("a forced attempt that times out, is refused or is aborted is handled as any attempt: nothing latched")
    @MainActor
    func forcedOtherOutcomes() {
        for outcome in [CanvasSessionRenewer.Outcome.timedOut, .notAttempted(reason: "gated"), .abortedByLoginPane] {
            let state = AppState()
            state.disablePersistenceForTesting()
            let expiredBefore = state.canvasSessionExpired
            state.noteRenewalOutcomeForTesting(outcome, forced: true)
            #expect(!state.autoLoginAwaitingDuo)
            #expect(state.autoLoginDisabledReason == nil)
            #expect(state.canvasSessionExpired == expiredBefore)
            #expect(!state.silentRenewalCannotProceed)
        }
    }

    @Test("the cookie copy keeps the Canvas host's cookies and no other host's")
    func mirrorScope() {
        func cookie(_ name: String, _ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: name, .value: "v", .domain: domain, .path: "/"])!
        }
        let data = SweepCookieMirror.encode([
            cookie("a", "canvas.upenn.edu"), cookie("b", ".upenn.edu"), cookie("c", "duosecurity.com"),
            cookie("d", "sso.canvaslms.com"), cookie("e", "idp.pennkey.upenn.edu"), cookie("f", "notcanvas.upenn.edu"),
        ], host: "canvas.upenn.edu")
        let kept = Set(SweepCookieMirror.decode(data).map(\.name))
        #expect(kept == ["a", "b"])
    }
}
