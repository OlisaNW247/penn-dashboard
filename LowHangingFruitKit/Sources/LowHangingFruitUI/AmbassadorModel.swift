import Foundation
import UserNotifications
import LowHangingFruitKit

/// The notification center as ambassador mode needs it: five calls. A
/// protocol so the model can be driven in tests, where
/// `UNUserNotificationCenter.current()` traps (the scheduler's own
/// `notificationSinkOverride` exists for the same reason). Main-actor
/// isolated like `PendingNotificationSink`, and for the same reason: a
/// `UNNotificationRequest` is not `Sendable`, so handing one to a
/// nonisolated `add` is a data race to Swift 6 (the first CI run of this
/// file said so); on the main actor the hand-off is no hand-off.
@MainActor
protocol AmbassadorNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func pendingIdentifiers() async -> [String]
    func remove(identifiers: [String])
    func add(_ request: UNNotificationRequest) async -> Bool
}

/// The real one, over the thread-safe `UNUserNotificationCenter`.
@MainActor
final class SystemAmbassadorNotificationCenter: AmbassadorNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        // The one delegate the app has, set at launch by
        // `NotificationResponseRouter.install()`; asking for permission must
        // not replace it (the scheduler's `requestAuthorization` re-asserts
        // it for the same reason).
        center.delegate = NotificationResponseDelegate.shared
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest) async -> Bool {
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }
}

/// Ambassador mode's state: signed in or not, the plan the server last gave
/// (cached, so the page opens instantly and works offline), the reminder
/// settings, and the one-shot "open the ambassador page" that a notification
/// tap or a `smooth://ambassador` link raises.
///
/// **Why a shared singleton and not a fourth `@EnvironmentObject`.** The
/// notification delegate (`NotificationResponseRouter`) and the root view's
/// URL handler both need to reach it, from places that have no environment,
/// the same reason `NotificationActionInbox.shared` exists. Profile and the
/// dashboard observe it with `@ObservedObject`. Tests build their own with
/// an in-memory store, a fake client and a fake center, and the shared one
/// is never touched by a test (its init reads the Keychain store, which is
/// inert under the test runner anyway).
///
/// **What is persisted where.** The code: Keychain (`AmbassadorCodeStore`).
/// The plan cache, the cadence, the time, the anonymous app and the "posted
/// today" day: `UserDefaults.lhf`, under `ambassador.*`. None of it is
/// anyone else's data; the plan is the ambassador's own numbers and the
/// message bank. "Sign out" removes all of it and the reminders.
@MainActor
final class AmbassadorModel: ObservableObject {
    static let shared = AmbassadorModel()

    @Published private(set) var code: String?
    @Published private(set) var plan: AmbassadorPlan?
    @Published private(set) var isWorking = false
    /// One line for the page, in the app's register, or nil.
    @Published private(set) var lastError: String?
    @Published private(set) var cadence: AmbassadorReminderCadence
    @Published private(set) var reminderHour: Int
    @Published private(set) var reminderMinute: Int
    @Published private(set) var anonApp: AmbassadorAnonApp
    @Published private(set) var authStatus: UNAuthorizationStatus = .notDetermined
    /// The day index (the server's) the student last marked "posted".
    @Published private(set) var postedDayIndex: Int?
    /// Set by a reminder tap or an `smooth://ambassador` link; the dashboard
    /// pushes Profile → ambassador and calls `consumePendingOpen()`.
    @Published private(set) var pendingOpen = false
    /// When the plan was last fetched from the server, for `refreshIfStale`.
    private(set) var planFetchedAt: Date?

    private let defaults: UserDefaults
    private let client: any AmbassadorService
    private let center: (any AmbassadorNotificationCenter)?
    private let loadCode: () -> String?
    private let saveCode: (String) -> Void
    private let removeCode: () -> Void
    private let timeZone: TimeZone

    static let planCacheKey = "ambassador.planCache"
    static let cadenceKey = "ambassador.cadence"
    static let hourKey = "ambassador.reminderHour"
    static let minuteKey = "ambassador.reminderMinute"
    static let anonAppKey = "ambassador.anonApp"
    static let postedDayKey = "ambassador.postedDayIndex"
    static let fetchedAtKey = "ambassador.planFetchedAt"
    /// A plan older than this is fetched again when the app becomes active
    /// or the page opens. Half an hour: the numbers move slowly, and the post
    /// changes once a day.
    static let staleAfter: TimeInterval = 30 * 60

    /// The app's instance. Everything real: the Keychain, the live server,
    /// the system notification center, the shared defaults.
    private convenience init() {
        self.init(
            defaults: .lhf,
            client: AmbassadorClient(),
            center: SharedDefaults.isTestRunner ? nil : SystemAmbassadorNotificationCenter(),
            loadCode: { AmbassadorCodeStore.load() },
            saveCode: { AmbassadorCodeStore.save($0) },
            removeCode: { AmbassadorCodeStore.remove() },
            timeZone: .current
        )
    }

    init(defaults: UserDefaults,
         client: any AmbassadorService,
         center: (any AmbassadorNotificationCenter)?,
         loadCode: @escaping () -> String?,
         saveCode: @escaping (String) -> Void,
         removeCode: @escaping () -> Void,
         timeZone: TimeZone = .current) {
        self.defaults = defaults
        self.client = client
        self.center = center
        self.loadCode = loadCode
        self.saveCode = saveCode
        self.removeCode = removeCode
        self.timeZone = timeZone
        self.code = loadCode()
        self.cadence = AmbassadorReminderCadence(rawValue: defaults.string(forKey: Self.cadenceKey) ?? "") ?? .daily
        let hour = defaults.object(forKey: Self.hourKey) as? Int
        let minute = defaults.object(forKey: Self.minuteKey) as? Int
        self.reminderHour = hour.map { max(0, min(23, $0)) } ?? AmbassadorReminders.defaultHour
        self.reminderMinute = minute.map { max(0, min(59, $0)) } ?? AmbassadorReminders.defaultMinute
        self.anonApp = AmbassadorAnonApp(rawValue: defaults.string(forKey: Self.anonAppKey) ?? "") ?? .fizz
        self.postedDayIndex = defaults.object(forKey: Self.postedDayKey) as? Int
        if let data = defaults.data(forKey: Self.planCacheKey), let cached = try? AmbassadorPlan.decode(data) {
            self.plan = cached
        }
        if let t = defaults.object(forKey: Self.fetchedAtKey) as? Double { self.planFetchedAt = Date(timeIntervalSince1970: t) }
        // The planner's budget must know about the slots from the first
        // reschedule, not from the first time the page is opened.
        NotificationScheduler.reservedForeignSlots = isSignedIn ? AmbassadorReminders.reservedSlots(for: cadence) : 0
    }

    var isSignedIn: Bool { code != nil }

    /// "maya · uva" for the Profile row, or the invitation.
    var statusLine: String {
        guard isSignedIn else { return "sign in" }
        guard let plan else { return "signed in" }
        return "\(plan.firstName.lowercased()) \u{00B7} \(plan.schoolLabel)"
    }

    /// Whether today's post has been marked posted. Compared on the server's
    /// day index so the phone's midnight and the server's agree (the plan was
    /// fetched with the phone's own offset).
    var postedToday: Bool {
        guard let today = plan?.today, let postedDayIndex else { return false }
        return today.dayIndex == postedDayIndex
    }

    // MARK: Signing in and out

    /// Parses `raw` (a code or a link), asks the server for the plan, and on
    /// success saves the code and schedules the reminders. False, with
    /// `lastError` set, when the code is malformed, unknown, or the server
    /// could not be reached.
    @discardableResult
    func signIn(_ raw: String) async -> Bool {
        guard let candidate = AmbassadorCode.parse(raw) else {
            lastError = "that doesn\u{2019}t look like a code"
            return false
        }
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        do {
            let fetched = try await client.plan(code: candidate, anonApp: anonApp, tzOffsetMinutes: tzOffset())
            code = candidate
            saveCode(candidate)
            store(plan: fetched)
            await ensureReminders()
            return true
        } catch AmbassadorClientError.unknownCode {
            lastError = "that code didn\u{2019}t work"
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
        }
        return false
    }

    /// Forgets the code, the cached plan and the local settings, and takes
    /// the reminders back. Nothing is sent to the server: the founder's
    /// roster row is theirs, and "left" is a word for the founders to set.
    func signOut() {
        code = nil
        plan = nil
        planFetchedAt = nil
        postedDayIndex = nil
        lastError = nil
        removeCode()
        for key in [Self.planCacheKey, Self.postedDayKey, Self.fetchedAtKey] { defaults.removeObject(forKey: key) }
        NotificationScheduler.reservedForeignSlots = 0
        Task { await removeAllReminders() }
    }

    // MARK: The plan

    func refresh() async {
        guard let code else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let fetched = try await client.plan(code: code, anonApp: anonApp, tzOffsetMinutes: tzOffset())
            store(plan: fetched)
            lastError = nil
        } catch AmbassadorClientError.unknownCode {
            // The founders removed this ambassador. The cached plan stays
            // readable; the next action will say the code no longer works.
            lastError = "this code no longer works"
        } catch {
            // Offline: the cached plan is what the page shows. No line, the
            // numbers simply do not move.
        }
    }

    func refreshIfStale(now: Date = Date()) async {
        guard isSignedIn else { return }
        if let planFetchedAt, now.timeIntervalSince(planFetchedAt) < Self.staleAfter, plan != nil { return }
        await refresh()
    }

    private func store(plan fetched: AmbassadorPlan) {
        plan = fetched
        planFetchedAt = Date()
        if let data = try? fetched.encoded() { defaults.set(data, forKey: Self.planCacheKey) }
        defaults.set(planFetchedAt!.timeIntervalSince1970, forKey: Self.fetchedAtKey)
    }

    private func tzOffset() -> Int {
        AmbassadorClient.tzOffsetMinutes(for: timeZone)
    }

    // MARK: What the student does

    /// "posted": logs today's post on the server in the channel it was
    /// written for, and remembers the day so the page says so. Logged even
    /// when the server cannot be reached? No: a log that never arrived would
    /// show "posted" here and nothing on the founders' side, and the student
    /// would be told their work counted when it did not. The tap fails
    /// visibly instead, and can be repeated.
    @discardableResult
    func markPostedToday() async -> Bool {
        guard let code, let today = plan?.today, let channel = today.channel else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.send(code: code, action: "post", body: ["channel": channel, "place": "daily"])
            postedDayIndex = today.dayIndex
            defaults.set(today.dayIndex, forKey: Self.postedDayKey)
            lastError = nil
            return true
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
            return false
        }
    }

    func setChecklist(_ key: String, done: Bool) async {
        guard let code else { return }
        // Optimistic: the tick shows at once and is corrected by the next
        // plan if the server disagreed.
        if var plan, let steps = plan.checklist {
            plan.checklist = steps.map { step in
                var s = step
                if s.key == key { s.done = done }
                return s
            }
            self.plan = plan
        }
        do {
            try await client.send(code: code, action: "check", body: ["step": key, "done": done ? "1" : "0"])
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
        }
    }

    @discardableResult
    func sendFeedback(_ text: String) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code, !body.isEmpty else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.send(code: code, action: "feedback", body: ["body": body])
            lastError = nil
            return true
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
            return false
        }
    }

    /// Pauses for `weeks` (0 resumes) on the server, which stops the
    /// founders' texts, and switches the local reminders off (or back to
    /// daily on resume): a pause means every nudge, not just the texted one.
    func pause(weeks: Int) async {
        guard let code else { return }
        do {
            try await client.send(code: code, action: "pause", body: ["weeks": String(weeks)])
            await setCadence(weeks > 0 ? .off : .daily)
            await refresh()
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
        }
    }

    // MARK: Reminders

    func setCadence(_ newValue: AmbassadorReminderCadence) async {
        cadence = newValue
        defaults.set(newValue.rawValue, forKey: Self.cadenceKey)
        await ensureReminders()
    }

    func setReminderTime(hour: Int, minute: Int) async {
        reminderHour = max(0, min(23, hour))
        reminderMinute = max(0, min(59, minute))
        defaults.set(reminderHour, forKey: Self.hourKey)
        defaults.set(reminderMinute, forKey: Self.minuteKey)
        await ensureReminders()
    }

    func setAnonApp(_ app: AmbassadorAnonApp) async {
        anonApp = app
        defaults.set(app.rawValue, forKey: Self.anonAppKey)
        // Today's post is filled for the chosen app, so it changes with it.
        await refresh()
    }

    /// Puts the reminders the settings call for in place and takes the rest
    /// of ours back. Idempotent, so it is safe to call on every activation.
    /// Asks for notification permission once, the first time there is
    /// something to schedule and the question has never been asked; a refusal
    /// is respected (the page shows "notifications are off in system
    /// settings", as reminders does).
    func ensureReminders() async {
        NotificationScheduler.reservedForeignSlots = isSignedIn ? AmbassadorReminders.reservedSlots(for: cadence) : 0
        guard let center else { return }
        let wanted = isSignedIn ? AmbassadorReminders.requests(cadence: cadence, hour: reminderHour,
                                                                minute: reminderMinute, firstName: plan?.firstName) : []
        authStatus = await center.authorizationStatus()
        if !wanted.isEmpty, authStatus == .notDetermined {
            _ = await center.requestAuthorization()
            authStatus = await center.authorizationStatus()
        }
        let pending = await center.pendingIdentifiers().filter(AmbassadorReminders.isAmbassadorIdentifier)
        let wantedIDs = Set(wanted.map(\.identifier))
        let stale = pending.filter { !wantedIDs.contains($0) }
        if !stale.isEmpty { center.remove(identifiers: stale) }
        guard authStatus == .authorized || authStatus == .provisional else { return }
        for request in wanted { _ = await center.add(request) }
    }

    private func removeAllReminders() async {
        guard let center else { return }
        let ours = await center.pendingIdentifiers().filter(AmbassadorReminders.isAmbassadorIdentifier)
        if !ours.isEmpty { center.remove(identifiers: ours) }
    }

    // MARK: Entry points from outside the page

    /// The app became active: put the reminders back if something cleared
    /// them (reminders switched off, the update wall) and fetch a fresh plan
    /// if the cached one is old. Cheap when signed out.
    func sceneBecameActive() {
        guard isSignedIn else { return }
        Task {
            await ensureReminders()
            await refreshIfStale()
        }
    }

    /// A `smooth://ambassador?code=…` link (the page's "open in smooth"). True
    /// when the URL was one, whether or not the code turned out to be real:
    /// the page then shows the result. A code that is already the signed-in
    /// one only opens the page.
    @discardableResult
    func receive(url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "smooth", parts.host?.lowercased() == "ambassador" else { return false }
        pendingOpen = true
        if let candidate = AmbassadorCode.parse(url.absoluteString), candidate != code {
            Task { await signIn(candidate) }
        }
        return true
    }

    /// The student tapped the daily reminder.
    func noteReminderTapped() {
        pendingOpen = true
    }

    func consumePendingOpen() {
        pendingOpen = false
    }
}
