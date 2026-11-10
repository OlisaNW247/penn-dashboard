import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

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

@Suite("Degree progress: what a sign-in outcome says")
struct DegreeSignInStatusTests {
    @Test("each outcome maps to its status, and a throttle keeps what was showing")
    func mapping() {
        let kept = DegreeStatus.read(Date(timeIntervalSince1970: 1_800_000_000))
        #expect(AppState.degreeStatus(for: .ready, previous: kept) == nil)
        #expect(AppState.degreeStatus(for: .needsDuo, previous: kept) == .waitingForDuo)
        #expect(AppState.degreeStatus(for: .noCanvasSession, previous: kept) == .needsCanvasSignIn)
        #expect(AppState.degreeStatus(for: .blocked, previous: kept) == .failed(AppState.degreeFailedLine))
        #expect(AppState.degreeStatus(for: .timedOut, previous: kept) == .failed(AppState.degreeFailedLine))
        #expect(AppState.degreeStatus(for: .throttled, previous: kept) == kept)
        // A throttle must never leave "reading" standing with nothing reading.
        #expect(AppState.degreeStatus(for: .throttled, previous: .reading) == .idle)
    }
}

@Suite("Degree progress: the portal's source")
struct PathPortalSourceTests {
    private func portalSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/PathPortal.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the popup is allowed, answered with the configuration WebKit passed, and scripts run in the page world")
    func popupContract() throws {
        let source = try portalSource()
        #expect(source.contains("javaScriptCanOpenWindowsAutomatically"))
        #expect(source.contains("createWebViewWith"))
        // The child is built from the passed-in configuration, and the only
        // fresh configuration in the file is the main WebView's.
        #expect(source.contains("WKWebView(frame: .zero, configuration: configuration)"))
        #expect(source.components(separatedBy: "WKWebViewConfiguration()").count == 2)
        #expect(source.contains("in: .page"))
        #expect(source.contains("PathPage.authHost"))
    }

    @Test("the token and the student's id never appear in the portal")
    func nothingPersonal() throws {
        let source = try portalSource()
        #expect(!source.contains("\"sam.auth.token\""))
        #expect(!source.contains("\"idProof\""))
        #expect(!source.contains("evaluateJavaScript(\"sam"))
        // Not even named in a comment: the readiness script is the only door.
        #expect(!source.contains("sam.auth.token"))
        #expect(!source.contains("idProof"))
    }
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

    @Test("fixture mode shows the sample audit and never touches the portal")
    func fixtureMode() async throws {
        let state = try makeState()
        state.forceFixtureDataForTesting(true)
        await state.refreshDegreeAudit(force: true)
        #expect(state.degree.current != nil)
        #expect(!state.degree.degrees.isEmpty)
        if case .read = state.degreeStatus {} else {
            Issue.record("expected a read status, got \(state.degreeStatus)")
        }
        let programs = await state.loadDegreePrograms()
        #expect(programs.count >= 8)
        let plans = await state.degreeWhatIfPlans(for: "MATH-MIN")
        #expect(plans.map(\.change) == [.newProgram, .addMinor])
        let switchOnly = await state.degreeWhatIfPlans(for: "CMPE-BSE")
        #expect(switchOnly.map(\.change) == [.newProgram])
        if let plan = plans.last { await state.runWhatIf(plan) }
        #expect(state.degreeStatus != .reading)
    }

    @Test("in fixture mode a what-if run files a copy under the plan's goals")
    func fixtureWhatIfRuns() async throws {
        let state = try makeState()
        state.forceFixtureDataForTesting(true)
        await state.refreshDegreeAudit(force: true)
        let goals = DegreeGoals(school: "UG", college: "EU", program: "EU_BSE", degree: "BSE", minors: ["STAT"])
        let plan = PathWhatIfPlan(
            change: .addMinor, programCode: "STAT-MIN",
            degreeInfo: ["degc": "BSE", "minor": "STAT"], goals: goals)
        await state.runWhatIf(plan)
        #expect(state.degree.whatIfs.first?.goals == goals)
        #expect(state.degree.whatIfs.first?.isWhatIf == true)
        #expect(state.degree.whatIfs.count <= 5)
    }

    @Test("in fixture mode selecting a degree moves the choice and keeps the sample audit")
    func fixtureSelectDegree() async throws {
        let state = try makeState()
        state.forceFixtureDataForTesting(true)
        await state.refreshDegreeAudit(force: true)
        let first = try #require(state.selectedStudentDegree)
        let second = try #require(state.degree.degrees.first { $0.id != first.id })
        await state.selectDegree(second.id)
        #expect(state.selectedStudentDegree?.id == second.id)
        #expect(state.degree.current != nil)
        // Unchanged is a no-op, and an unknown id changes nothing.
        await state.selectDegree(second.id)
        await state.selectDegree("no such degree")
        #expect(state.selectedStudentDegree?.id == second.id)
    }

    @Test("the selected degree falls back to the first, and descriptions come from the dictionaries")
    func selectionAndDescriptions() throws {
        let state = try makeState()
        #expect(state.selectedStudentDegree == nil)
        #expect(state.degreeDescriptions.isEmpty)
        let one = StudentDegree(raw: ["degc": "BSE", "coll": "EU", "major": "CSCI"])
        let two = StudentDegree(raw: ["degc": "BS", "coll": "WU", "major": "UNDL"])
        state.degree = DegreeSnapshot(
            degrees: [one, two], selectedDegreeID: nil,
            dictionaries: PathDictionaries(majors: ["CSCI": "Computer Science"]))
        #expect(state.selectedStudentDegree == one)
        #expect(state.degreeDescriptions["CSCI"] == "Computer Science")
        state.degree.selectedDegreeID = two.id
        #expect(state.selectedStudentDegree == two)
        state.degree.selectedDegreeID = "gone"
        #expect(state.selectedStudentDegree == one)
    }

    @Test("clearing leaves an empty snapshot, an idle status, an empty file and no saved choice")
    func clearing() throws {
        let state = try makeState()
        let key = "degreeSelectedIDV1"
        let saved = UserDefaults.lhf.object(forKey: key)
        defer {
            if let saved { UserDefaults.lhf.set(saved, forKey: key) } else { UserDefaults.lhf.removeObject(forKey: key) }
        }
        let snapshot = SampleData.degreeSnapshot()
        state.degree = snapshot
        state.degreeStatus = .failed(AppState.degreeFailedLine)
        UserDefaults.lhf.set("some|id", forKey: key)
        try state.degreeStore.save(snapshot)
        state.clearDegreeData()
        #expect(state.degree == .empty)
        #expect(state.degreeStatus == .idle)
        #expect(state.degreeStore.load() == .empty)
        #expect(UserDefaults.lhf.string(forKey: key) == nil)
    }

    @Test("a snapshot with the new fields survives a round trip through the store")
    func snapshotRoundTrip() throws {
        let state = try makeState()
        // A whole-second `now`: the store writes dates as ISO 8601, which
        // drops the fraction, so a snapshot stamped with `Date()` comes back
        // a few hundred milliseconds different and unequal. That is the
        // fixture's doing, not a loss in the store.
        let snapshot = SampleData.degreeSnapshot(now: Date(timeIntervalSince1970: 1_800_000_000))
        try state.degreeStore.save(snapshot)
        #expect(state.degreeStore.load() == snapshot)
        #expect(!snapshot.degrees.isEmpty)
        #expect(snapshot.selectedDegreeID == snapshot.degrees.first?.id)
        #expect(!snapshot.programs.isEmpty)
        #expect(snapshot.dictionaries != nil)
    }

    @Test("an old-format snapshot with a catalog key and none of the new keys still decodes")
    func oldFormatDecodes() throws {
        let old = #"{"whatIfs":[],"catalog":{"majors":[{"key":"CIS","description":"cs"}]},"lastShape":["x"]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DegreeSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.current == nil)
        #expect(snapshot.degrees.isEmpty)
        #expect(snapshot.selectedDegreeID == nil)
        #expect(snapshot.programs.isEmpty)
        #expect(snapshot.dictionaries == nil)
        #expect(snapshot.lastShape == ["x"])
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
