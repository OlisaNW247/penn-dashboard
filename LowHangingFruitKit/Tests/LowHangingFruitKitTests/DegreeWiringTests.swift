import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Records what a fake network was asked, in order, and answers from a closure.
/// A lock instead of an actor because the client's `fetch` is `@Sendable` and
/// the tests read the log after the awaits have finished.
private final class FakeNetwork: @unchecked Sendable {
    struct Seen: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private let lock = NSLock()
    private var log: [Seen] = []
    private let answer: @Sendable (Seen) -> (Int, String)

    init(_ answer: @escaping @Sendable (Seen) -> (Int, String)) {
        self.answer = answer
    }

    var seen: [Seen] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    var client: DegreeWorksClient { makeClient() }

    /// Synchronous on purpose: `NSLock` may not be taken directly inside an
    /// async closure under Swift 6, but may inside a plain method.
    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let entry = Seen(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            headers: request.allHTTPHeaderFields ?? [:]
        )
        lock.lock(); log.append(entry); lock.unlock()
        let (status, body) = answer(entry)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func makeClient(log logLine: @escaping @Sendable (String) -> Void = { _ in }) -> DegreeWorksClient {
        DegreeWorksClient(fetch: { [self] request in
            try respond(to: request)
        }, log: logLine)
    }
}

private let auditBody = """
{"auditHeader":{"percentComplete":50},"blockArray":[{"requirementId":"RA1","requirementType":"MAJOR","requirementValue":"CIS","title":"Computer Science","percentComplete":50,"ruleArray":[]}]}
"""

/// A structurally valid JWT (unsigned) whose subject and expiry the Kit reads.
private func fakeTokens(now: Date = Date()) -> DegreeWorksTokens {
    func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let exp = Int(now.timeIntervalSince1970) + 3600
    let jwt = "\(b64url("{\"alg\":\"none\"}")).\(b64url("{\"sub\":\"S0000001\",\"exp\":\(exp)}")).sig"
    return DegreeWorksTokens(authToken: jwt, refreshToken: "refresh-secret-value")
}

@Suite("Degree progress: when a read runs")
struct DegreeRefreshRuleTests {
    @Test("the rule needs Penn, the flag, no fixtures, the foreground, and stale or forced")
    func truthTable() {
        func rule(
            penn: Bool = true, flag: Bool = true, fixture: Bool = false,
            foreground: Bool = true, stale: Bool = true, force: Bool = false
        ) -> Bool {
            AppState.shouldRefreshDegree(
                isPenn: penn, flag: flag, fixture: fixture,
                isForeground: foreground, stale: stale, force: force
            )
        }
        #expect(rule())
        #expect(rule(stale: false, force: true))
        #expect(!rule(stale: false))
        #expect(!rule(penn: false))
        #expect(!rule(flag: false))
        #expect(!rule(fixture: true))
        #expect(!rule(foreground: false))
        #expect(!rule(penn: false, force: true))
        #expect(!rule(foreground: false, force: true))
    }

    @Test("a read is stale after twelve hours, and when there never was one")
    func staleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AppState.degreeIsStale(readAt: nil, now: now))
        #expect(!AppState.degreeIsStale(readAt: now.addingTimeInterval(-11 * 3600), now: now))
        #expect(AppState.degreeIsStale(readAt: now.addingTimeInterval(-12 * 3600), now: now))
    }
}

@Suite("Degree progress: status words")
struct DegreeStatusLineTests {
    @Test("each status says exactly its words")
    func words() {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 15))!
        let earlierToday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 6))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 22))!
        let nov7 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!

        #expect(DegreeStatus.idle.line(now: now) == nil)
        #expect(DegreeStatus.reading.line(now: now) == "reading path@penn…")
        #expect(DegreeStatus.waitingForDuo.line(now: now) == "approve the duo push on this phone")
        #expect(DegreeStatus.needsCanvasSignIn.line(now: now) == "sign in to canvas")
        #expect(DegreeStatus.needsGoals.line(now: now) == "pick your degree")
        #expect(DegreeStatus.failed("couldn't read path@penn · retry").line(now: now) == "couldn't read path@penn · retry")
        #expect(DegreeStatus.read(earlierToday).line(now: now) == "read today")
        #expect(DegreeStatus.read(yesterday).line(now: now) == "read yesterday")
        #expect(DegreeStatus.read(nov7).line(now: now) == "read nov 7")
    }

    @Test("the failure line is the spec's words")
    func failureWords() {
        #expect(AppState.degreeFailedLine == "couldn't read path@penn · retry")
    }
}

@Suite("Degree progress: the client")
struct DegreeWorksClientTests {
    private let now = Date()

    @Test("every request carries the cookie, origin, host, accept and requested-with headers, and no log line holds a token")
    func headersAndLogs() async throws {
        let tokens = fakeTokens()
        let net = FakeNetwork { _ in (200, auditBody) }
        let logLines = LogBox()
        let client = net.makeClient(log: { logLines.add($0) })
        let audit = try await client.fetchAudit(
            tokens: tokens, goals: DegreeGoals(school: "UG", degree: "BSE", majors: ["CIS"]),
            keepCurriculum: false, isWhatIf: true, now: now
        )
        #expect(audit.isWhatIf)
        let headers = try #require(net.seen.first?.headers)
        #expect(headers["Cookie"] == tokens.cookieHeader)
        #expect(headers["Origin"] == DegreeWorksEndpoints.baseURL.absoluteString)
        #expect(headers["Host"] == "\(DegreeWorksEndpoints.host):\(DegreeWorksEndpoints.port)")
        #expect(headers["X-Requested-With"] == "XMLHttpRequest")
        #expect(headers["Accept"] != nil)
        for line in logLines.lines {
            #expect(!line.contains(tokens.authToken))
            #expect(!line.contains("refresh-secret-value"))
            #expect(!line.contains("S0000001"))
        }
    }

    @Test("a 401 or 403 is tokensRejected")
    func rejected() async {
        for status in [401, 403] {
            let net = FakeNetwork { _ in (status, "") }
            do {
                _ = try await net.client.fetchCurrentAudit(tokens: fakeTokens(), now: now)
                Issue.record("expected a throw")
            } catch {
                #expect(error as? DegreeWorksClient.Failure == .tokensRejected)
            }
        }
    }

    @Test("when the student record names a degree the audit is a GET")
    func studentFirst() async throws {
        let net = FakeNetwork { seen in
            if seen.path == DegreeWorksEndpoints.studentPath {
                return (200, #"{"school":"UG","degree":"BSE","catalogYear":"2025"}"#)
            }
            return (200, auditBody)
        }
        let audit = try await net.client.fetchCurrentAudit(tokens: fakeTokens(), now: now)
        #expect(!audit.isWhatIf)
        let order = net.seen.map { "\($0.method) \($0.path)" }
        #expect(order == [
            "GET \(DegreeWorksEndpoints.studentPath)",
            "GET \(DegreeWorksEndpoints.auditPath)",
        ])
    }

    @Test("with no usable student record the keep-curriculum POST is next")
    func postFallback() async throws {
        let net = FakeNetwork { seen in
            seen.path == DegreeWorksEndpoints.studentPath ? (404, "") : (200, auditBody)
        }
        _ = try await net.client.fetchCurrentAudit(tokens: fakeTokens(), now: now)
        let order = net.seen.map { "\($0.method) \($0.path)" }
        #expect(order == [
            "GET \(DegreeWorksEndpoints.studentPath)",
            "POST \(DegreeWorksEndpoints.auditPath)",
        ])
    }

    @Test("a 400, 404 or 422 on the POST means the student has to pick a degree")
    func needsGoals() async {
        for status in [400, 404, 422] {
            let net = FakeNetwork { seen in
                seen.path == DegreeWorksEndpoints.studentPath ? (404, "") : (status, "")
            }
            do {
                _ = try await net.client.fetchCurrentAudit(tokens: fakeTokens(), now: now)
                Issue.record("expected a throw")
            } catch {
                #expect(error as? DegreeWorksClient.Failure == .needsGoals)
            }
        }
    }

    @Test("a body that is not an audit is a decode failure, and a server error is http")
    func otherFailures() async {
        let bad = FakeNetwork { seen in
            seen.path == DegreeWorksEndpoints.studentPath ? (404, "") : (200, "<html></html>")
        }
        do {
            _ = try await bad.client.fetchCurrentAudit(tokens: fakeTokens(), now: now)
            Issue.record("expected a throw")
        } catch {
            #expect(error as? DegreeWorksClient.Failure == .decode)
        }
        let down = FakeNetwork { seen in
            seen.path == DegreeWorksEndpoints.studentPath ? (404, "") : (503, "")
        }
        do {
            _ = try await down.client.fetchCurrentAudit(tokens: fakeTokens(), now: now)
            Issue.record("expected a throw")
        } catch {
            #expect(error as? DegreeWorksClient.Failure == .http(503))
        }
    }

    @Test("the shape callback gets key names and never a value")
    func shapeHasNoValues() async throws {
        let net = FakeNetwork { _ in (200, auditBody) }
        let box = LogBox()
        _ = try await net.client.fetchAudit(
            tokens: fakeTokens(), goals: DegreeGoals(), keepCurriculum: true, isWhatIf: false,
            now: now, shape: { box.addAll($0) }
        )
        #expect(!box.lines.isEmpty)
        for line in box.lines {
            #expect(!line.contains("Computer Science"))
        }
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    func addAll(_ lines: [String]) { lock.lock(); stored.append(contentsOf: lines); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@MainActor
@Suite("Degree progress: wired to AppState")
struct DegreeAppStateTests {
    private func makeState() throws -> AppState {
        let suite = "DegreeAppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        return state
    }

    @Test("clearing leaves an empty snapshot, an idle status and an empty file")
    func clearing() throws {
        let state = try makeState()
        var snapshot = DegreeSnapshot.empty
        snapshot.lastShape = ["top: a, b"]
        state.degree = snapshot
        state.degreeStatus = .failed("couldn't read path@penn · retry")
        try state.degreeStore.save(snapshot)
        state.clearDegreeData()
        #expect(state.degree == .empty)
        #expect(state.degreeStatus == .idle)
        #expect(state.degreeStore.load() == .empty)
    }

    @Test("fixture mode never touches the network and shows the sample audit")
    func fixtureMode() async throws {
        let state = try makeState()
        state.forceFixtureDataForTesting(true)
        let calls = LogBox()
        state.degreeClient = DegreeWorksClient(fetch: { request in
            calls.add(request.url?.path ?? "")
            Issue.record("the network must not be called in fixture mode")
            throw URLError(.notConnectedToInternet)
        })
        await state.refreshDegreeAudit(force: true)
        #expect(calls.lines.isEmpty)
        #expect(state.degree.current != nil)
        if case .read = state.degreeStatus {} else {
            Issue.record("expected a read status, got \(state.degreeStatus)")
        }
        await state.runWhatIf(DegreeGoals(minors: ["MATH"]))
        _ = await state.loadDegreeCatalog(selected: DegreeGoals())
        #expect(calls.lines.isEmpty)
    }

    @Test("in fixture mode a what-if run files a copy under the picked goals")
    func fixtureWhatIfRuns() async throws {
        let state = try makeState()
        state.forceFixtureDataForTesting(true)
        await state.refreshDegreeAudit(force: true)
        let goals = DegreeGoals(school: "UG", college: "EU", program: "EU_BSE", degree: "BSE", minors: ["MATH"])
        await state.runWhatIf(goals)
        #expect(state.degree.whatIfs.first?.goals == goals)
        #expect(state.degree.whatIfs.first?.isWhatIf == true)
        #expect(state.degree.whatIfs.count <= 5)
    }

    @Test("the feature is available on Penn, and with fixtures, when the flag is on")
    func availability() throws {
        let state = try makeState()
        #expect(state.degreeFeatureAvailable == (FeatureFlags.degreeProgress
            && state.canvasInstallation.id == CanvasInstallation.penn.id))
        state.forceFixtureDataForTesting(true)
        #expect(state.degreeFeatureAvailable == FeatureFlags.degreeProgress)
    }
}
