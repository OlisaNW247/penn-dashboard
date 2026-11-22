import Foundation
import Testing
import WebKit
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// The hostile test pass over 3.5.0 (21), 2026-11-22
// (`docs/TEST_RELEASE_3.5.0_2026-11-22.md`). A test that pins a defect is
// wrapped in `withKnownIssue`: it passes while the defect is there and fails
// ("known issue was not recorded") the day it is fixed, which is the signal
// to drop the wrapper. Everything else pins behaviour that held.

// MARK: - The update wall's list (R-I1)

@Suite("3.5.0 pass: the update wall's four lines")
struct ReleasePassUpdateChangesTests {
    /// Marco's four lines from `docs/appstore/LISTING.md` → "Update wall list
    /// for 3.5.0", exactly as they will be pasted into `lhf-update.json`. One
    /// of them is exactly the 40-character limit, so a sanitizer that counted
    /// one character differently (UTF-16, a trailing space) would drop it on
    /// the live wall and nobody would see why.
    static let marco = [
        "the smooth sweeper has its own page",
        "the sweeper is more accurate and careful",
        "swipe a card either way to finish it",
        "become a smooth ambassador",
    ]

    @Test("all four survive the sanitizer, unchanged, in order")
    func allFourKept() {
        #expect(UpdatePolicy.sanitizedChanges(Self.marco) == Self.marco)
        #expect(Self.marco.map(\.count).max() == 40)
    }

    @Test("decoded from a manifest shaped like the live one, the four lines come through")
    func manifestDecode() throws {
        let json = """
        {"minimumVersion":"3.5.0","latestVersion":"3.5.0",
         "appStoreURL":"https://apps.apple.com/us/app/smooth-for-students/id6783911002",
         "changes":["the smooth sweeper has its own page","the sweeper is more accurate and careful",
                    "swipe a card either way to finish it","become a smooth ambassador"]}
        """
        let policy = try JSONDecoder().decode(UpdatePolicy.self, from: Data(json.utf8))
        #expect(policy.changes == Self.marco)
        // And the cache's encode-then-decode returns the same list.
        let again = try JSONDecoder().decode(UpdatePolicy.self, from: JSONEncoder().encode(policy))
        #expect(again.changes == Self.marco)
    }

    @Test("a 41st character, a pasted capital or a trailing tab are handled as documented")
    func edges() {
        #expect(UpdatePolicy.sanitizedChanges(["the sweeper is more accurate and careful!"]).isEmpty)
        #expect(UpdatePolicy.sanitizedChanges(["Become A Smooth Ambassador\t"]) == ["become a smooth ambassador"])
        #expect(UpdatePolicy.sanitizedChanges(["see https://x.test"]).isEmpty)
        #expect(UpdatePolicy.sanitizedChanges(["go to www.example.com"]).isEmpty)
    }

    /// R-L5. "No link on the wall" is the sanitizer's promise; a bare domain
    /// with no scheme and no `www.` is not read as a link by NSDataDetector for
    /// newer TLDs, so it is shown.
    @Test("a bare domain is dropped like any other link")
    func bareDomains() {
        let candidates = ["see smooth.app now", "get it at smooth.dev", "visit smoothapp.com", "update at bit.ly/x"]
        let shown = candidates.filter { !UpdatePolicy.sanitizedChanges([$0]).isEmpty }
        withKnownIssue("R-L5: \(shown) pass the link filter") {
            #expect(shown.isEmpty)
        }
    }
}

// MARK: - Ambassador tasks

@MainActor
@Suite("3.5.0 pass: ambassador task ticks", .serialized)
struct ReleasePassAmbassadorTaskTests {
    /// The phone's own day index for the fixed -5 h zone the model below
    /// uses, computed the same way the server's `dayIndex()` does.
    static func localToday() -> Int {
        Int(((Date().timeIntervalSince1970 - 5 * 3600) / 86_400).rounded(.down))
    }

    private func withModel(
        planDay: Int,
        _ body: @MainActor (AmbassadorModel, FakeAmbassadorService) async throws -> Void
    ) async rethrows {
        let before = NotificationScheduler.reservedForeignSlots
        defer { NotificationScheduler.reservedForeignSlots = before }
        let suite = "release-pass-ambassador-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeAmbassadorService()
        service.plans[AmbassadorModelTests.code] = AmbassadorModelTests.plan(dayIndex: planDay)
        final class Box: @unchecked Sendable { var code: String?; init() {} }
        let box = Box()
        let model = AmbassadorModel(defaults: defaults, client: service, center: FakeAmbassadorCenter(),
                                    loadCode: { box.code }, saveCode: { box.code = $0 }, removeCode: { box.code = nil },
                                    timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
        try await body(model, service)
    }

    /// R-M1. Plan fetched at 23:50 (yesterday's index), "done" tapped at
    /// 00:05 before the 30-minute cache expires: the post reaches the server
    /// and is logged on the server's today, but the phone records it under
    /// the cached plan's yesterday. When the plan refreshes, the task the
    /// student just did reads not done, and the streak counts it as yesterday.
    @Test("a post made after midnight under a cached plan stays done after the plan refreshes")
    func staleCachedDayIndex() async {
        let today = Self.localToday()
        await withModel(planDay: today - 1) { model, service in
            #expect(await model.signIn(AmbassadorModelTests.code))
            await model.markDone(.anonChats)
            #expect(service.sent.contains { $0.action == "post" })
            #expect(model.isDone(.anonChats))

            service.plans[AmbassadorModelTests.code] = AmbassadorModelTests.plan(dayIndex: today)
            await model.refresh()
            withKnownIssue("R-M1: todayIndex prefers a stale cached plan's dayIndex over the phone's own day") {
                #expect(model.isDone(.anonChats))
                #expect(model.anonStreak == 1)
            }
        }
    }

    /// R-M2. `markDone(.anonChats)` ticks first and then logs the post; when
    /// the log fails (offline), the tick stays, the done row turns into a
    /// disabled check, and nothing ever sends the post again. The founders'
    /// count misses it, which `markPostedToday`'s own comment says must not
    /// happen ("The tap fails visibly instead, and can be repeated").
    @Test("an anonymous post that failed to log can be logged again")
    func offlinePostIsNotRetried() async {
        await withModel(planDay: Self.localToday()) { model, service in
            #expect(await model.signIn(AmbassadorModelTests.code))
            service.offline = true
            await model.markDone(.anonChats)
            #expect(model.lastError != nil)
            #expect(!model.postedToday)
            withKnownIssue("R-M2: the local tick hides the done button, so a failed post log has no retry") {
                // The row is drawn as a done check exactly when isDone is true.
                #expect(!model.isDone(.anonChats))
            }
            service.offline = false
            // Nothing in the model retries on its own: a refresh does not.
            await model.refresh()
            #expect(!service.sent.contains { $0.action == "post" })
        }
    }

    @Test("a group-chat drop that failed to log is ticked and never sent (same shape as R-M2)")
    func offlineGroupChat() async {
        await withModel(planDay: Self.localToday()) { model, service in
            #expect(await model.signIn(AmbassadorModelTests.code))
            service.offline = true
            await model.markDone(.groupChats)
            #expect(model.isDone(.groupChats))
            #expect(model.lastError == nil) // silent: `try?`
            #expect(service.sent.isEmpty)
        }
    }

    @Test("the posters count clamps whatever is stored or sent")
    func postersClamp() async {
        await withModel(planDay: Self.localToday()) { model, _ in
            model.setPostersPutUp(-4)
            #expect(model.postersPutUp == 0)
            model.setPostersPutUp(10_000)
            #expect(model.postersPutUp == AmbassadorGoals.postersTarget)
            #expect(model.isDone(.posters))
            model.setPostersPutUp(29)
            #expect(!model.isDone(.posters))
        }
    }
}

@Suite("3.5.0 pass: ambassador pure rules")
struct ReleasePassAmbassadorPureTests {
    @Test("the streak never counts a future day and survives a gap of one unposted today")
    func streak() {
        var log = AmbassadorTaskLog()
        for d in [96, 97, 98, 99] { log.markDone(.anonChats, todayIndex: d) }
        #expect(log.anonStreak(todayIndex: 100) == 4)   // today not yet posted
        #expect(log.anonStreak(todayIndex: 101) == 0)   // yesterday missed
        log.markDone(.anonChats, todayIndex: 500)        // a wrong clock
        #expect(log.anonStreak(todayIndex: 100) == 4)
        #expect(!log.isDone(.groupChats, todayIndex: 100))
    }

    @Test("a corrupt stored log decodes to empty pieces, never throws away the other key")
    func lenientLog() throws {
        let json = #"{"doneDayIndex":{"feedback":10},"anonDays":"nope"}"#
        let log = try JSONDecoder().decode(AmbassadorTaskLog.self, from: Data(json.utf8))
        #expect(log.doneDayIndex == ["feedback": 10])
        #expect(log.anonDays.isEmpty)
    }

    @Test("goal progress is clamped and a zero target is safe")
    func goals() {
        #expect(AmbassadorGoals.progress(count: -3, target: 100) == 0)
        #expect(AmbassadorGoals.progress(count: 250, target: 100) == 1)
        #expect(AmbassadorGoals.progress(count: 5, target: 0) == 0)
        #expect(AmbassadorGoals.caption(count: 250, target: 100) == "250 of 100")
    }

    @Test("guidance is filled once and a filled text is left alone")
    func guidanceFill() {
        let link = "https://example.test/r/abc/s/fizz"
        let once = AmbassadorGuidance.filled("i use this app {link}", link: link)
        #expect(once == "i use this app \(link)")
        #expect(AmbassadorGuidance.filled(once, link: link) == once)
    }
}

// MARK: - Install count (R-L2, R-L3)

@Suite("3.5.0 pass: install count edges")
struct ReleasePassInstallCountTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func attempt(lastAttempt: Date?) -> Bool {
        InstallCountRule.shouldAttempt(
            featureEnabled: true, onboardingComplete: true, canvasConnected: true,
            usingFixtureData: false, isTestRunner: false, alreadyReported: false,
            host: "canvas.upenn.edu", lastAttempt: lastAttempt, now: Self.now)
    }

    /// R-L2. A last attempt stamped under a clock set ahead (a phone whose
    /// date was wrong once) blocks every later attempt until real time
    /// passes it, which can be never for a year-2100 stamp.
    @Test("a last-attempt stamp in the future does not block the count for good")
    func futureStamp() {
        #expect(attempt(lastAttempt: Self.now.addingTimeInterval(-7 * 3600)))
        withKnownIssue("R-L2: a future lastAttempt is read as 'just tried'") {
            #expect(attempt(lastAttempt: Self.now.addingTimeInterval(365 * 86_400)))
        }
    }

    /// R-L3. The phone's host rule is looser than the Worker's
    /// (`/^[a-z0-9-]+(\.[a-z0-9-]+)+$/`): a host the phone sends, the Worker
    /// answers 400, and a 400 is `.done`, so the install is never counted.
    @Test("every host the phone sends is one the Worker accepts")
    func hostRuleMatchesWorker() throws {
        let worker = try Regex("^[a-z0-9-]+(\\.[a-z0-9-]+)+$")
        let hostile = ["canvas.upenn.edu.", ".canvas.upenn.edu", "canvas..upenn.edu", "....", "a.-"]
        let sentButRefused = hostile.filter { host in
            guard let sent = InstallCountRule.normalizedHost(host) else { return false }
            return (try? worker.wholeMatch(in: sent)) == nil
        }
        withKnownIssue("R-L3: \(sentButRefused) pass normalizedHost and are refused (400 → done) by the Worker") {
            #expect(sentButRefused.isEmpty)
        }
        // The real catalog hosts all pass both.
        for host in ["canvas.upenn.edu", "canvas.virginia.edu", "bcourses.berkeley.edu"] {
            let sent = try #require(InstallCountRule.normalizedHost(host))
            #expect((try? worker.wholeMatch(in: sent)) != nil)
        }
    }

    @Test("the body is exactly two keys for any accepted host")
    func body() throws {
        let host = try #require(InstallCountRule.normalizedHost("  CANVAS.UPENN.EDU \n"))
        let object = try JSONSerialization.jsonObject(with: InstallCountRule.body(host: host, kind: "new")) as? [String: String]
        #expect(object == ["host": "canvas.upenn.edu", "kind": "new"])
    }
}

// MARK: - Practice cards (R-L4)

@MainActor
@Suite("3.5.0 pass: practice cards from real items")
struct ReleasePassPracticeCardsTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ id: String, _ course: String, days: Double, kind: Assignment.Kind = .assignment,
                     submitted: Bool = false) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: kind, course: course, title: "item \(id)",
                   dueAt: now.addingTimeInterval(days * 86_400), url: nil, submitted: submitted)
    }

    @Test("nothing upcoming, or only undated or past work, falls back to the three generic cards")
    func fallback() {
        let past = Self.item("p", "CIS 1200", days: -1)
        let undated = Assignment(source: .canvas, sourceID: "u", kind: .assignment, course: "CIS 1200",
                                 title: "u", dueAt: nil, url: nil)
        let cards = PracticeCards.items(from: [past, undated], now: Self.now)
        #expect(cards.map(\.assignment.course) == ["BIO 101", "ECON 101", "WRTG 101"])
    }

    @Test("one per class first, soonest first, at most three, no duplicates")
    func spread() {
        let rows = [
            Self.item("a1", "CIS 1200", days: 1), Self.item("a2", "CIS 1200", days: 1.5),
            Self.item("b1", "PHYS 0151", days: 3), Self.item("c1", "MATH 1400", days: 9),
            Self.item("d1", "LGST 1010", days: 20),
        ]
        let ids = PracticeCards.items(from: rows, now: Self.now).map(\.assignment.sourceID)
        #expect(ids == ["a1", "b1", "c1"])
        #expect(Set(ids).count == ids.count)
    }

    /// R-L4. The lesson says "swipe right to finish" over the student's own
    /// work, and the pool is the raw feed: work already handed in on Canvas
    /// and a calendar event with nothing to hand in are chosen like anything
    /// else.
    @Test("work already submitted and non-submittable events are not practice cards")
    func submittedAndEvents() {
        let rows = [
            Self.item("done", "CIS 1200", days: 1, submitted: true),
            Self.item("lecture", "PHYS 0151", days: 1.2, kind: .event),
            Self.item("real", "MATH 1400", days: 2),
        ]
        let ids = PracticeCards.items(from: rows, now: Self.now).map(\.assignment.sourceID)
        withKnownIssue("R-L4: submitted work and events are offered for the practice swipe") {
            #expect(!ids.contains("done"))
            #expect(!ids.contains("lecture"))
        }
    }

    @Test("ten thousand items pick in well under a second")
    func huge() {
        let rows = (0..<10_000).map { Self.item("x\($0)", "C\($0 % 400)", days: Double($0 % 90) + 0.5) }
        let start = Date()
        let cards = PracticeCards.items(from: rows, now: Self.now)
        #expect(cards.count == 3)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }
}

// MARK: - Swipe and app-link guard edges (held)

@Suite("3.5.0 pass: swipe and app-link edges")
struct ReleasePassSwipeAndGuardTests {
    @Test("either-way completion: thresholds are symmetric and a fling the other way never counts",
          arguments: [
              (70.0, 0.0, 0.0, true), (-70.0, 0.0, 0.0, true),
              (50.0, 0.0, 90.0, true), (-50.0, 0.0, -90.0, true),
              (50.0, 0.0, -90.0, false), (-50.0, 0.0, 90.0, false),
              (60.0, 61.0, 200.0, false), (-0.0, 0.0, -500.0, false),
              (41.9, 0.0, 500.0, false), (Double.nan, 0.0, 100.0, false),
              (Double.infinity, 0.0, 0.0, true),
          ])
    func either(h: Double, v: Double, predicted: Double, expected: Bool) {
        #expect(CompletionSwipe.acceptsCompletion(horizontal: h, vertical: v, predicted: predicted) == expected)
    }

    @Test("undo in prev stays left only")
    func undoLeftOnly() {
        #expect(CompletionSwipe.accepts(horizontal: -70, vertical: 0, predicted: 0, undo: true))
        #expect(!CompletionSwipe.accepts(horizontal: 70, vertical: 0, predicted: 0, undo: true))
    }

    @Test("the guard fires only on a cross-host arrival at the guard host, case-insensitively")
    func guardRule() {
        func needs(_ dest: String?, _ current: String?, marker: Bool = false,
                   type: WKNavigationTypeShim = .other) -> Bool {
            AppLinkGuard.needsAppLinkGuard(destinationHost: dest, currentHost: current,
                                           guardHost: "canvas.upenn.edu", navigationType: type.value,
                                           hasReissueMarker: marker)
        }
        #expect(needs("CANVAS.UPENN.EDU", "idp.pennkey.upenn.edu"))
        #expect(!needs("canvas.upenn.edu", "canvas.upenn.edu"))
        #expect(!needs("canvas.upenn.edu", nil))
        #expect(!needs("canvas.upenn.edu", "idp.pennkey.upenn.edu", marker: true))
        #expect(!needs("canvas.upenn.edu", "idp.pennkey.upenn.edu", type: .backForward))
        #expect(!needs(nil, "idp.pennkey.upenn.edu"))
        #expect(!AppLinkGuard.reissueAllowed(count: AppLinkGuard.maxAppLinkReissues))
    }

    @Test("the form script embeds a target URL as one JS string literal")
    func scriptLiteral() throws {
        let url = try #require(URL(string: "https://canvas.upenn.edu/login/saml?x=%22%5C#frag"))
        let script = AppLinkGuard.formSerializerScript(targetURL: url)
        #expect(script.contains("var target = \"https://canvas.upenn.edu/login/saml?x=%22%5C\";"))
        #expect(AppLinkGuard.jsonStringLiteral(for: #"a"b\c"#) == #""a\"b\\c""#)
    }
}



/// `WKNavigationType` spelled as a Sendable test argument.
enum WKNavigationTypeShim {
    case other, backForward
    var value: WKNavigationType { self == .other ? .other : .backForward }
}
