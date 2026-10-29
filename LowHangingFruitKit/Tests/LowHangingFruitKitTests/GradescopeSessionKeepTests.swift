import Foundation
import Security
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// Keeping a Gradescope connection alive (hardening plan A4, 2026-10-27).
//
// Four things used to sign a student out of Gradescope on one observation: the
// 24-hour no-expiry cookie clock, an empty cookie set in the coordinator, any
// 401 or 403, and a keyword match that could fire on an ordinary page. These
// suites pin the replacements: no clock, no disconnect on a failed read, a
// login form (a password input) as the only evidence, and two runs an hour
// apart before the reconnect line shows.

// MARK: - The detector

@Suite("Gradescope login form detector")
struct GradescopeLoginFormDetectorTests {

    @Test("a password input is a login form, whatever its quoting or attribute order",
          arguments: [
            #"<input type="password" name="session[password]">"#,
            #"<input type='password'>"#,
            "<input type=password>",
            #"<INPUT NAME="x" TYPE="PASSWORD" id="y">"#,
            #"<form><input class="form--input" name="session[password]" type = "password" autocomplete="current-password"></form>"#,
            "<input\n  type=\"password\"\n  name=\"p\">",
          ])
    func passwordInputIsALoginForm(html: String) {
        #expect(GradescopeHTMLParser.isLoginPage(html))
    }

    @Test("every word the old keyword match looked for, without a password input, is not a login form")
    func keywordsAloneAreNotALoginForm() {
        let html = """
        <main>
          <h1>Log in to Gradescope</h1>
          <p>Use your school credentials, email or password.</p>
          <label>Email</label><label>Password</label>
        </main>
        """
        #expect(!GradescopeHTMLParser.isLoginPage(html))
    }

    @Test("inputs that only mention a password are not login forms",
          arguments: [
            #"<input type="hidden" name="password">"#,
            #"<input data-type="password" name="x">"#,
            #"<input type="text" placeholder="password">"#,
            #"<input type="email" name="session[email]">"#,
            #"<textarea name="type=password"></textarea>"#,
            "",
          ])
    func lookalikesAreNot(html: String) {
        #expect(!GradescopeHTMLParser.isLoginPage(html))
    }
}

// MARK: - The two-runs rule

@Suite("Gradescope reauth rule")
struct GradescopeReauthRuleTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    private func run(
        _ outcomes: [(GradescopeReauthRule.Outcome, TimeInterval)],
        from state: GradescopeReauthRule.State = .clear
    ) -> GradescopeReauthRule.State {
        outcomes.reduce(state) { GradescopeReauthRule.advance($0, after: $1.0, now: t0.addingTimeInterval($1.1)) }
    }

    @Test("one login form records a sighting and raises nothing")
    func firstSightingOnly() {
        let state = run([(.loginForm, 0)])
        #expect(!state.needsReauth)
        #expect(state.firstLoginFormAt == t0)
    }

    @Test("a second login form inside the hour is the same event")
    func secondInsideTheHour() {
        let state = run([(.loginForm, 0), (.loginForm, hour / 4), (.loginForm, hour - 1)])
        #expect(!state.needsReauth)
        #expect(state.firstLoginFormAt == t0, "the first sighting is kept, not moved forward by later ones")
    }

    @Test("a second login form exactly an hour later raises the verdict")
    func secondAtTheHour() {
        let state = run([(.loginForm, 0), (.loginForm, hour)])
        #expect(state.needsReauth)
    }

    @Test("a second login form two days later raises the verdict")
    func secondMuchLater() {
        #expect(run([(.loginForm, 0), (.loginForm, 48 * hour)]).needsReauth)
    }

    @Test("an accepted fetch between the two sightings clears the first")
    func acceptedFetchClears() {
        let state = run([(.loginForm, 0), (.sessionAccepted, hour), (.loginForm, 2 * hour)])
        #expect(!state.needsReauth)
        #expect(state.firstLoginFormAt == t0.addingTimeInterval(2 * hour), "the later one starts a fresh count")
    }

    @Test("an accepted fetch clears a raised verdict by itself")
    func acceptedFetchClearsTheVerdict() {
        let raised = run([(.loginForm, 0), (.loginForm, hour)])
        #expect(raised.needsReauth)
        #expect(run([(.sessionAccepted, 2 * hour)], from: raised) == .clear)
    }

    @Test("an inconclusive run (offline, a 403, an empty cookie set) changes nothing, before or after a sighting")
    func inconclusiveChangesNothing() {
        #expect(run([(.inconclusive, 0)]) == .clear)
        let seen = run([(.loginForm, 0)])
        #expect(run([(.inconclusive, hour)], from: seen) == seen)
        let raised = run([(.loginForm, 0), (.loginForm, hour)])
        #expect(run([(.inconclusive, 2 * hour)], from: raised) == raised)
    }

    @Test("a 403 between two login forms does not break the pair")
    func inconclusiveBetweenSightings() {
        #expect(run([(.loginForm, 0), (.inconclusive, hour / 2), (.loginForm, 2 * hour)]).needsReauth)
    }

    @Test("a raised verdict stays raised through further login forms and keeps the original sighting")
    func raisedStaysRaised() {
        let state = run([(.loginForm, 0), (.loginForm, hour), (.loginForm, 5 * hour)])
        #expect(state.needsReauth)
        #expect(state.firstLoginFormAt == t0)
    }

    @Test("a clock moved backwards restarts the count instead of making the verdict unreachable")
    func clockRewind() {
        // First sighting is in the "future" relative to the second run.
        let state = run([(.loginForm, 10 * hour), (.loginForm, 0)])
        #expect(!state.needsReauth)
        #expect(state.firstLoginFormAt == t0)
        // And the count works from the new anchor.
        #expect(run([(.loginForm, hour)], from: state).needsReauth)
    }
}

// MARK: - Persistence of the verdict

@Suite("Gradescope reauth store")
struct GradescopeReauthStoreTests {
    /// A scratch suite, never `UserDefaults.lhf`: under `swift test` that is
    /// `.standard`, shared by every suite in the process.
    private func scratch(_ body: (UserDefaults) -> Void) {
        let name = "lhf.test.gradescopeReauth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test("nothing saved reads as clear")
    func emptyIsClear() {
        scratch { #expect(GradescopeReauthStore.load(defaults: $0) == .clear) }
    }

    @Test("a sighting and a verdict round-trip, so the rule survives a relaunch")
    func roundTrip() {
        scratch { defaults in
            let sighting = Date(timeIntervalSince1970: 1_800_000_000)
            let first = GradescopeReauthRule.State(firstLoginFormAt: sighting, needsReauth: false)
            GradescopeReauthStore.save(first, defaults: defaults)
            #expect(GradescopeReauthStore.load(defaults: defaults) == first)

            let raised = GradescopeReauthRule.State(firstLoginFormAt: sighting, needsReauth: true)
            GradescopeReauthStore.save(raised, defaults: defaults)
            #expect(GradescopeReauthStore.load(defaults: defaults) == raised)
        }
    }

    @Test("reset forgets both the verdict and the sighting")
    func resetClears() {
        scratch { defaults in
            GradescopeReauthStore.save(.init(firstLoginFormAt: Date(), needsReauth: true), defaults: defaults)
            GradescopeReauthStore.reset(defaults: defaults)
            #expect(GradescopeReauthStore.load(defaults: defaults) == .clear)
            #expect(defaults.object(forKey: GradescopeReauthStore.firstSightingKey) == nil)
            #expect(!defaults.bool(forKey: GradescopeReauthStore.needsReauthKey))
        }
    }

    @Test("the saved key is the plan's name for it")
    func keyName() {
        #expect(GradescopeReauthStore.needsReauthKey == "gradescopeNeedsReauth")
    }
}

// MARK: - No clock, no disconnect

@Suite("Gradescope session keep")
struct GradescopeSessionKeepTests {

    @Test("Gradescope has no no-expiry window, so no age signs it out; Canvas keeps its 24 hours")
    func noClock() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(SessionCookieStore.maxAge(for: .gradescope) == nil)
        let twentyFourHours: TimeInterval = 24 * 3600
        #expect(SessionCookieStore.maxAge(for: .canvas) == twentyFourHours)
        let ages: [TimeInterval] = [25 * 3600, 7 * 24 * 3600, 400 * 24 * 3600]
        for age in ages {
            let captured = now.addingTimeInterval(-age)
            #expect(!SessionCookieStore.isStale(capturedAt: captured, now: now, service: .gradescope))
            #expect(SessionCookieStore.isStale(capturedAt: captured, now: now, service: .canvas))
        }
    }

    // `UserDefaults.lhf` is `.standard` under test, so each test below that
    // goes through `AppState` puts back what it changed.
    private static let touched = [
        "gradescopeConnected", GradescopeReauthStore.needsReauthKey, GradescopeReauthStore.firstSightingKey,
    ]

    @MainActor
    private func withRestoredDefaults(_ body: () async -> Void) async {
        let defaults = UserDefaults.lhf
        let saved = Self.touched.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        await body()
    }

    @MainActor
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    @Test("an empty cookie set on a coordinator tick leaves Gradescope connected and syncs nothing")
    @MainActor
    func emptyCookiesDoNotDisconnect() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            var asked = 0

            await AutoSyncCoordinator.syncConnectedServices(
                state: state,
                now: Date(),
                gradescopeCookieProvider: { asked += 1; return [] },
                emptySetOutcome: { .inconclusive }
            )

            #expect(asked == 1, "the tick did read cookies")
            #expect(state.isGradescopeConnected)
            #expect(state.lastGradescopeSync == nil, "no sync ran")
            #expect(!state.gradescopeNeedsReauth, "an empty read is not evidence of anything")
            #expect(UserDefaults.lhf.bool(forKey: "gradescopeConnected"), "and the saved flag is still on")
        }
    }

    @Test("repeated empty ticks never disconnect either")
    @MainActor
    func repeatedEmptyTicks() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            for _ in 0..<5 {
                await AutoSyncCoordinator.syncConnectedServices(
                    state: state, now: Date(), gradescopeCookieProvider: { [] },
                    emptySetOutcome: { .inconclusive }
                )
            }
            #expect(state.isGradescopeConnected)
        }
    }

    // A restored phone: "connected" flag and rows, no Keychain items.
    // Nothing is sent to Gradescope, so no login form ever answers; the
    // definitive not-found read has to stand in for one.

    @Test("a definitively gone cookie set, seen on two runs an hour apart, raises the reconnect verdict and still does not disconnect")
    @MainActor
    func goneCookiesRaiseTheVerdict() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)

            await AutoSyncCoordinator.syncConnectedServices(
                state: state, now: t0, gradescopeCookieProvider: { [] }, emptySetOutcome: { .loginForm }
            )
            #expect(!state.gradescopeNeedsReauth, "one sighting raises nothing")

            await AutoSyncCoordinator.syncConnectedServices(
                state: state, now: t0.addingTimeInterval(3600), gradescopeCookieProvider: { [] }, emptySetOutcome: { .loginForm }
            )
            #expect(state.gradescopeNeedsReauth)
            #expect(state.needsGradescopeConnection, "the banner's condition")
            #expect(state.isGradescopeConnected, "and the connection itself is left alone")
            #expect(state.lastGradescopeSync == nil, "no sync ran")
        }
    }

    @Test("two gone-cookie ticks inside the hour are one event")
    @MainActor
    func goneCookiesInsideTheHour() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            for minutes in [0.0, 5, 20, 59] as [TimeInterval] {
                await AutoSyncCoordinator.syncConnectedServices(
                    state: state, now: t0.addingTimeInterval(minutes * 60),
                    gradescopeCookieProvider: { [] }, emptySetOutcome: { .loginForm }
                )
            }
            #expect(!state.gradescopeNeedsReauth)
        }
    }

    @Test("a Keychain that would not answer counts for nothing, however many hours it goes on")
    @MainActor
    func unavailableCountsForNothing() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            for hours in [0.0, 2, 5, 30] as [TimeInterval] {
                await AutoSyncCoordinator.syncConnectedServices(
                    state: state, now: t0.addingTimeInterval(hours * 3600),
                    gradescopeCookieProvider: { [] }, emptySetOutcome: { .inconclusive }
                )
            }
            #expect(!state.gradescopeNeedsReauth)
            #expect(state.isGradescopeConnected)
        }
    }

    @Test("a disconnected Gradescope is skipped without reading cookies")
    @MainActor
    func disconnectedIsSkipped() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(false)
            var asked = 0
            await AutoSyncCoordinator.syncConnectedServices(
                state: state, now: Date(), gradescopeCookieProvider: { asked += 1; return [] },
                emptySetOutcome: { .inconclusive }
            )
            #expect(asked == 0)
        }
    }

    @Test("the sync throttle still applies before cookies are read")
    @MainActor
    func throttleStillApplies() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            state.lastGradescopeSync = Date()
            var asked = 0
            await AutoSyncCoordinator.syncConnectedServices(
                state: state, now: Date(), gradescopeCookieProvider: { asked += 1; return [] },
                emptySetOutcome: { .inconclusive }
            )
            #expect(asked == 0)
        }
    }

    @Test("a login form seen twice an hour apart raises the verdict and still does not disconnect")
    @MainActor
    func verdictDoesNotDisconnect() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(!state.recordGradescopeOutcome(.loginForm, now: t0).needsReauth)
            #expect(state.recordGradescopeOutcome(.loginForm, now: t0.addingTimeInterval(3600)).needsReauth)
            #expect(state.gradescopeNeedsReauth)
            #expect(state.isGradescopeConnected)
            #expect(UserDefaults.lhf.bool(forKey: GradescopeReauthStore.needsReauthKey))

            // An accepted fetch clears it without anyone doing anything.
            state.recordGradescopeOutcome(.sessionAccepted, now: t0.addingTimeInterval(7200))
            #expect(!state.gradescopeNeedsReauth)
            #expect(!UserDefaults.lhf.bool(forKey: GradescopeReauthStore.needsReauthKey))
        }
    }

    @Test("an explicit disconnect forgets the verdict")
    @MainActor
    func disconnectResets() async {
        await withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(true)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            state.recordGradescopeOutcome(.loginForm, now: t0)
            state.recordGradescopeOutcome(.loginForm, now: t0.addingTimeInterval(3600))
            #expect(state.gradescopeNeedsReauth)

            state.setGradescopeConnected(false)
            #expect(!state.gradescopeNeedsReauth)
            #expect(GradescopeReauthStore.load() == .clear)
        }
    }

    // `syncGradescope`'s failure paths cannot be driven without a network, so
    // the rule "nothing in the Gradescope sync path disconnects on a failure"
    // is pinned on the source, in the same style as `ReconnectCoverTests`.
    @Test("no failure path in the coordinator or the Gradescope sync calls setGradescopeConnected(false)")
    func sourceNeverDisconnectsOnFailure() throws {
        let coordinator = try Self.uiSource("AutoSyncCoordinator.swift")
        let appState = try Self.uiSource("AppState.swift")
        guard !coordinator.isEmpty, !appState.isEmpty else { return }

        // Comments may name the call; code may not.
        func code(_ s: String) -> String {
            s.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        #expect(!code(coordinator).contains("setGradescopeConnected(false)"))

        let start = try #require(appState.range(of: "func syncGradescope(cookies: [HTTPCookie], reportErrors: Bool) async {"))
        let end = try #require(appState.range(of: "func setGradescopeConnected(", range: start.upperBound..<appState.endIndex))
        let syncBody = code(String(appState[start.upperBound..<end.lowerBound]))
        #expect(!syncBody.contains("setGradescopeConnected(false)"))
        #expect(!syncBody.contains("requiresReauthentication"), "a bare 401/403 must not reach the verdict")
    }

    // The cover the "reconnect gradescope" banner opens is the Gradescope step
    // of the onboarding walk, and that step shows "gradescope is connected."
    // instead of the login pane whenever it believes Gradescope is connected.
    // A raised verdict leaves `isGradescopeConnected` true by design, so the
    // step has to look at the verdict too. The step is a SwiftUI view builder
    // with no seam to drive from a test, so the condition is pinned on the
    // source, in the same style as `ReconnectCoverTests`.
    @Test("the Gradescope step shows the login pane, not 'connected', while the reconnect verdict is raised")
    func gradescopeStepChecksTheVerdict() throws {
        let source = try Self.uiSource("OnboardingView.swift")
        guard !source.isEmpty else { return }
        let start = try #require(source.range(of: "private var gradescopeStep: some View {"))
        let end = try #require(source.range(of: "private func gradescopeConnected()", range: start.upperBound..<source.endIndex))
        let step = String(source[start.upperBound..<end.lowerBound])
        let code = step.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.contains("if state.isGradescopeConnected && !state.gradescopeNeedsReauth {"))
        // And the login pane is still the other branch.
        let connected = try #require(code.range(of: "connectedStep("))
        let pane = try #require(code.range(of: "GradescopeLoginPane("))
        #expect(connected.lowerBound < pane.lowerBound)
    }

    private static func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        let file = sources.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }
}

// MARK: - Reading an empty cookie set

@Suite("Gradescope empty cookie set outcome")
struct GradescopeEmptySetOutcomeTests {
    private let entry: [String: String] = ["name": "n", "value": "v", "domain": "www.gradescope.com", "path": "/"]

    @Test("a saved set that is not found is login-form-grade evidence, without asking whether it expired")
    func notFound() {
        var asked = false
        let outcome = SessionCookieStore.emptySetOutcome(read: .notFound, isExpired: { asked = true; return false })
        #expect(outcome == .loginForm)
        #expect(!asked)
    }

    @Test("an empty found set is the same as not found")
    func foundEmpty() {
        #expect(SessionCookieStore.emptySetOutcome(read: .found([]), isExpired: { false }) == .loginForm)
    }

    @Test("a Keychain that would not answer is inconclusive, whatever it refused with, and never asks about expiry",
          arguments: [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecIO])
    func unavailable(status: OSStatus) {
        var asked = false
        let outcome = SessionCookieStore.emptySetOutcome(read: .unavailable(status), isExpired: { asked = true; return true })
        #expect(outcome == .inconclusive)
        #expect(!asked)
    }

    @Test("entries that are all expired by their own dates are gone too; entries still fresh are not")
    func foundEntries() {
        #expect(SessionCookieStore.emptySetOutcome(read: .found([entry]), isExpired: { true }) == .loginForm)
        #expect(SessionCookieStore.emptySetOutcome(read: .found([entry]), isExpired: { false }) == .inconclusive)
    }
}

// MARK: - A course whose page stopped parsing

@Suite("Gradescope emptied-course hold")
struct GradescopeEmptiedCourseHoldTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func row(_ id: String, course: String, due: Date?) -> Assignment {
        Assignment(source: .gradescope, sourceID: id, kind: .assignment,
                   course: course, title: "HW \(id)", dueAt: due, url: nil)
    }

    /// Long overdue and unfinished: exactly what `isAgedOut` hides and
    /// `pruneAgedOut` deletes once the row is flagged gone.
    private var longOverdue: Date { t0.addingTimeInterval(-30 * day) }
    private var future: Date { t0.addingTimeInterval(5 * day) }

    @MainActor
    private func seededStore() throws -> AssignmentStore {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([
            row("a1", course: "CIS 1200", due: longOverdue),
            row("a2", course: "CIS 1200", due: longOverdue),
            row("b1", course: "CIS 2400", due: future),
        ], source: .gradescope, now: t0)
        return store
    }

    @Test("a course that came back empty while another still has rows is held: kept, unflagged, unpruned")
    @MainActor
    func emptiedCourseIsHeld() throws {
        let store = try seededStore()
        let later = t0.addingTimeInterval(15 * 60)
        let result = store.reconcile([row("b1", course: "CIS 2400", due: future)],
                                     source: .gradescope, now: later, holdingEmptiedCourses: true)

        #expect(result.wasSuspectedPartial)
        #expect(Set(result.items.map(\.sourceID)) == ["a1", "a2", "b1"], "the held course's work stays on screen")
        #expect(store.rowCount() == 3, "and nothing was pruned in the call that suspected the fetch")
        #expect(store.goneFromFeedIDs(source: .gradescope).isEmpty, "nor flagged gone")
    }

    @Test("the same fetch without the hold flags, hides and prunes the course, which is the old behaviour")
    @MainActor
    func withoutHoldOldBehaviour() throws {
        let store = try seededStore()
        let result = store.reconcile([row("b1", course: "CIS 2400", due: future)],
                                     source: .gradescope, now: t0.addingTimeInterval(15 * 60))
        #expect(!result.wasSuspectedPartial)
        #expect(Set(result.items.map(\.sourceID)) == ["b1"])
        #expect(store.rowCount() == 1)
    }

    @Test("after a day the course is believed gone, and ordinary flagging and aging take over")
    @MainActor
    func patienceRunsOut() throws {
        let store = try seededStore()
        let result = store.reconcile([row("b1", course: "CIS 2400", due: future)],
                                     source: .gradescope, now: t0.addingTimeInterval(day + 60),
                                     holdingEmptiedCourses: true)
        #expect(!result.wasSuspectedPartial)
        #expect(Set(result.items.map(\.sourceID)) == ["b1"])
    }

    @Test("holding a course does not extend its own patience")
    @MainActor
    func holdingDoesNotRefresh() throws {
        let store = try seededStore()
        // Held at every tick inside the day, and each one a fresh fetch.
        let hoursLater: [TimeInterval] = [5, 10, 15, 20]
        for hours in hoursLater {
            let result = store.reconcile([row("b1", course: "CIS 2400", due: future)],
                                         source: .gradescope, now: t0.addingTimeInterval(hours * 3600),
                                         holdingEmptiedCourses: true)
            #expect(result.wasSuspectedPartial)
            #expect(store.rowCount() == 3)
        }
        // 25 hours after the course was last SEEN, not after it was last held.
        let result = store.reconcile([row("b1", course: "CIS 2400", due: future)],
                                     source: .gradescope, now: t0.addingTimeInterval(25 * 3600),
                                     holdingEmptiedCourses: true)
        #expect(!result.wasSuspectedPartial)
        #expect(store.rowCount() == 1)
    }

    @Test("an empty fetch for the whole source is still refused, as before, and reports partial")
    @MainActor
    func wholeSourceEmpty() throws {
        let store = try seededStore()
        let result = store.reconcile([], source: .gradescope, now: t0.addingTimeInterval(60),
                                     holdingEmptiedCourses: true)
        #expect(result.wasSuspectedPartial)
        #expect(store.rowCount() == 3)
    }

    // A Gradescope that really has no rows (the course ended, the student left
    // it) must stop being reported as a failed refresh. The refusal of an
    // entirely empty fetch has the same one-day patience as the per-course hold.

    @Test("an entirely empty fetch is refused inside the day and believed after it")
    @MainActor
    func legitimatelyEmptySourceIsBelievedAfterPatience() throws {
        let store = try seededStore()

        let early = store.reconcile([], source: .gradescope, now: t0.addingTimeInterval(3600),
                                    holdingEmptiedCourses: true)
        #expect(early.wasSuspectedPartial)
        #expect(store.rowCount() == 3, "nothing flagged or pruned while it is only a suspicion")

        let late = store.reconcile([], source: .gradescope, now: t0.addingTimeInterval(25 * 3600),
                                   holdingEmptiedCourses: true)
        #expect(!late.wasSuspectedPartial, "past the day, empty is real and the notice stops")
        #expect(Set(late.items.map(\.sourceID)) == ["b1"], "the long-overdue rows age out as for any vanished work")
        #expect(store.rowCount() == 1)

        // And it stays quiet on every later empty sync (the surviving row is
        // still listed, but its last sighting is long past).
        let after = store.reconcile([], source: .gradescope, now: t0.addingTimeInterval(26 * 3600),
                                    holdingEmptiedCourses: true)
        #expect(!after.wasSuspectedPartial)
    }

    @Test("rows seen again restart the patience")
    @MainActor
    func seeingRowsRestartsThePatience() throws {
        let store = try seededStore()
        _ = store.reconcile([row("b1", course: "CIS 2400", due: future)], source: .gradescope,
                            now: t0.addingTimeInterval(20 * 3600), holdingEmptiedCourses: true)
        // 30 hours after the first sighting but only 10 after the last.
        let result = store.reconcile([], source: .gradescope, now: t0.addingTimeInterval(30 * 3600),
                                     holdingEmptiedCourses: true)
        #expect(result.wasSuspectedPartial)
    }

    @Test("without the opt-in an empty fetch stays refused indefinitely, as before (Canvas)")
    @MainActor
    func canvasEmptyRefusalHasNoPatience() throws {
        let store = try AssignmentStore(inMemory: true)
        let item = Assignment(source: .canvas, sourceID: "1", kind: .assignment, course: "CIS 1200",
                              title: "HW", dueAt: longOverdue, url: nil)
        _ = store.reconcile([item], source: .canvas, now: t0)
        let result = store.reconcile([], source: .canvas, now: t0.addingTimeInterval(90 * day))
        #expect(result.wasSuspectedPartial)
        #expect(store.rowCount() == 1)
    }

    @Test("the empty-fetch rule is pure: no rows is not suspect, no patience always is, the day is the boundary")
    func emptyFetchRule() {
        let now = t0.addingTimeInterval(100 * day)
        let patience = AssignmentStore.heldCoursePatience
        // No listed rows: nothing to suspect.
        #expect(!AssignmentStore.emptyFetchIsSuspect(lastSeen: [], now: now, withPatience: true))
        #expect(!AssignmentStore.emptyFetchIsSuspect(lastSeen: [], now: now, withPatience: false))
        // Without patience: always.
        #expect(AssignmentStore.emptyFetchIsSuspect(lastSeen: [t0], now: now, withPatience: false))
        // With patience: measured from the newest sighting, boundary exclusive.
        let seen = now.addingTimeInterval(-patience + 1)
        #expect(AssignmentStore.emptyFetchIsSuspect(lastSeen: [t0, seen], now: now, withPatience: true))
        #expect(!AssignmentStore.emptyFetchIsSuspect(lastSeen: [t0, now.addingTimeInterval(-patience)], now: now, withPatience: true))
        #expect(!AssignmentStore.emptyFetchIsSuspect(lastSeen: [t0], now: now, withPatience: true))
    }

    @Test("a course renamed on Gradescope keeps its assignment ids and is not mistaken for an emptied one")
    @MainActor
    func renamedCourseIsNotEmptied() throws {
        let store = try seededStore()
        let result = store.reconcile([
            row("a1", course: "CIS 1200 Programming", due: longOverdue),
            row("a2", course: "CIS 1200 Programming", due: longOverdue),
            row("b1", course: "CIS 2400", due: future),
        ], source: .gradescope, now: t0.addingTimeInterval(60), holdingEmptiedCourses: true)
        #expect(!result.wasSuspectedPartial)
    }

    @Test("a course whose work was replaced under the same label is an ordinary change")
    @MainActor
    func replacedWorkIsNotEmptied() throws {
        let store = try seededStore()
        let result = store.reconcile([
            row("c1", course: "CIS 1200", due: future),
            row("b1", course: "CIS 2400", due: future),
        ], source: .gradescope, now: t0.addingTimeInterval(60), holdingEmptiedCourses: true)
        #expect(!result.wasSuspectedPartial)
    }

    @Test("Canvas never opts in: its feed legitimately drops a whole course when a class ends")
    @MainActor
    func canvasDefaultUnchanged() throws {
        let store = try AssignmentStore(inMemory: true)
        func canvas(_ id: String, _ course: String, _ due: Date) -> Assignment {
            Assignment(source: .canvas, sourceID: id, kind: .assignment, course: course, title: id,
                       dueAt: due, url: nil)
        }
        _ = store.reconcile([canvas("1", "CIS 1200", longOverdue), canvas("2", "CIS 2400", future)],
                            source: .canvas, now: t0)
        let result = store.reconcile([canvas("2", "CIS 2400", future)], source: .canvas,
                                     now: t0.addingTimeInterval(60))
        #expect(!result.wasSuspectedPartial)
        #expect(Set(result.items.map(\.sourceID)) == ["2"])
    }

    @Test("the hold rule is pure: matched by id then label, unlabelled rows never held, patience from the newest sighting")
    func pureRule() {
        typealias Row = AssignmentStore.HeldCourseCandidate
        let now = t0
        let recent = now.addingTimeInterval(-3600)
        // No rows for the course: nothing to hold.
        #expect(AssignmentStore.heldCourses(ledger: [], fetchedIDs: [], fetchedCourses: ["X"], now: now).isEmpty)
        // An unlabelled row cannot be held by label.
        #expect(AssignmentStore.heldCourses(
            ledger: [Row(id: "g:1", course: "", lastSeenInFeed: recent)],
            fetchedIDs: [], fetchedCourses: ["X"], now: now).isEmpty)
        // The ordinary hold.
        #expect(AssignmentStore.heldCourses(
            ledger: [Row(id: "g:1", course: "A", lastSeenInFeed: recent)],
            fetchedIDs: ["g:9"], fetchedCourses: ["X"], now: now) == ["A"])
        // One of its rows came back: not emptied.
        #expect(AssignmentStore.heldCourses(
            ledger: [Row(id: "g:1", course: "A", lastSeenInFeed: recent), Row(id: "g:2", course: "A", lastSeenInFeed: recent)],
            fetchedIDs: ["g:2"], fetchedCourses: ["X"], now: now).isEmpty)
        // Patience measured from the newest sighting among the course's rows.
        let old = now.addingTimeInterval(-AssignmentStore.heldCoursePatience - 1)
        #expect(AssignmentStore.heldCourses(
            ledger: [Row(id: "g:1", course: "A", lastSeenInFeed: old)],
            fetchedIDs: [], fetchedCourses: ["X"], now: now).isEmpty)
        #expect(AssignmentStore.heldCourses(
            ledger: [Row(id: "g:1", course: "A", lastSeenInFeed: old), Row(id: "g:2", course: "A", lastSeenInFeed: recent)],
            fetchedIDs: [], fetchedCourses: ["X"], now: now) == ["A"])
    }
}
