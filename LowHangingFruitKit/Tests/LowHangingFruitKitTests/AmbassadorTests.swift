import CoreGraphics
import Foundation
import ImageIO
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

    /// Since 2026-11-11 the server puts the school in front of a new code
    /// (`uva-7k3m9x2p4q8w`). The app needed no change for it, and this pins
    /// why: a code is letters, digits and hyphens up to forty characters, so
    /// the longest school, `case-western`, still fits with room to spare.
    @Test("a code that starts with its school parses whole, in every shape, for every school")
    func schoolPrefixedCodes() {
        for school in ["upenn", "umiami", "uva", "case-western", "clark"] {
            let code = "\(school)-7k3m9x2p4q8wab"
            #expect(code.count <= AmbassadorCode.maximumLength)
            #expect(AmbassadorCode.parse(code) == code)
            #expect(AmbassadorCode.parse(code.uppercased()) == code)
            #expect(AmbassadorCode.parse("https://smooth-poster-scans.jazzysmile20.chatgpt.site/a/\(code)") == code)
            #expect(AmbassadorCode.parse("smooth://ambassador?code=\(code)") == code)
        }
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

    @Test("contacts decode element by element, read nil when absent, and make sms links")
    func contacts() throws {
        let good = Self.json.replacingOccurrences(of: "\"tips\"", with: "\"contacts\":[{\"name\":\"olisa\",\"phone\":\"+1 555 010 0100\"},{\"name\":\"x\"},7],\"tips\"")
        let plan = try AmbassadorPlan.decode(Data(good.utf8))
        #expect(plan.contacts == [.init(name: "olisa", phone: "+1 555 010 0100")])
        #expect(try AmbassadorPlan.decode(Data(Self.json.utf8)).contacts == nil)
        let bad = Self.json.replacingOccurrences(of: "\"tips\"", with: "\"contacts\":{\"a\":1},\"tips\"")
        #expect(try AmbassadorPlan.decode(Data(bad.utf8)).contacts == nil)
        #expect(AmbassadorPlan.Contact.smsURL(for: .init(name: "a", phone: "+1 (555) 010-0100"))?.absoluteString == "sms:+15550100100")
        #expect(AmbassadorPlan.Contact.smsURL(for: .init(name: "a", phone: "n/a")) == nil)
    }

    @Test("links decode as a map, and a wrong shape reads as none without costing the plan")
    func links() throws {
        let good = Self.json.replacingOccurrences(of: "\"tips\"", with: "\"links\":{\"gc\":\"https://example.test/r/k3m9x2p7qa/s/gc\"},\"tips\"")
        #expect(try AmbassadorPlan.decode(Data(good.utf8)).links?["gc"] == "https://example.test/r/k3m9x2p7qa/s/gc")
        let bad = Self.json.replacingOccurrences(of: "\"tips\"", with: "\"links\":[1,2],\"tips\"")
        let plan = try AmbassadorPlan.decode(Data(bad.utf8))
        #expect(plan.links == nil)
        #expect(plan.firstName == "Maya")
        #expect(try AmbassadorPlan.decode(Data(Self.json.utf8)).links == nil)
    }

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

    @Test("the school's download counts decode when present and are nil from an older server")
    func installNumbers() throws {
        let withInstalls = Self.json.replacingOccurrences(
            of: #""posts":1,"days":14}"#,
            with: #""posts":1,"days":14,"schoolInstalls":42,"schoolInstallsRecent":5}"#)
        let plan = try AmbassadorPlan.decode(Data(withInstalls.utf8))
        #expect(plan.numbers?.schoolInstalls == 42)
        #expect(plan.numbers?.schoolInstallsRecent == 5)
        let old = try AmbassadorPlan.decode(Data(Self.json.utf8))
        #expect(old.numbers?.schoolInstalls == nil)
        #expect(old.numbers?.schoolInstallsRecent == nil)
    }

    @Test("the bare minimum is a name and a school")
    func minimal() throws {
        let plan = try AmbassadorPlan.decode(Data(#"{"name":"J","school":"clark"}"#.utf8))
        #expect(plan.schoolLabel == "clark")
        #expect(plan.today == nil)
        #expect(plan.numbers == nil)
        #expect(throws: (any Error).self) { try AmbassadorPlan.decode(Data(#"{"school":"clark"}"#.utf8)) }
    }

    @Test("a reply beside today's post and a message decodes; an older server's plan has none")
    func replies() throws {
        let withReply = Self.json
            .replacingOccurrences(of: "\"text\":\"psa", with: "\"reply\":\"get it on the app store\",\"text\":\"psa")
            .replacingOccurrences(of: "\"text\":\"hi {x}\"", with: "\"text\":\"hi {x}\",\"reply\":\"and a reply\"")
        let plan = try AmbassadorPlan.decode(Data(withReply.utf8))
        #expect(plan.today?.reply == "get it on the app store")
        #expect(plan.messages?.first?.reply == "and a reply")
        let old = try AmbassadorPlan.decode(Data(Self.json.utf8))
        #expect(old.today?.reply == nil)
        #expect(old.messages?.first?.reply == nil)
    }

    @Test("a today and a message with a reply round-trip through JSON")
    func replyRoundTrip() throws {
        let today = AmbassadorPlan.Today(dayIndex: 3, kind: "anon", channel: "fizz", platform: "fizz",
                                         text: "a post", reply: "a reply")
        let todayBack = try JSONDecoder().decode(AmbassadorPlan.Today.self, from: JSONEncoder().encode(today))
        #expect(todayBack == today)
        #expect(todayBack.reply == "a reply")
        let message = AmbassadorPlan.Message(key: "k", label: "l", channel: "gc", text: "t", reply: "r")
        let messageBack = try JSONDecoder().decode(AmbassadorPlan.Message.self, from: JSONEncoder().encode(message))
        #expect(messageBack == message)
        #expect(messageBack.reply == "r")
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
        #expect(request.content.body == "today's anonymous post, maya. 1 a day.")
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

    @Test("twice a week is two weekly requests, Monday and Thursday; the picker offers three")
    func twiceWeekly() throws {
        let requests = AmbassadorReminders.requests(cadence: .twiceWeekly, hour: 19, minute: 0)
        let weekdays = try requests.map { try #require(($0.trigger as? UNCalendarNotificationTrigger)?.dateComponents.weekday) }
        #expect(weekdays == [2, 5])
        #expect(requests.map(\.identifier) == ["ambassador:weekday:2", "ambassador:weekday:5"])
        #expect(requests.allSatisfy { ($0.trigger as? UNCalendarNotificationTrigger)?.repeats == true })
        #expect(AmbassadorReminders.reservedSlots(for: .twiceWeekly) == 2)
        #expect(AmbassadorReminderCadence.offered == [.daily, .twiceWeekly, .off])
        #expect(AmbassadorReminderCadence.twiceWeekly.label == "2 a week")
        // A phone that stored the retired choice still decodes it.
        #expect(AmbassadorReminderCadence(rawValue: "weekdays") == .weekdays)
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
    var ideas: [(code: String, note: String, image: Data?)] = []
    var ideaError: AmbassadorClientError?
    var captures: [(code: String, fields: [String: String])] = []
    /// Thrown by `sendCapture` once `failCapturesAfter` have been accepted.
    var captureError: AmbassadorClientError?
    var failCapturesAfter = 0

    func sendCapture(code: String, fields: [String: String]) async throws {
        if offline { throw AmbassadorClientError.network }
        if let captureError, captures.count >= failCapturesAfter { throw captureError }
        guard plans[code] != nil else { throw AmbassadorClientError.unknownCode }
        captures.append((code, fields))
    }

    func sendIdea(code: String, note: String, imageJPEG: Data?) async throws {
        if offline { throw AmbassadorClientError.network }
        if let ideaError { throw ideaError }
        guard plans[code] != nil else { throw AmbassadorClientError.unknownCode }
        ideas.append((code, note, imageJPEG))
    }

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

/// A settable clock for the model's day index: midday, in the model's -5 h
/// zone, of day 20766, the plan's own index in `AmbassadorModelTests.plan`.
final class ModelClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 20766 * 86_400 + 17 * 3600)
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
        clock: ModelClock = ModelClock(),
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
                                    // A fixed offset, not New York: New York is 240 west of
                                    // UTC for eight months of the year. The clock is fixed at
                                    // midday of the plan's day (index 20766).
                                    timeZone: TimeZone(secondsFromGMT: -5 * 3600)!,
                                    now: { clock.now })
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
            #expect(center.pending.map(\.identifier).sorted() == ["ambassador:daily"])
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
        let clock = ModelClock()
        await withModel(clock: clock) { model, service, _, _ in
            await model.signIn(Self.code)
            #expect(!model.postedToday)
            #expect(await model.markPostedToday())
            #expect(model.postedToday)
            #expect(service.sent.last?.action == "post")
            #expect(service.sent.last?.body == ["channel": "fizz", "place": "daily"])
            // Tomorrow: the phone's own day rolls over and so does the plan.
            clock.now = clock.now.addingTimeInterval(86_400)
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

    @Test("every sign-in raises the intro; finishing it clears it")
    func intro() async {
        await withModel { model, _, _, defaults in
            #expect(!model.introPending)
            await model.signIn(Self.code)
            #expect(model.introPending)
            model.finishIntro()
            #expect(!model.introPending)
            model.signOut()
            await model.signIn(Self.code)
            #expect(model.introPending)
        }
    }

    @Test("a group-chat drop posts in the gc channel and ticks for the week")
    func groupChatsDone() async {
        await withModel { model, service, _, _ in
            await model.signIn(Self.code)
            #expect(!model.isDone(.groupChats))
            await model.markDone(.groupChats)
            #expect(model.isDone(.groupChats))
            let sent = service.sent.last
            #expect(sent?.action == "post")
            #expect(sent?.body["channel"] == "gc")
            #expect(!model.isDone(.posters))
            // Posters are the slider's, not the log's: a tick changes nothing.
            await model.markDone(.posters)
            #expect(!model.isDone(.posters))
        }
    }

    @Test("the anonymous task ticks with the daily post, and a tick comes back after a relaunch")
    func anonDoneAndRestored() async {
        await withModel { model, service, _, defaults in
            await model.signIn(Self.code)
            await model.markDone(.anonChats)
            #expect(model.isDone(.anonChats))
            #expect(model.postedToday)
            #expect(service.sent.contains { $0.action == "post" && $0.body["channel"] == "fizz" })
            let data = defaults.data(forKey: AmbassadorModel.taskLogKey)
            #expect(data != nil)
            let log = try? JSONDecoder().decode(AmbassadorTaskLog.self, from: data ?? Data())
            #expect(log?.isDone(.anonChats, todayIndex: 20766) == true)
        }
    }

    @Test("sending feedback ticks the feedback task; a failed send does not; sign out clears the log")
    func feedbackDone() async {
        await withModel { model, service, _, defaults in
            await model.signIn(Self.code)
            service.offline = true
            #expect(await model.sendFeedback("hello") == false)
            #expect(!model.isDone(.feedback))
            service.offline = false
            #expect(await model.sendFeedback("hello"))
            #expect(model.isDone(.feedback))
            model.signOut()
            #expect(!model.isDone(.feedback))
            #expect(model.taskLog == AmbassadorTaskLog())
            #expect(defaults.data(forKey: AmbassadorModel.taskLogKey) == nil)
        }
    }

    @Test("with nothing stored the reminder defaults to every day")
    func defaultCadence() async {
        await withModel { model, _, _, _ in
            #expect(model.cadence == .daily)
        }
    }

    @Test("an anonymous tick logs today's day; the week count follows")
    func anonWeek() async {
        await withModel { model, _, _, _ in
            await model.signIn(Self.code)
            #expect(model.anonPostsThisWeek == 0)
            #expect(!model.anonWeeklyMinimumMet)
            await model.markDone(.anonChats)
            #expect(model.taskLog.anonDays == [20766])
            #expect(model.anonPostsThisWeek == 1)
            #expect(model.anonWeeklyMinimumMet)
            #expect(model.anonWeekDots == [false, false, false, false, false, false, true])
        }
    }

    @Test("posters are done at 30 and not before; sign out clears the count")
    func postersGoal() async {
        await withModel { model, _, _, defaults in
            await model.signIn(Self.code)
            model.setPostersPutUp(29)
            #expect(!model.isDone(.posters))
            model.setPostersPutUp(30)
            #expect(model.isDone(.posters))
            model.setPostersPutUp(99)
            #expect(model.postersPutUp == 30)
            model.signOut()
            #expect(model.postersPutUp == 0)
            #expect(defaults.object(forKey: AmbassadorModel.postersPutUpKey) == nil)
        }
    }

    @Test("requestOpen raises the open signal")
    func requestOpen() async {
        await withModel { model, _, _, _ in
            #expect(!model.pendingOpen)
            model.requestOpen()
            #expect(model.pendingOpen)
        }
    }

    @Test("an idea with nothing in it is refused in words and sends no request")
    func emptyIdea() async {
        await withModel { model, service, _, _ in
            await model.signIn(Self.code)
            let before = service.planRequests.count
            #expect(await model.sendPosterIdea(note: "  \n ", imageData: nil) == false)
            #expect(model.lastError == "add a picture or a note")
            #expect(service.ideas.isEmpty)
            #expect(service.planRequests.count == before)
        }
    }

    @Test("a note-only idea is sent trimmed and the plan is fetched again")
    func noteIdea() async {
        await withModel { model, service, _, _ in
            await model.signIn(Self.code)
            let before = service.planRequests.count
            #expect(await model.sendPosterIdea(note: "  a funnel poster  ", imageData: nil))
            #expect(service.ideas.count == 1)
            #expect(service.ideas.first?.code == Self.code)
            #expect(service.ideas.first?.note == "a funnel poster")
            #expect(service.ideas.first?.image == nil)
            #expect(service.planRequests.count == before + 1)
            #expect(model.lastError == nil)
        }
    }

    @Test("a picture that is not an image is refused before anything is sent")
    func unreadablePicture() async {
        await withModel { model, service, _, _ in
            await model.signIn(Self.code)
            #expect(await model.sendPosterIdea(note: "", imageData: Data([1, 2, 3, 4])) == false)
            #expect(model.lastError == "couldn\u{2019}t read that picture")
            #expect(service.ideas.isEmpty)
        }
    }

    @Test("a real picture is sent as a prepared JPEG")
    func pictureIdea() async throws {
        let png = try #require(PosterImageFixtures.png(width: 3000, height: 2000))
        try await withModel { model, service, _, _ in
            await model.signIn(Self.code)
            #expect(await model.sendPosterIdea(note: "", imageData: png))
            let sent = try #require(service.ideas.first?.image)
            #expect(Array(sent.prefix(3)) == [0xFF, 0xD8, 0xFF])
            #expect(sent.count <= 600_000)
        }
    }

    @Test("the server's refusals become short lowercase lines")
    func ideaErrors() async {
        await withModel { model, service, _, _ in
            await model.signIn(Self.code)
            service.ideaError = .limitReached
            #expect(await model.sendPosterIdea(note: "x", imageData: nil) == false)
            #expect(model.lastError == "that\u{2019}s the limit for today")
            service.ideaError = .tooLarge
            #expect(await model.sendPosterIdea(note: "x", imageData: nil) == false)
            #expect(model.lastError == "that picture is too big")
            service.ideaError = .unknownCode
            #expect(await model.sendPosterIdea(note: "x", imageData: nil) == false)
            #expect(model.lastError == "this code no longer works")
            service.ideaError = .badResponse(500)
            #expect(await model.sendPosterIdea(note: "x", imageData: nil) == false)
            #expect(model.lastError == "couldn\u{2019}t reach smooth")
        }
    }
}

// MARK: - Poster gallery and idea box

enum PosterImageFixtures {
    /// An opaque RGB picture, PNG-encoded, for the image tests.
    static func png(width: Int, height: Int) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The pixel size of encoded image data.
    static func size(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

@Suite("Ambassador posters in the plan")
struct AmbassadorPosterPlanTests {
    static let base = #"{"name":"Maya","school":"uva""#

    @Test("the three new fields decode when present")
    func present() throws {
        let json = Self.base + #"""
        ,"posters":[{"key":"ib","name":"Funneled into IB","image":"https://example.test/posters/uva/ib.jpg","scans":12},
                    {"key":"cs","name":"CS","image":"https://example.test/posters/uva/cs.jpg"}],
         "dashboard":"https://example.test/?school=uva",
         "ideas":{"sent":3,"limit":30,"dailyLimit":5}}
        """#
        let plan = try AmbassadorPlan.decode(Data(json.utf8))
        #expect(plan.posters?.count == 2)
        #expect(plan.posters?.first?.scans == 12)
        #expect(plan.posters?.last?.scans == nil)
        #expect(plan.dashboardURL?.absoluteString == "https://example.test/?school=uva")
        #expect(plan.ideas == AmbassadorPlan.Ideas(sent: 3, limit: 30, dailyLimit: 5))
        #expect(plan.posters?.first?.imageURL?.host == "example.test")
        let again = try AmbassadorPlan.decode(plan.encoded())
        #expect(again == plan)
    }

    @Test("an older server omits them and the plan still decodes")
    func absent() throws {
        let plan = try AmbassadorPlan.decode(Data((Self.base + "}").utf8))
        #expect(plan.posters == nil)
        #expect(plan.dashboard == nil)
        #expect(plan.dashboardURL == nil)
        #expect(plan.ideas == nil)
    }

    @Test("one malformed poster is dropped and the rest survive")
    func lossy() throws {
        let json = Self.base + #"""
        ,"posters":[{"key":"a","name":"A","image":"https://example.test/a.jpg"},
                    {"key":"broken","name":"no image"},
                    {"key":7,"name":"wrong type","image":"https://example.test/x.jpg"},
                    {"key":"b","name":"B","image":"https://example.test/b.jpg","scans":2}]}
        """#
        let plan = try AmbassadorPlan.decode(Data(json.utf8))
        #expect(plan.posters?.map(\.key) == ["a", "b"])
    }

    @Test("a wrongly shaped ideas or dashboard reads as absent, not as a failed plan")
    func wrongShapes() throws {
        let plan = try AmbassadorPlan.decode(Data((Self.base + #","ideas":"many","dashboard":5}"#).utf8))
        #expect(plan.ideas == nil)
        #expect(plan.dashboard == nil)
        #expect(plan.name == "Maya")
    }

    @Test("only https links are ever used")
    func httpsOnly() {
        #expect(AmbassadorPlan(name: "a", school: "b", dashboard: "http://example.test/").dashboardURL == nil)
        #expect(AmbassadorPlan(name: "a", school: "b", dashboard: "javascript:alert(1)").dashboardURL == nil)
        #expect(AmbassadorPlan(name: "a", school: "b", dashboard: "https://example.test/").dashboardURL != nil)
        #expect(AmbassadorPlan.Poster(key: "k", name: "n", image: "http://example.test/a.jpg").imageURL == nil)
        #expect(AmbassadorPlan.Poster(key: "k", name: "n", image: "file:///etc/passwd").imageURL == nil)
        #expect(AmbassadorPlan.Poster(key: "k", name: "n", image: "https://example.test/a.jpg").imageURL != nil)
    }
}

@Suite("Poster idea picture")
struct PosterIdeaImageTests {
    @Test("a large photo becomes a small JPEG with no more than 1280 on its long side")
    func shrinks() throws {
        let png = try #require(PosterImageFixtures.png(width: 3000, height: 2000))
        let jpeg = try #require(PosterIdeaImage.prepared(from: png))
        #expect(Array(jpeg.prefix(3)) == [0xFF, 0xD8, 0xFF])
        #expect(jpeg.count <= 600_000)
        let size = try #require(PosterImageFixtures.size(of: jpeg))
        #expect(max(size.width, size.height) <= 1280)
        #expect(max(size.width, size.height) > 1000)
    }

    @Test("a small picture is not made bigger")
    func neverUpsizes() throws {
        let png = try #require(PosterImageFixtures.png(width: 200, height: 100))
        let jpeg = try #require(PosterIdeaImage.prepared(from: png))
        let size = try #require(PosterImageFixtures.size(of: jpeg))
        #expect(size.width == 200)
        #expect(size.height == 100)
    }

    @Test("bytes that are not an image, and no bytes, give nothing")
    func notAnImage() {
        #expect(PosterIdeaImage.prepared(from: Data((0..<2000).map { _ in UInt8.random(in: 0...255) })) == nil)
        #expect(PosterIdeaImage.prepared(from: Data()) == nil)
    }
}

/// Answers every request with a canned status and keeps the last request, so
/// the client's POSTs can be read without a network. `.serialized` on the
/// suite: the handler and capture are process-wide.
final class IdeaStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Ambassador client: ideas", .serialized)
struct AmbassadorIdeaClientTests {
    private func client() -> AmbassadorClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IdeaStubProtocol.self]
        return AmbassadorClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: config))
    }

    private func sentJSON() throws -> [String: String] {
        let body = try #require(IdeaStubProtocol.lastBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
    }

    @Test("an idea POSTs to /a/{code}/idea with note, image and type")
    func request() async throws {
        IdeaStubProtocol.status = 200
        try await client().sendIdea(code: "abc123code", note: "hi", imageJPEG: Data([0xFF, 0xD8, 0xFF]))
        let request = try #require(IdeaStubProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/a/abc123code/idea")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try sentJSON()
        #expect(json["note"] == "hi")
        #expect(json["type"] == "image/jpeg")
        #expect(json["image"] == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
    }

    @Test("a note-only idea omits image and type")
    func noteOnly() async throws {
        IdeaStubProtocol.status = 200
        try await client().sendIdea(code: "abc123code", note: "just words", imageJPEG: nil)
        let json = try sentJSON()
        #expect(json == ["note": "just words"])
    }

    @Test("413, 429 and 404 each have their own error; another status is a bad response")
    func statuses() async {
        let cases: [(Int, AmbassadorClientError)] = [(413, .tooLarge), (429, .limitReached),
                                                     (404, .unknownCode), (500, .badResponse(500))]
        for (status, expected) in cases {
            IdeaStubProtocol.status = status
            do {
                try await client().sendIdea(code: "abc123code", note: "x", imageJPEG: nil)
                Issue.record("status \(status) did not throw")
            } catch {
                #expect(error as? AmbassadorClientError == expected, "\(status)")
            }
        }
    }
}

/// The wiring that `swift test` cannot exercise as behaviour, pinned as
/// source scans the way the Berserk tests pin `LHFApp.swift`.
@Suite("Ambassador tasks")
struct AmbassadorTaskTests {
    @Test("four tasks in order, the anonymous one daily and the rest weekly")
    func cases() {
        #expect(AmbassadorTask.allCases == [.anonChats, .groupChats, .posters, .feedback])
        #expect(AmbassadorTask.allCases.map(\.label) == ["anonymous chats", "group chats", "posters", "feedback"])
        #expect(AmbassadorTask.anonChats.period == .day)
        for task in [AmbassadorTask.groupChats, .posters, .feedback] { #expect(task.period == .week) }
    }

    @Test("a day task is done on its own day only")
    func dayRule() {
        var log = AmbassadorTaskLog()
        #expect(!log.isDone(.anonChats, todayIndex: 100))
        log.markDone(.anonChats, todayIndex: 100)
        #expect(log.isDone(.anonChats, todayIndex: 100))
        #expect(!log.isDone(.anonChats, todayIndex: 101))
        #expect(!log.isDone(.anonChats, todayIndex: 99))
    }

    @Test("a week task holds for the day and six more, never from the future")
    func weekRule() {
        var log = AmbassadorTaskLog()
        log.markDone(.posters, todayIndex: 100)
        #expect(log.isDone(.posters, todayIndex: 100))
        #expect(log.isDone(.posters, todayIndex: 106))
        #expect(!log.isDone(.posters, todayIndex: 107))
        #expect(!log.isDone(.posters, todayIndex: 99))
        #expect(!log.isDone(.feedback, todayIndex: 100))
    }

    @Test("a log saved before anonDays existed decodes with an empty set")
    func oldLog() throws {
        let log = try JSONDecoder().decode(AmbassadorTaskLog.self, from: Data(#"{"doneDayIndex":{"posters":5}}"#.utf8))
        #expect(log.anonDays.isEmpty)
        #expect(log.isDone(.posters, todayIndex: 5))
    }

    @Test("the week is today and the six days before; the future is ignored")
    func anonWeek() {
        var log = AmbassadorTaskLog()
        #expect(!log.anonWeeklyMinimumMet(todayIndex: 100))
        log.markDone(.anonChats, todayIndex: 94)
        #expect(log.anonPostsInLastWeek(todayIndex: 100) == 1)
        #expect(log.anonWeeklyMinimumMet(todayIndex: 100))
        #expect(log.anonPostsInLastWeek(todayIndex: 101) == 0)
        #expect(!log.anonWeeklyMinimumMet(todayIndex: 101))
        log.markDone(.anonChats, todayIndex: 100)
        log.markDone(.anonChats, todayIndex: 103)
        #expect(log.anonPostsInLastWeek(todayIndex: 100) == 2)
        #expect(log.anonPostedDays(todayIndex: 100) == [true, false, false, false, false, false, true])
    }

    @Test("the log round-trips")
    func codable() throws {
        var log = AmbassadorTaskLog()
        log.markDone(.groupChats, todayIndex: 7)
        let back = try JSONDecoder().decode(AmbassadorTaskLog.self, from: JSONEncoder().encode(log))
        #expect(back == log)
        #expect(back.isDone(.groupChats, todayIndex: 7))
    }
}

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
        // Its own destination since 2026-11-22: back goes to the dashboard.
        #expect(content.contains("path = [.ambassador]"))
        #expect(!content.contains("path = [.profile, .ambassador]"))
        let settings = try uiSource("SettingsPage.swift")
        #expect(settings.contains("AmbassadorModel.shared.requestOpen()"))
        #expect(!settings.contains("NavigationLink(value: ContentView.DashRoute.ambassador)"))
    }

    /// Olisa, 2026-11-19: the bank is his two Sidechat posts and nothing
    /// else, and neither carries a pitch. The pitch is the reply, so a post
    /// without its reply on the page is half of what he asked for.
    @Test("the page draws a post's reply with its own copy button")
    func replyShown() throws {
        let page = try uiSource("AmbassadorTaskSheets.swift")
        #expect(page.contains("copy reply"))
        #expect(page.contains("then reply:"))
    }

    /// The posts are the server's and the plan is cached for half an hour,
    /// so without a pull a changed bank stays invisible on the phone.
    @Test("pulling the page down fetches the plan again")
    func pullToRefresh() throws {
        let page = try uiSource("AmbassadorPage.swift")
        #expect(page.contains(".refreshable { await model.refresh() }"))
    }

    /// Marco, 2026-11-21: the page is four tasks, then the numbers, the
    /// reminder and the account rows. The job, the playbook, the founders'
    /// posts, the feed recording and the results sheets are gone from it; the
    /// job's one line lives in the first-sign-in intro.
    @Test("the page opens on the four tasks, then numbers, reminder, account")
    func tasksFirst() throws {
        let page = try uiSource("AmbassadorPage.swift")
        let body = try #require(page.range(of: "if model.isSignedIn {"))
        func at(_ name: String) throws -> String.Index {
            try #require(page.range(of: name, range: body.upperBound..<page.endIndex)).lowerBound
        }
        let goal = try at("goalSection")
        let tasks = try at("tasksSection")
        #expect(goal < tasks)
        let numbers = try at("numbersSection")
        let reminders = try at("remindersSection")
        let account = try at("accountSection")
        #expect(tasks < numbers && numbers < reminders && reminders < account)
        for gone in ["jobSection", "playbookSection", "suggestedSection", "todaySection", "trackingSection",
                     "messagesSection", "feedbackSection", "postersSection", "FeedRecordingSheet", "PostResultSheet",
                     "get smooth in front of as many eyes", "checklistSection", "setChecklist"] {
            #expect(!page.contains(gone), "\(gone)")
        }
        let intro = try uiSource("AmbassadorIntroView.swift")
        #expect(intro.contains("get smooth in front of as many eyes as you can."))
        #expect(intro.contains("let\\u{2019}s go"))
        // The web page is one plain row in the account section.
        #expect(page.components(separatedBy: "web page \\u{2197}").count == 2)
        let acct = try #require(page.range(of: "private var accountSection"))
        let link = try #require(page.range(of: "my web page"))
        #expect(acct.lowerBound < link.lowerBound)
        // The picker offers the cadences in `offered`, never every case.
        #expect(page.contains("AmbassadorReminderCadence.offered"))
        #expect(!page.contains("my anonymous app"))
        #expect(try uiSource("AmbassadorTaskSheets.swift").contains("my anonymous app"))
    }

    @Test("the posters sheet is a goal and a slider with no done row; the chats sheet leads with 1 a day")
    func sheets() throws {
        let sheets = try uiSource("AmbassadorTaskSheets.swift")
        let posters = try #require(sheets.range(of: "struct AmbassadorPostersTaskSheet"))
        let feedback = try #require(sheets.range(of: "// MARK: Feedback"))
        let body = String(sheets[posters.lowerBound..<feedback.lowerBound])
        #expect(body.contains("Slider("))
        #expect(body.contains("posters put up"))
        #expect(!body.contains("AmbassadorDoneRow(task: .posters"))
        #expect(sheets.contains("goal: 1 post a day"))
        #expect(sheets.contains("streak: "))
        #expect(!sheets.contains("more messages"))
        #expect(!sheets.contains("at least 1"))
        #expect(try uiSource("AmbassadorIntroView.swift").contains("downloads at"))
        #expect(sheets.contains("posted today"))
        #expect(sheets.contains("AmbassadorGuidance.bundled"))
        #expect(sheets.contains("example post"))
        #expect(!sheets.contains("prompts"))
        #expect(try uiSource("AmbassadorPage.swift").contains("AmbassadorGoals.caption"))
    }

    @Test("the numbers section shows the school's downloads only when the server sent them")
    func downloadsRow() throws {
        let page = try uiSource("AmbassadorPage.swift")
        #expect(page.contains(#"\(plan.schoolLabel) downloads"#))
        #expect(page.contains("if let installs = n.schoolInstalls"))
    }

    @Test("the contacts section is last and invites the question")
    func contactsLast() throws {
        let page = try uiSource("AmbassadorPage.swift")
        let body = try #require(page.range(of: "if model.isSignedIn {"))
        let account = try #require(page.range(of: "accountSection", range: body.upperBound..<page.endIndex))
        let contacts = try #require(page.range(of: "contactsSection", range: account.upperBound..<page.endIndex))
        #expect(account.lowerBound < contacts.lowerBound)
        #expect(page.contains("tell us"))
    }

    @Test("ambassador mode never mentions ratings or reviews")
    func noReviews() throws {
        for file in ["AmbassadorPage.swift", "AmbassadorModel.swift", "AmbassadorReminders.swift",
                     "AmbassadorPostersView.swift", "PosterIdeaSheet.swift",
                     "AmbassadorIntroView.swift", "AmbassadorTaskSheets.swift"] {
            let source = try uiSource(file).lowercased()
            #expect(!source.contains("5 star") && !source.contains("five star") && !source.contains("rate the app"), "\(file)")
        }
    }
}

// MARK: - Playbook, suggestions and captures (2026-11-18)

@Suite("Ambassador playbook and captures in the plan")
struct AmbassadorCapturePlanTests {
    static let base = #"{"name":"Maya","school":"uva""#

    @Test("all three new keys decode when present")
    func present() throws {
        let json = Self.base + #"""
        ,"playbook":{"lead":"the posts that work don't look like ads.","steps":["one","two"],
           "examples":[{"key":"question","title":"ask the question","post":"What do you use?","reply":"Smooth","score":"22 upvotes at penn","why":"it's a question"},
                       {"key":"list","title":"slip it into a list","post":"a\nb"}]},
         "suggested":[{"id":3,"text":"hello","reply":"world","ts":"2026-11-18T12:00:00.000Z"},{"id":4,"text":"bare"}],
         "captures":{"feed":{"framesPerRecording":16,"frameBytes":200000,"sentToday":0,"dailyLimit":32,"stored":3,"limit":96},
                     "results":{"imageBytes":300000,"sentToday":0,"dailyLimit":8,"stored":0,"limit":60},
                     "styles":[{"key":"question","label":"question"},{"key":"list","label":"slipped into a list"}]}}
        """#
        let plan = try AmbassadorPlan.decode(Data(json.utf8))
        #expect(plan.playbook?.steps == ["one", "two"])
        #expect(plan.playbook?.examples.count == 2)
        #expect(plan.playbook?.examples.first?.score == "22 upvotes at penn")
        #expect(plan.playbook?.examples.last?.reply == nil)
        #expect(plan.suggested?.map(\.id) == [3, 4])
        #expect(plan.suggested?.last?.reply == nil)
        #expect(plan.captures?.feed?.stored == 3)
        #expect(plan.captures?.feed?.limit == 96)
        #expect(plan.captures?.results?.dailyLimit == 8)
        #expect(plan.captures?.styles?.map(\.key) == ["question", "list"])
        let again = try AmbassadorPlan.decode(plan.encoded())
        #expect(again == plan)
    }

    @Test("an older server omits them and the plan still decodes with nils")
    func absent() throws {
        let plan = try AmbassadorPlan.decode(Data((Self.base + "}").utf8))
        #expect(plan.playbook == nil)
        #expect(plan.suggested == nil)
        #expect(plan.captures == nil)
    }

    @Test("a malformed captures, playbook or suggested reads as absent and the rest survives")
    func malformed() throws {
        let plan = try AmbassadorPlan.decode(Data((Self.base + #","captures":"lots","playbook":7,"suggested":"x"}"#).utf8))
        #expect(plan.captures == nil)
        #expect(plan.playbook == nil)
        #expect(plan.suggested == nil)
        #expect(plan.name == "Maya")
        let partial = try AmbassadorPlan.decode(Data((Self.base + #","suggested":[{"id":1,"text":"ok"},{"id":"bad"}]}"#).utf8))
        #expect(partial.suggested?.map(\.id) == [1])
    }
}

@Suite("Feed recording frames")
struct FeedRecordingFramesTests {
    @Test("no times for a duration that is not a positive finite number")
    func empty() {
        for duration in [0, -3, Double.nan, Double.infinity, -Double.infinity] {
            #expect(FeedRecordingFrames.sampleTimes(duration: duration).isEmpty)
        }
    }

    @Test("counts and bounds for clips of different lengths")
    func counts() {
        #expect(FeedRecordingFrames.sampleTimes(duration: 1).count == 1)
        let six = FeedRecordingFrames.sampleTimes(duration: 6)
        #expect(six.count == 3 || six.count == 4)
        #expect(FeedRecordingFrames.sampleTimes(duration: 30).count > 4)
        #expect(FeedRecordingFrames.sampleTimes(duration: 30).count <= 16)
        #expect(FeedRecordingFrames.sampleTimes(duration: 120).count == 16)
        #expect(FeedRecordingFrames.sampleTimes(duration: 120, maxFrames: 5).count == 5)
    }

    @Test("times are strictly inside the clip, ascending and never closer than the spacing")
    func spacing() {
        for duration in [0.4, 1, 2.5, 6, 9, 30, 120, 600] as [Double] {
            let times = FeedRecordingFrames.sampleTimes(duration: duration)
            #expect(!times.isEmpty, "\(duration)")
            #expect(times.allSatisfy { $0 > 0 && $0 < duration }, "\(duration)")
            #expect(times == times.sorted(), "\(duration)")
            if times.count > 1 {
                let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
                #expect(gaps.allSatisfy { $0 >= 1.5 - 1e-9 }, "\(duration)")
            }
        }
    }

    @Test("a batch id is twelve of a-z0-9 and a second one differs")
    func batchID() {
        let first = FeedRecordingFrames.newBatchID()
        let second = FeedRecordingFrames.newBatchID()
        #expect(first.range(of: "^[a-z0-9]{12}$", options: .regularExpression) != nil)
        #expect(first != second)
    }

    @Test("a decoded picture goes through the same shrink and encode path")
    func cgImageEntry() throws {
        let png = try #require(PosterImageFixtures.png(width: 3000, height: 2000))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let jpeg = try #require(PosterIdeaImage.prepared(cgImage: image, maxDimension: 1200, maxBytes: 200_000))
        #expect(Array(jpeg.prefix(3)) == [0xFF, 0xD8, 0xFF])
        #expect(jpeg.count <= 200_000)
        let size = try #require(PosterImageFixtures.size(of: jpeg))
        #expect(max(size.width, size.height) <= 1200)
    }
}

@Suite("Ambassador capture bodies")
struct AmbassadorCaptureBodyTests {
    @Test("a feed still carries kind, batch, a decimal seq and base64")
    func feed() {
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let body = AmbassadorClient.feedFrameBody(batch: "abc123def456", seq: 11, jpeg: jpeg)
        #expect(body == ["kind": "feed", "batch": "abc123def456", "seq": "11", "image": jpeg.base64EncodedString()])
    }

    @Test("a result omits upvotes, views and note when they are not given")
    func resultOptional() {
        let jpeg = Data([1, 2, 3])
        let bare = AmbassadorClient.resultBody(jpeg: jpeg, platform: "fizz", style: "list", upvotes: nil, views: nil, note: "  ")
        #expect(bare == ["kind": "result", "image": jpeg.base64EncodedString(), "platform": "fizz", "style": "list"])
        let full = AmbassadorClient.resultBody(jpeg: jpeg, platform: "yikyak", style: "pitch", upvotes: 123, views: 4500, note: "ok")
        #expect(full["upvotes"] == "123")
        #expect(full["views"] == "4500")
        #expect(full["note"] == "ok")
        #expect(Set(full.keys) == ["kind", "image", "platform", "style", "upvotes", "views", "note"])
    }
}

@MainActor
@Suite("Ambassador capture uploads", .serialized)
struct AmbassadorCaptureModelTests {
    private func withModel(_ body: @MainActor (AmbassadorModel, FakeAmbassadorService) async throws -> Void) async rethrows {
        let before = NotificationScheduler.reservedForeignSlots
        defer { NotificationScheduler.reservedForeignSlots = before }
        let suite = "ambassador-capture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeAmbassadorService()
        service.plans[AmbassadorModelTests.code] = AmbassadorModelTests.plan()
        final class Box: @unchecked Sendable { var code: String?; init(_ c: String?) { code = c } }
        let box = Box(AmbassadorModelTests.code)
        let model = AmbassadorModel(defaults: defaults, client: service, center: FakeAmbassadorCenter(),
                                    loadCode: { box.code }, saveCode: { box.code = $0 }, removeCode: { box.code = nil },
                                    timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
        try await body(model, service)
    }

    @Test("every still goes under one batch id with seq 0...n-1")
    func oneBatch() async {
        await withModel { model, service in
            let frames = (0..<3).map { Data([UInt8($0), 0xFF]) }
            #expect(await model.sendFeedFrames(frames) == true)
            #expect(service.captures.count == 3)
            #expect(service.captures.map { $0.fields["seq"] } == ["0", "1", "2"])
            #expect(Set(service.captures.compactMap { $0.fields["batch"] }).count == 1)
            #expect(service.captures.allSatisfy { $0.fields["kind"] == "feed" })
            #expect(model.feedProgress == nil)
            #expect(model.lastError == nil)
        }
    }

    @Test("a 429 stops the upload and says so")
    func limit() async {
        await withModel { model, service in
            service.captureError = .limitReached
            service.failCapturesAfter = 2
            let frames = (0..<5).map { Data([UInt8($0)]) }
            #expect(await model.sendFeedFrames(frames) == false)
            #expect(service.captures.count == 2)
            #expect(model.lastError == "that\u{2019}s the limit for today")
            #expect(model.feedProgress == nil)
        }
    }

    @Test("no frames is an error and sends nothing")
    func noFrames() async {
        await withModel { model, service in
            #expect(await model.sendFeedFrames([]) == false)
            #expect(model.lastError == "couldn\u{2019}t read that recording")
            #expect(service.captures.isEmpty)
        }
    }

    @Test("a result with an undecodable picture sends nothing")
    func badPicture() async {
        await withModel { model, service in
            let ok = await model.sendPostResult(imageData: Data([1, 2, 3, 4]), platform: "fizz", style: "list",
                                                upvotes: nil, views: nil, note: "")
            #expect(ok == false)
            #expect(model.lastError == "couldn\u{2019}t read that picture")
            #expect(service.captures.isEmpty)
        }
    }

    @Test("a result with a real picture is sent as a result")
    func goodPicture() async throws {
        let png = try #require(PosterImageFixtures.png(width: 400, height: 300))
        await withModel { model, service in
            let ok = await model.sendPostResult(imageData: png, platform: "sidechat", style: "question",
                                                upvotes: 12, views: nil, note: "hi")
            #expect(ok == true)
            let sent = service.captures.first?.fields
            #expect(sent?["kind"] == "result")
            #expect(sent?["upvotes"] == "12")
            #expect(sent?["views"] == nil)
            #expect(sent?["note"] == "hi")
        }
    }
}

@Suite("Ambassador capture wiring")
struct AmbassadorCaptureWiringTests {
    private func page() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/AmbassadorPage.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the four tasks are listed in order and the page presents the intro")
    func order() throws {
        let kit = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitKit/Ambassador/AmbassadorTask.swift")
        let task = try String(contentsOf: kit, encoding: .utf8)
        var from = task.startIndex
        for label in ["anonymous chats", "group chats", "posters", "feedback"] {
            let hit = try #require(task.range(of: "return \"\(label)\"", range: from..<task.endIndex), Comment(rawValue: label))
            from = hit.upperBound
        }
        let page = try page()
        #expect(page.contains("ForEach(AmbassadorTask.allCases)"))
        #expect(page.contains("AmbassadorIntroView()"))
        #expect(page.contains("AmbassadorTaskSheet(task: task)"))
        #expect(!page.contains("FeedRecordingSheet()") && !page.contains("PostResultSheet()"))
    }
}

/// The dashboard header once signed in as an ambassador (2026-11-12).
@Suite("Ambassador header")
struct AmbassadorHeaderTests {
    private func uiSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the header swaps Smooth {weekday} for the badge and Ambassador only while signed in")
    func headerSwapsOnlyWhenSignedIn() throws {
        let source = try uiSource("ContentView.swift")
        let header = try #require(source.range(of: "private var header: some View"))
        let body = source[header.lowerBound...]
        #expect(body.contains("if ambassador.isSignedIn {"))
        #expect(body.contains("ambassadorTitle(pointSize: size)"))
        #expect(body.contains("headerTitle(weekday: weekday, pointSize: size)"))
        // The same view as the wordmark, so a tap squiggles and shines, with
        // the medal as a header-style squircle, and the tap opens the page.
        #expect(source.contains("text: \"Ambassador\""))
        #expect(source.contains("headerButton(icon: Self.ambassadorBadgeSymbol"))
        let titleStart = try #require(source.range(of: "private func ambassadorTitle"))
        let titleBody = String(source[titleStart.lowerBound...].prefix(1400))
        #expect(!titleBody.contains("badge: Self.ambassadorBadgeSymbol"))
        #expect(source.contains("path = [.ambassador]"))
        #expect(!source.contains("path = [.profile, .ambassador]"))
        #expect(source.contains("var badgeSize: CGFloat? = nil"))
        #expect(source.contains("AmbassadorStatsLine("))
        #expect(!source.contains("AmbassadorStatsCard("))
        // No date line for an ambassador (Marco, 2026-11-22): the stats line
        // takes its place, and it ends "so far".
        #expect(!source.contains("AmbassadorDateLine.text("))
        #expect(try uiSource("AmbassadorStatsCard.swift").contains("users at \\(schoolLabel) so far"))
        #expect(try uiSource("AmbassadorStatsCard.swift").contains(".lineLimit(1)"))
        #expect(source.contains("struct WordmarkBadge: View"))
        #expect(source.contains("ambassadorBadgeSymbol = \"medal.fill\""))
    }
}

@Suite("Ambassador date line")
struct AmbassadorDateLineTests {
    private func text(_ month: Int, _ day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        return AmbassadorDateLine.text(for: date, calendar: calendar)
    }

    @Test("the month in full and an ordinal day")
    func ordinals() {
        #expect(text(11, 1) == "November 1st")
        #expect(text(11, 2) == "November 2nd")
        #expect(text(11, 3) == "November 3rd")
        #expect(text(11, 4) == "November 4th")
        #expect(text(11, 11) == "November 11th")
        #expect(text(11, 12) == "November 12th")
        #expect(text(11, 13) == "November 13th")
        #expect(text(11, 21) == "November 21st")
        #expect(text(11, 22) == "November 22nd")
        #expect(text(11, 23) == "November 23rd")
        #expect(text(12, 31) == "December 31st")
    }
}

@Suite("Ambassador goals")
struct AmbassadorGoalsTests {
    @Test("progress clamps to 0...1 and the caption reads n of target")
    func progress() {
        #expect(AmbassadorGoals.downloadsTarget == 100)
        #expect(AmbassadorGoals.postersTarget == 30)
        #expect(AmbassadorGoals.progress(count: 0, target: 100) == 0)
        #expect(AmbassadorGoals.progress(count: 25, target: 100) == 0.25)
        #expect(AmbassadorGoals.progress(count: 250, target: 100) == 1)
        #expect(AmbassadorGoals.progress(count: -3, target: 100) == 0)
        #expect(AmbassadorGoals.progress(count: 5, target: 0) == 0)
        #expect(AmbassadorGoals.caption(count: 12, target: 30) == "12 of 30")
    }
}

@Suite("Ambassador streak and link fill")
struct AmbassadorStreakTests {
    @Test("the streak counts back from today, or yesterday while today is open")
    func streak() {
        var log = AmbassadorTaskLog()
        #expect(log.anonStreak(todayIndex: 100) == 0)
        log.markDone(.anonChats, todayIndex: 100)
        #expect(log.anonStreak(todayIndex: 100) == 1)
        log.markDone(.anonChats, todayIndex: 99)
        log.markDone(.anonChats, todayIndex: 98)
        #expect(log.anonStreak(todayIndex: 100) == 3)
        #expect(log.anonStreak(todayIndex: 101) == 3)
        #expect(log.anonStreak(todayIndex: 102) == 0)
        var gap = AmbassadorTaskLog()
        gap.markDone(.anonChats, todayIndex: 99)
        gap.markDone(.anonChats, todayIndex: 98)
        #expect(gap.anonStreak(todayIndex: 100) == 2)
        gap.markDone(.anonChats, todayIndex: 95)
        #expect(gap.anonStreak(todayIndex: 100) == 2)
        var future = AmbassadorTaskLog()
        future.markDone(.anonChats, todayIndex: 105)
        #expect(future.anonStreak(todayIndex: 100) == 0)
    }

    @Test("filled replaces every {link}")
    func fill() {
        #expect(AmbassadorGuidance.filled("a {link} b {link}", link: "L") == "a L b L")
        #expect(AmbassadorGuidance.filled("none", link: "L") == "none")
    }
}

@Suite("Ambassador guidance in the plan")
struct AmbassadorGuidancePlanTests {
    static let base = #"{"name":"Maya","school":"uva""#

    @Test("guidance decodes; a malformed kind or example is dropped, not the plan")
    func decodes() throws {
        let json = Self.base + #"""
        ,"guidance":{"footer":"f","kinds":[
          {"key":"a","label":"plug","example":{"text":"t","reply":"x"},"how":"h"},
          {"key":"b","label":"sneak","example":{"text":"t2"}},
          {"key":"bad","label":"no example"},
          {"label":"no key"}]}}
        """#
        let plan = try AmbassadorPlan.decode(Data(json.utf8))
        let guidance = try #require(plan.guidance)
        #expect(guidance.footer == "f")
        #expect(guidance.kinds.map(\.key) == ["a", "b"])
        #expect(guidance.kinds[0].how == "h")
        #expect(guidance.kinds[0].example.text == "t")
        #expect(guidance.kinds[0].example.reply == "x")
        #expect(guidance.kinds[1].example.reply == nil)
        #expect(guidance.kinds[1].how == nil)
    }

    @Test("absent or wrongly shaped guidance reads nil and the plan survives")
    func absent() throws {
        #expect(try AmbassadorPlan.decode(Data((Self.base + "}").utf8)).guidance == nil)
        let plan = try AmbassadorPlan.decode(Data((Self.base + #","guidance":"lots"}"#).utf8))
        #expect(plan.guidance == nil)
        #expect(plan.name == "Maya")
    }

    @Test("the bundled copy equals the Worker's guidance.json")
    func bundledParity() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appendingPathComponent("smooth-ambassadors/worker/templates/guidance.json").path) {
            url.deleteLastPathComponent()
        }
        let file = url.appendingPathComponent("smooth-ambassadors/worker/templates/guidance.json")
        let data = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode(AmbassadorPlan.Guidance.self, from: data)
        #expect(decoded == AmbassadorGuidance.bundled)
        #expect(decoded.kinds.map(\.key) == ["plug", "sneak"])
    }
}
