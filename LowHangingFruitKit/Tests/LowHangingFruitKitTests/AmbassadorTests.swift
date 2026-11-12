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
    var ideas: [(code: String, note: String, image: Data?)] = []
    var ideaError: AmbassadorClientError?

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

    /// Olisa, from his phone on 2026-11-12: the checklist told a signed-in
    /// ambassador to download the app, so it went, and the page now opens on
    /// what the job is and on the web page, which had been the last row.
    @Test("the page opens on the job and the web page, and has no getting-started list")
    func jobFirst() throws {
        let page = try uiSource("AmbassadorPage.swift")
        #expect(!page.contains("SmoothSectionHeader(\"getting started\""))
        #expect(!page.contains("checklistSection"))
        #expect(!page.contains("setChecklist"))
        let body = try #require(page.range(of: "if model.isSignedIn {"))
        let job = try #require(page.range(of: "jobSection", range: body.upperBound..<page.endIndex))
        let today = try #require(page.range(of: "todaySection", range: body.upperBound..<page.endIndex))
        #expect(job.lowerBound < today.lowerBound)
        #expect(page.contains("get smooth in front of as many eyes as you can."))
        // Gathering feedback and ideas is part of the job: said in the job
        // section, and the box for it comes before the numbers.
        #expect(page.contains("bring back what people say and ideas for smooth."))
        let feedback = try #require(page.range(of: "feedbackSection", range: body.upperBound..<page.endIndex))
        let numbers = try #require(page.range(of: "numbersSection", range: body.upperBound..<page.endIndex))
        #expect(today.lowerBound < feedback.lowerBound && feedback.lowerBound < numbers.lowerBound)
        // One way to the web page, and it is in the job section, not the footer.
        #expect(page.components(separatedBy: "web page \\u{2197}").count == 2)
        let jobStart = try #require(page.range(of: "private var jobSection"))
        let todayStart = try #require(page.range(of: "private var todaySection"))
        let link = try #require(page.range(of: "open my web page"))
        #expect(jobStart.lowerBound < link.lowerBound && link.lowerBound < todayStart.lowerBound)
    }

    @Test("ambassador mode never mentions ratings or reviews")
    func noReviews() throws {
        for file in ["AmbassadorPage.swift", "AmbassadorModel.swift", "AmbassadorReminders.swift",
                     "AmbassadorPostersView.swift", "PosterIdeaSheet.swift"] {
            let source = try uiSource(file).lowercased()
            #expect(!source.contains("5 star") && !source.contains("five star") && !source.contains("rate the app"), "\(file)")
        }
    }
}
