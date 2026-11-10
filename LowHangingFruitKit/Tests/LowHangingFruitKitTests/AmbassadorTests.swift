import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// Ambassador mode (2026-11-09): the code the founders text a friend, the plan
// the server answers with, the daily reminder, and the model that ties them
// together. Everything here runs without a Keychain, a network or the
// notification center: the model takes all three as seams.

@Suite("Ambassador code")
struct AmbassadorCodeTests {
    @Test("a bare code, a page link, a stickers link and the smooth:// link all parse to the same code")
    func shapes() {
        let code = "7yqyg4ter97n4w"
        #expect(AmbassadorCode.parse(code) == code)
        #expect(AmbassadorCode.parse("  \(code)\n") == code)
        #expect(AmbassadorCode.parse(code.uppercased()) == code)
        #expect(AmbassadorCode.parse("https://smooth-poster-scans.jazzysmile20.chatgpt.site/a/\(code)") == code)
        #expect(AmbassadorCode.parse("https://smooth-poster-scans.jazzysmile20.chatgpt.site/a/\(code)/stickers") == code)
        #expect(AmbassadorCode.parse("https://example.test/a/\(code)?ok=hi#numbers") == code)
        #expect(AmbassadorCode.parse("smooth://ambassador?code=\(code)") == code)
    }

    @Test("what can never be a code is refused")
    func refusals() {
        #expect(AmbassadorCode.parse("") == nil)
        #expect(AmbassadorCode.parse("short") == nil)
        #expect(AmbassadorCode.parse(String(repeating: "a", count: 41)) == nil)
        #expect(AmbassadorCode.parse("has spaces in it") == nil)
        #expect(AmbassadorCode.parse("https://example.test/f/secretfoundertoken") == nil)
        #expect(AmbassadorCode.parse("https://example.test/scan/uva/ib") == nil)
        #expect(AmbassadorCode.parse("smooth://pair?c=abc") == nil)
        #expect(AmbassadorCode.parse("smooth://ambassador") == nil)
    }
}

@Suite("Ambassador plan")
struct AmbassadorPlanTests {
    static let json = """
    {"name":"Maya Example","school":"uva","schoolName":"UVA","title":"founding ambassador","status":"active",
     "pausedUntil":null,"page":"https://example.test/a/7yqyg4ter97n4w",
     "numbers":{"linkOpens":13,"linkOpensRecent":13,"schoolScans":16,"schoolScansRecent":4,"drops":3,"posts":1,"days":14},
     "today":{"dayIndex":20766,"kind":"anon","channel":"sidechat","platform":"sidechat","text":"psa … https://example.test/r/k3m9x2p7qa/s/sidechat"},
     "messages":[{"key":"gc","label":"group chat","channel":"gc","text":"hi {x}"}],
     "checklist":[{"key":"download","label":"download smooth","hint":"2 min","done":true}],
     "tips":["post once"],"unknownFutureField":{"a":1},"generatedAt":"2026-11-09T20:00:00.000Z"}
    """

    @Test("decodes leniently and round-trips through the cache")
    func decodes() throws {
        let plan = try AmbassadorPlan.decode(Data(Self.json.utf8))
        #expect(plan.firstName == "Maya")
        #expect(plan.schoolLabel == "uva")
        #expect(plan.numbers?.linkOpens == 13)
        #expect(plan.today?.channel == "sidechat")
        #expect(plan.today?.isRest == false)
        #expect(plan.checklist?.first?.done == true)
        #expect(plan.isPaused() == false)
        let again = try AmbassadorPlan.decode(plan.encoded())
        #expect(again == plan)
    }

    @Test("the bare minimum is a name and a school")
    func minimal() throws {
        let plan = try AmbassadorPlan.decode(Data(#"{"name":"J","school":"clark"}"#.utf8))
        #expect(plan.schoolLabel == "clark")
        #expect(plan.today == nil)
        #expect(plan.numbers == nil)
        #expect(throws: (any Error).self) { try AmbassadorPlan.decode(Data(#"{"school":"clark"}"#.utf8)) }
    }

    @Test("a rest day has words and nothing to post; a pause in the future is a pause")
    func restAndPause() {
        let rest = AmbassadorPlan.Today(dayIndex: 1, kind: "rest", channel: nil, platform: "rest", text: "rest day.")
        #expect(rest.isRest)
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
        let past = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400))
        #expect(AmbassadorPlan(name: "a", school: "uva", pausedUntil: future).isPaused())
        #expect(!AmbassadorPlan(name: "a", school: "uva", pausedUntil: past).isPaused())
        #expect(!AmbassadorPlan(name: "a", school: "uva", pausedUntil: "not a date").isPaused())
    }
}

@Suite("Ambassador reminders")
struct AmbassadorRemindersTests {
    @Test("daily is one repeating request at the chosen time, with the prefix the planner spares")
    func daily() throws {
        let requests = AmbassadorReminders.requests(cadence: .daily, hour: 19, minute: 30, firstName: "Maya")
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.identifier == "ambassador:daily")
        #expect(AmbassadorReminders.isAmbassadorIdentifier(request.identifier))
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats)
        #expect(trigger.dateComponents.hour == 19)
        #expect(trigger.dateComponents.minute == 30)
        #expect(trigger.dateComponents.weekday == nil)
        #expect(request.content.body == "today's post is written, maya. tap to copy it.")
        #expect(request.content.title == "smooth")
        #expect(request.content.userInfo["ambassador"] as? String == "daily")
    }

    @Test("weekdays is five weekly requests, Monday to Friday; off is none")
    func weekdaysAndOff() throws {
        let requests = AmbassadorReminders.requests(cadence: .weekdays, hour: 8, minute: 0)
        #expect(requests.count == 5)
        let weekdays = try requests.map { try #require(($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents.weekday) }
        #expect(weekdays == [2, 3, 4, 5, 6])
        #expect(Set(requests.map(\.identifier)).count == 5)
        #expect(requests.allSatisfy { AmbassadorReminders.isAmbassadorIdentifier($0.identifier) })
        #expect(AmbassadorReminders.requests(cadence: .off).isEmpty)
    }

    @Test("the slots each cadence reserves match the requests it schedules")
    func reservedSlots() {
        for cadence in AmbassadorReminderCadence.allCases {
            #expect(AmbassadorReminders.reservedSlots(for: cadence) == AmbassadorReminders.requests(cadence: cadence).count)
        }
    }

    @Test("a due-date reminder's identifier is never mistaken for ours")
    func prefix() {
        #expect(!AmbassadorReminders.isAmbassadorIdentifier("reminder:abc:3600"))
        #expect(!AmbassadorReminders.isAmbassadorIdentifier("loud:abc:1"))
        #expect(!AmbassadorReminders.isAmbassadorIdentifier(""))
    }

    @Test("the phone's offset is minutes west of UTC, as the server counts days")
    func tzOffset() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let november = DateComponents(calendar: .init(identifier: .gregorian), timeZone: newYork,
                                      year: 2026, month: 11, day: 9, hour: 12).date!
        #expect(AmbassadorClient.tzOffsetMinutes(for: newYork, at: november) == 300)
        #expect(AmbassadorClient.tzOffsetMinutes(for: TimeZone(identifier: "UTC")!) == 0)
    }
}

/// The due-date planner's pass must leave ambassador reminders in the queue
/// and give up their slots; this is the contract `AmbassadorReminders`'s doc
/// comment describes, checked against the same fake center the planner's own
/// tests use.
/// `.serialized` here and on the model suite: `NotificationScheduler.
/// reservedForeignSlots` is process-wide, and two async tests interleaving at
/// an `await` would read each other's value.
@MainActor
@Suite("Ambassador reminders and the due-date pass", .serialized)
struct AmbassadorPassTests {
    @Test("applyNotifications removes stale due-date reminders and spares ambassador:*")
    func spared() async {
        let suite = "ambassador-pass-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = NotificationScheduler(defaults: defaults)
        let sink = FakeSink()
        sink.seed(AmbassadorReminders.requests(cadence: .daily)[0])
        sink.seed(UNNotificationRequest(identifier: "reminder:old", content: UNMutableNotificationContent(), trigger: nil))
        let result = await scheduler.applyNotifications([], to: sink)
        #expect(result.staleRemoved == 1)
        #expect(sink.removedIdentifiers == ["reminder:old"])
        #expect(sink.requests.map(\.identifier) == ["ambassador:daily"])
    }

    @Test("reserved slots come off the planner's budget and never below zero")
    func budget() {
        let before = NotificationScheduler.reservedForeignSlots
        defer { NotificationScheduler.reservedForeignSlots = before }
        NotificationScheduler.reservedForeignSlots = 5
        #expect(max(0, NotificationScheduler.maxPending - 0 - NotificationScheduler.reservedForeignSlots) == 55)
        NotificationScheduler.reservedForeignSlots = 1_000
        #expect(max(0, NotificationScheduler.maxPending - 0 - NotificationScheduler.reservedForeignSlots) == 0)
    }
}

// MARK: - The model, against fakes

final class FakeAmbassadorService: AmbassadorService, @unchecked Sendable {
    var plans: [String: AmbassadorPlan] = [:]
    var offline = false
    var sent: [(code: String, action: String, body: [String: String])] = []
    var planRequests: [(code: String, anon: AmbassadorAnonApp, tz: Int)] = []

    func plan(code: String, anonApp: AmbassadorAnonApp, tzOffsetMinutes: Int) async throws -> AmbassadorPlan {
        planRequests.append((code, anonApp, tzOffsetMinutes))
        if offline { throw AmbassadorClientError.network }
        guard let plan = plans[code] else { throw AmbassadorClientError.unknownCode }
        return plan
    }

    func send(code: String, action: String, body: [String: String]) async throws {
        if offline { throw AmbassadorClientError.network }
        guard plans[code] != nil else { throw AmbassadorClientError.unknownCode }
        sent.append((code, action, body))
    }
}

@MainActor
final class FakeAmbassadorCenter: AmbassadorNotificationCenter {
    var status: UNAuthorizationStatus = .notDetermined
    var grants = true
    var authorizationRequests = 0
    var pending: [UNNotificationRequest] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        status = grants ? .authorized : .denied
        return grants
    }
    func pendingIdentifiers() async -> [String] { pending.map(\.identifier) }
    func remove(identifiers: [String]) { pending.removeAll { identifiers.contains($0.identifier) } }
    func add(_ request: UNNotificationRequest) async -> Bool {
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
        return true
    }
}

@MainActor
@Suite("Ambassador model", .serialized)
struct AmbassadorModelTests {
    static let code = "7yqyg4ter97n4w"

    static func plan(dayIndex: Int = 20766) -> AmbassadorPlan {
        AmbassadorPlan(
            name: "Maya Example", school: "uva", schoolName: "UVA", title: "founding ambassador",
            page: "https://example.test/a/\(code)",
            numbers: .init(linkOpens: 13, linkOpensRecent: 13, schoolScans: 16, schoolScansRecent: 4, drops: 3, posts: 1),
            today: .init(dayIndex: dayIndex, kind: "anon", channel: "fizz", platform: "fizz", text: "psa … https://example.test/r/k3m9x2p7qa/s/fizz"),
            messages: [.init(key: "gc", label: "group chat", channel: "gc", text: "hi")],
            checklist: [.init(key: "download", label: "download smooth", done: false)]
        )
    }

    /// A model over scratch defaults, an in-memory code store, and the two
    /// fakes. `NotificationScheduler.reservedForeignSlots` is process-wide,
    /// so every test here restores it.
    private func withModel(
        storedCode: String? = nil,
        _ body: @MainActor (AmbassadorModel, FakeAmbassadorService, FakeAmbassadorCenter, UserDefaults) async throws -> Void
    ) async rethrows {
        let before = NotificationScheduler.reservedForeignSlots
        defer { NotificationScheduler.reservedForeignSlots = before }
        let suite = "ambassador-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeAmbassadorService()
        service.plans[Self.code] = Self.plan()
        let center = FakeAmbassadorCenter()
        final class Box: @unchecked Sendable { var code: String? ; init(_ c: String?) { code = c } }
        let box = Box(storedCode)
        let model = AmbassadorModel(defaults: defaults, client: service, center: center,
                                    loadCode: { box.code }, saveCode: { box.code = $0 }, removeCode: { box.code = nil },
                                    // A fixed offset, not New York: the model reads the real clock,
                                    // and New York is 240 west of UTC for eight months of the year.
                                    timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
        try await body(model, service, center, defaults)
    }

    @Test("signed out: the row invites, nothing is reserved, nothing is scheduled")
    func signedOut() async {
        await withModel { model, _, center, _ in
            #expect(!model.isSignedIn)
            #expect(model.statusLine == "sign in")
            #expect(NotificationScheduler.reservedForeignSlots == 0)
            await model.ensureReminders()
            #expect(center.pending.isEmpty)
            #expect(center.authorizationRequests == 0)
        }
    }

    @Test("a malformed or unknown code fails in words and signs nothing in")
    func badCodes() async {
        await withModel { model, _, center, _ in
            #expect(await model.signIn("nope") == false)
            #expect(model.lastError == "that doesn\u{2019}t look like a code")
            #expect(await model.signIn("unknowncode1234") == false)
            #expect(model.lastError == "that code didn\u{2019}t work")
            #expect(!model.isSignedIn)
            #expect(center.pending.isEmpty)
        }
    }

    @Test("a real code signs in, caches the plan, asks once, schedules the daily reminder and reserves its slot")
    func signIn() async throws {
        try await withModel { model, service, center, defaults in
            #expect(await model.signIn("https://example.test/a/\(Self.code)/stickers"))
            #expect(model.code == Self.code)
            #expect(model.statusLine == "maya \u{00B7} uva")
            #expect(model.plan?.today?.channel == "fizz")
            #expect(service.planRequests.last?.tz == 300)
            #expect(service.planRequests.last?.anon == .fizz)
            #expect(center.authorizationRequests == 1)
            #expect(center.pending.map(\.identifier) == ["ambassador:daily"])
            #expect(NotificationScheduler.reservedForeignSlots == 1)
            // The cache is what a fresh model starts from, offline.
            let cached = try #require(defaults.data(forKey: AmbassadorModel.planCacheKey))
            #expect(try AmbassadorPlan.decode(cached).name == "Maya Example")
        }
    }

    @Test("weekdays swaps the daily request for five and reserves five; off removes them all")
    func cadence() async {
        await withModel { model, _, center, _ in
            await model.signIn(Self.code)
            await model.setCadence(.weekdays)
            #expect(center.pending.count == 5)
            #expect(!center.pending.contains { $0.identifier == "ambassador:daily" })
            #expect(NotificationScheduler.reservedForeignSlots == 5)
            await model.setReminderTime(hour: 8, minute: 15)
            let trigger = center.pending.first?.trigger as? UNCalendarNotificationTrigger
            #expect(trigger?.dateComponents.hour == 8)
            #expect(trigger?.dateComponents.minute == 15)
            await model.setCadence(.off)
            #expect(center.pending.isEmpty)
            #expect(NotificationScheduler.reservedForeignSlots == 0)
        }
    }

    @Test("a refused permission schedules nothing and is not asked again")
    func refused() async {
        await withModel { model, _, center, _ in
            center.grants = false
            await model.signIn(Self.code)
            #expect(model.isSignedIn)
            #expect(center.pending.isEmpty)
            #expect(model.authStatus == .denied)
            await model.ensureReminders()
            #expect(center.authorizationRequests == 1)
        }
    }

    @Test("posted today logs the post in today's channel and sticks for the day only")
    func posted() async {
        await withModel { model, service, _, _ in
            await model.signIn(Self.code)
            #expect(!model.postedToday)
            #expect(await model.markPostedToday())
            #expect(model.postedToday)
            #expect(service.sent.last?.action == "post")
            #expect(service.sent.last?.body == ["channel": "fizz", "place": "daily"])
            // Tomorrow's plan is a new day.
            service.plans[Self.code] = Self.plan(dayIndex: 20767)
            await model.refresh()
            #expect(!model.postedToday)
        }
    }

    @Test("a tap on the reminder and the smooth:// link both raise the open signal; the link also signs in")
    func openSignals() async throws {
        try await withModel { model, _, _, _ in
            #expect(!model.pendingOpen)
            model.noteReminderTapped()
            #expect(model.pendingOpen)
            model.consumePendingOpen()
            #expect(!model.pendingOpen)
            #expect(model.receive(url: URL(string: "smooth://pair?c=x")!) == false)
            #expect(model.receive(url: URL(string: "smooth://ambassador?code=\(Self.code)")!))
            #expect(model.pendingOpen)
            // The sign-in runs as a task; wait for it.
            for _ in 0..<50 where !model.isSignedIn { try await Task.sleep(for: .milliseconds(10)) }
            #expect(model.isSignedIn)
        }
    }

    @Test("offline keeps the cached plan and the sign-in; sign out forgets everything and the slot")
    func offlineAndSignOut() async {
        await withModel { model, service, center, defaults in
            await model.signIn(Self.code)
            service.offline = true
            await model.refresh()
            #expect(model.plan?.name == "Maya Example")
            #expect(model.isSignedIn)
            #expect(await model.markPostedToday() == false)
            #expect(model.lastError == "couldn\u{2019}t reach smooth")
            service.offline = false
            model.signOut()
            #expect(!model.isSignedIn)
            #expect(model.plan == nil)
            #expect(defaults.data(forKey: AmbassadorModel.planCacheKey) == nil)
            #expect(NotificationScheduler.reservedForeignSlots == 0)
            for _ in 0..<50 where !center.pending.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(center.pending.isEmpty)
        }
    }

    @Test("a stored code and cache come back on launch and reserve the slot before any reschedule")
    func restoredOnLaunch() async {
        let before = NotificationScheduler.reservedForeignSlots
        defer { NotificationScheduler.reservedForeignSlots = before }
        let suite = "ambassador-restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try! Self.plan().encoded(), forKey: AmbassadorModel.planCacheKey)
        defaults.set(AmbassadorReminderCadence.weekdays.rawValue, forKey: AmbassadorModel.cadenceKey)
        let model = AmbassadorModel(defaults: defaults, client: FakeAmbassadorService(), center: FakeAmbassadorCenter(),
                                    loadCode: { Self.code }, saveCode: { _ in }, removeCode: {})
        #expect(model.isSignedIn)
        #expect(model.plan?.schoolLabel == "uva")
        #expect(model.cadence == .weekdays)
        #expect(NotificationScheduler.reservedForeignSlots == 5)
    }
}

/// The wiring that `swift test` cannot exercise as behaviour, pinned as
/// source scans the way the Berserk tests pin `LHFApp.swift`.
@Suite("Ambassador wiring")
struct AmbassadorWiringTests {
    private func uiSource(_ filename: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/\(filename)")
        try #require(FileManager.default.fileExists(atPath: url.path), "\(url.path) is not there")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the reminder tap, the link, the planner's carve-out and the route are all in place")
    func wiring() throws {
        #expect(try uiSource("NotificationResponseRouter.swift").contains("AmbassadorReminders.isAmbassadorIdentifier(response.notification.request.identifier)"))
        #expect(try uiSource("RootView.swift").contains("AmbassadorModel.shared.receive(url: url)"))
        #expect(try uiSource("RootView.swift").contains("AmbassadorModel.shared.sceneBecameActive()"))
        #expect(try uiSource("BerserkAlarmDelivery.swift").contains("!AmbassadorReminders.isAmbassadorIdentifier($0)"))
        #expect(try uiSource("NotificationScheduler.swift").contains("Self.maxPending - buzzes.count - Self.reservedForeignSlots"))
        let content = try uiSource("ContentView.swift")
        #expect(content.contains("case .ambassador:"))
        #expect(content.contains("path = [.profile, .ambassador]"))
        let settings = try uiSource("SettingsPage.swift")
        #expect(settings.contains("NavigationLink(value: ContentView.DashRoute.ambassador)"))
    }

    @Test("ambassador mode never mentions ratings or reviews")
    func noReviews() throws {
        for file in ["AmbassadorPage.swift", "AmbassadorModel.swift", "AmbassadorReminders.swift"] {
            let source = try uiSource(file).lowercased()
            #expect(!source.contains("5 star") && !source.contains("five star") && !source.contains("rate the app"), "\(file)")
        }
    }
}
