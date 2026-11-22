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

/// How far a feed recording's upload has got, for "sent 3 of 12".
struct FeedProgress: Equatable {
    var sent: Int
    var total: Int
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
    /// Non-nil only while a recording's stills are going up.
    @Published private(set) var feedProgress: FeedProgress?
    /// True from a first sign-in until the intro sheet is dismissed.
    @Published private(set) var introPending = false
    /// Which of the four tasks is ticked, and for how long (`AmbassadorTaskLog`).
    @Published private(set) var taskLog = AmbassadorTaskLog()
    /// How many posters the ambassador says they have put up, of 30. Theirs
    /// to set with the slider; never sent anywhere.
    @Published private(set) var postersPutUp: Int = 0
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
    /// Written once the intro has been shown. Sign-out leaves it alone: the
    /// intro is for a first sign-in on this install, not for every code.
    static let introSeenKey = "ambassador.introSeenV1"
    static let taskLogKey = "ambassador.taskLogV1"
    static let postersPutUpKey = "ambassador.postersPutUpV1"
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
        self.postersPutUp = max(0, min(AmbassadorGoals.postersTarget, defaults.integer(forKey: Self.postersPutUpKey)))
        if let data = defaults.data(forKey: Self.taskLogKey),
           let log = try? JSONDecoder().decode(AmbassadorTaskLog.self, from: data) {
            self.taskLog = log
        }
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
            if !defaults.bool(forKey: Self.introSeenKey) { introPending = true }
            await ensureReminders()
            return true
        } catch AmbassadorClientError.unknownCode {
            lastError = "that code didn\u{2019}t work"
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
        }
        return false
    }

    /// The intro sheet was dismissed; it is not shown again on this install.
    func finishIntro() {
        defaults.set(true, forKey: Self.introSeenKey)
        introPending = false
    }

    /// Forgets the code, the cached plan and the local settings, and takes
    /// the reminders back. Nothing is sent to the server: the founder's
    /// roster row is theirs, and "left" is a word for the founders to set.
    func signOut() {
        code = nil
        plan = nil
        planFetchedAt = nil
        postedDayIndex = nil
        taskLog = AmbassadorTaskLog()
        postersPutUp = 0
        introPending = false
        lastError = nil
        removeCode()
        for key in [Self.planCacheKey, Self.postedDayKey, Self.fetchedAtKey, Self.taskLogKey, Self.postersPutUpKey] { defaults.removeObject(forKey: key) }
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

    // MARK: The four tasks

    /// The server's day index when the plan has one, else the phone's own
    /// (days since the epoch in the phone's zone), so a task can be ticked
    /// before the first plan arrives.
    private var todayIndex: Int {
        if let index = plan?.today?.dayIndex { return index }
        let local = Date().timeIntervalSince1970 + Double(timeZone.secondsFromGMT())
        return Int((local / 86_400).rounded(.down))
    }

    func isDone(_ task: AmbassadorTask) -> Bool {
        // Posters are ongoing: ticked only at the goal, never by the log.
        if task == .posters { return postersPutUp >= AmbassadorGoals.postersTarget }
        if task == .anonChats, postedToday { return true }
        return taskLog.isDone(task, todayIndex: todayIndex)
    }

    func setPostersPutUp(_ value: Int) {
        postersPutUp = max(0, min(AmbassadorGoals.postersTarget, value))
        defaults.set(postersPutUp, forKey: Self.postersPutUpKey)
    }

    /// Posts logged in the last seven days (today included).
    var anonPostsThisWeek: Int { taskLog.anonPostsInLastWeek(todayIndex: todayIndex) }
    var anonWeeklyMinimumMet: Bool { taskLog.anonWeeklyMinimumMet(todayIndex: todayIndex) }
    var anonWeekDots: [Bool] { taskLog.anonPostedDays(todayIndex: todayIndex) }

    private func tick(_ task: AmbassadorTask) {
        taskLog.markDone(task, todayIndex: todayIndex)
        if let data = try? JSONEncoder().encode(taskLog) { defaults.set(data, forKey: Self.taskLogKey) }
    }

    /// Ticks `task` at once, on the phone, then tells the server where it has
    /// something to count: the anonymous post (the existing daily log) and a
    /// group-chat drop (a `post` in the `gc` channel). Posters and feedback
    /// send nothing from here (a poster idea and feedback have their own
    /// calls). A server failure leaves the tick: the ambassador did the job.
    func markDone(_ task: AmbassadorTask) async {
        tick(task)
        switch task {
        case .anonChats:
            await markPostedToday()
        case .groupChats:
            guard let code else { return }
            try? await client.send(code: code, action: "post", body: ["channel": "gc", "place": "group chats"])
        case .posters, .feedback:
            break
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
            tick(.feedback)
            return true
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
            return false
        }
    }

    /// Sends a poster idea: a note, a picture, or both. This is the one place
    /// a picture leaves the phone, and only here, on the student's tap. The
    /// picture is shrunk and re-encoded first (`PosterIdeaImage`: a phone
    /// photo is several megabytes, the server refuses over 600 KB, and the
    /// new JPEG carries no GPS or other metadata). The shrinking runs off the
    /// main actor because decoding and re-encoding a camera photo takes long
    /// enough to drop frames; `Data` is Sendable, so nothing unsafe crosses.
    /// On success the plan is fetched again so "3 of 30" moves.
    @discardableResult
    func sendPosterIdea(note: String, imageData: Data?) async -> Bool {
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard text.isEmpty == false || imageData != nil else {
            lastError = "add a picture or a note"
            return false
        }
        guard let code else { return false }
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        var jpeg: Data?
        if let imageData {
            jpeg = await Task.detached(priority: .userInitiated) {
                PosterIdeaImage.prepared(from: imageData)
            }.value
            guard jpeg != nil else {
                lastError = "couldn\u{2019}t read that picture"
                return false
            }
        }
        do {
            try await client.sendIdea(code: code, note: text, imageJPEG: jpeg)
        } catch AmbassadorClientError.unknownCode {
            lastError = "this code no longer works"
            return false
        } catch AmbassadorClientError.tooLarge {
            lastError = "that picture is too big"
            return false
        } catch AmbassadorClientError.limitReached {
            lastError = "that\u{2019}s the limit for today"
            return false
        } catch {
            lastError = "couldn\u{2019}t reach smooth"
            return false
        }
        await refresh()
        lastError = nil
        return true
    }

    /// The words for a failed upload, the same ones the idea path uses.
    private static func uploadErrorLine(_ error: Error) -> String {
        switch error as? AmbassadorClientError {
        case .unknownCode?: return "this code no longer works"
        case .tooLarge?: return "that picture is too big"
        case .limitReached?: return "that\u{2019}s the limit for today"
        default: return "couldn\u{2019}t reach smooth"
        }
    }

    /// The feed recording and post result sheets went on 2026-11-21 at Marco's
    /// word (the page is four tasks now), but the server still has both routes
    /// and the founder page reads what they stored, so these two methods, the
    /// client's `sendCapture` and `FeedRecordingFrames` stay, tested, for the
    /// day a sheet comes back.
    ///
    /// Uploads the stills of one screen recording, in order, under one new
    /// batch id (the server groups by it) with `seq` 0...n-1, at most 16. Stops
    /// at the first refusal: a daily limit or a dead code will not get better
    /// by trying the next still, and the ones already sent stay sent. The
    /// stills were already shrunk and re-encoded by `FeedRecordingFrames`, so
    /// nothing is re-encoded here. On success the plan is fetched again so
    /// "3 of 96" moves.
    @discardableResult
    func sendFeedFrames(_ frames: [Data]) async -> Bool {
        guard let code else { return false }
        let batch = Array(frames.prefix(16))
        guard !batch.isEmpty else {
            lastError = "couldn\u{2019}t read that recording"
            return false
        }
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        let id = FeedRecordingFrames.newBatchID()
        feedProgress = FeedProgress(sent: 0, total: batch.count)
        for (index, jpeg) in batch.enumerated() {
            do {
                try await client.sendCapture(code: code, fields: AmbassadorClient.feedFrameBody(batch: id, seq: index, jpeg: jpeg))
            } catch {
                lastError = Self.uploadErrorLine(error)
                feedProgress = nil
                return false
            }
            feedProgress = FeedProgress(sent: index + 1, total: batch.count)
        }
        feedProgress = nil
        await refresh()
        lastError = nil
        return true
    }

    /// Sends one screenshot of how a post did, with where it was posted, which
    /// kind of post it was and the numbers if the student gave them. Shrunk off
    /// the main actor exactly as `sendPosterIdea` does.
    @discardableResult
    func sendPostResult(imageData: Data, platform: String, style: String,
                        upvotes: Int?, views: Int?, note: String) async -> Bool {
        guard let code else { return false }
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        let jpeg = await Task.detached(priority: .userInitiated) {
            PosterIdeaImage.prepared(from: imageData, maxDimension: 1200, maxBytes: 300_000)
        }.value
        guard let jpeg else {
            lastError = "couldn\u{2019}t read that picture"
            return false
        }
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        do {
            try await client.sendCapture(code: code, fields: AmbassadorClient.resultBody(
                jpeg: jpeg, platform: platform, style: style, upvotes: upvotes, views: views, note: text))
        } catch {
            lastError = Self.uploadErrorLine(error)
            return false
        }
        await refresh()
        lastError = nil
        return true
    }

    /// Clears a line left by an earlier action, for a sheet that opens fresh.
    func clearError() {
        lastError = nil
    }

    /// Pauses for `weeks` (0 resumes) on the server, which stops the
    /// founders' texts, and switches the local reminders off (or back to
    /// daily on resume): a pause means every nudge, not just the texted one.
    func pause(weeks: Int) async {
        guard let code else { return }
        do {
            try await client.send(code: code, action: "pause", body: ["weeks": String(weeks)])
            await setCadence(weeks > 0 ? .off : .twiceWeekly)
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
        requestOpen()
    }

    /// Asks the dashboard to open the page as its own destination (the
    /// Profile row, the reminder tap and the link all come through here).
    func requestOpen() {
        pendingOpen = true
    }

    func consumePendingOpen() {
        pendingOpen = false
    }
}
