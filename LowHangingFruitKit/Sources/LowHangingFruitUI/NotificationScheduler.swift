import Foundation
import UserNotifications
import LowHangingFruitKit

/// Schedules local due-date reminders. Cross-platform: `UNUserNotificationCenter`
/// works on iOS 17 and macOS 14, and local notifications need no entitlement and
/// no Info.plist usage string. Notification logic lives in the app/UI layer (not
/// in the data-layer `AppState`) and reads the override-aware `DashItem`s from the
/// view-model so manually-adjusted due dates are respected.
///
/// **Two layers of settings, and only one of them lives here.** The properties
/// below (`isEnabled`, `leadOffsets`, `digestEnabled`, `digestTime`) are the
/// *global* configuration — the one control set in Settings → Reminders. Since
/// v4 there is a second, per-course layer in `CoursePreferences`: a mute, an
/// optional lead-time override, and a switch for recurring non-assignment work.
/// The planner consults both. Which one wins is decided by
/// `CoursePreferences.effectiveLeadOffsets(global:)`, and the global set stays
/// load-bearing precisely because a course that has never been configured
/// inherits from it rather than freezing a copy — see that property's note.
@MainActor
final class NotificationScheduler: ObservableObject {

    /// How far before a due date a reminder fires.
    ///
    /// **The enum itself moved into the Kit** (`Models/LeadOffset.swift`) when
    /// `CoursePreferences` grew a per-course `leadOffsets`: that type is in
    /// `LowHangingFruitKit`, which cannot import this module, so the shared
    /// vocabulary had to move down rather than be duplicated. This alias keeps
    /// `NotificationScheduler.LeadOffset` — the spelling Settings and every
    /// other call site already uses — resolving to exactly the same type, so
    /// nothing outside this file had to change.
    typealias LeadOffset = LowHangingFruitKit.LeadOffset

    @Published private(set) var isEnabled: Bool
    @Published private(set) var leadOffsets: Set<LeadOffset>
    @Published private(set) var digestEnabled: Bool
    /// Whether "Turned in ✓" confirmations post when a Grade Watcher refresh
    /// detects a new submission. Defaults ON (unlike reminders/digest): the
    /// feature was requested as always-on, so the toggle exists to opt OUT.
    @Published private(set) var turnedInEnabled: Bool
    @Published private(set) var digestTime: DateComponents
    @Published private(set) var authStatus: UNAuthorizationStatus = .notDetermined

    // Lazy so launch on an unbundled binary never touches the notification center.
    private lazy var center = UNUserNotificationCenter.current()
    private let foregroundDelegate = ForegroundPresentationDelegate()

    /// Where the global reminder settings are read and written.
    ///
    /// Injected rather than reaching for `UserDefaults.lhf` inline so a test can
    /// drive a scratch suite. That is not a cosmetic change: `UserDefaults.lhf`
    /// resolves to the process-wide standard domain whenever the App Group is
    /// unavailable — which is every `swift test` run — so a scheduler that
    /// hard-coded it would be reading and writing the same five keys as every
    /// other test in the suite, and the failures that produces land in whichever
    /// test happens to run next. The default keeps every existing call site
    /// (`NotificationScheduler()`) working unchanged.
    private let defaults: UserDefaults

    private static let enabledKey      = "notif.enabled"
    private static let offsetsKey      = "notif.leadOffsets"
    private static let digestKey       = "notif.digestEnabled"
    private static let digestHourKey   = "notif.digestHour"
    private static let digestMinuteKey = "notif.digestMinute"
    private static let turnedInKey     = "notif.turnedInEnabled"

    /// iOS caps pending local notifications at 64; stay under it with headroom.
    static let maxPending = 60
    static let horizonDays = 14

    init(defaults: UserDefaults = .lhf) {
        self.defaults = defaults
        let d = defaults
        self.isEnabled = d.bool(forKey: Self.enabledKey)
        if let raw = d.array(forKey: Self.offsetsKey) as? [Int], !raw.isEmpty {
            self.leadOffsets = Set(raw.compactMap(LeadOffset.init(rawValue:)))
        } else {
            // The same default a course with `leadOffsets == nil` inherits, so
            // the two cannot drift apart.
            self.leadOffsets = LeadOffset.defaults
        }
        self.digestEnabled = d.bool(forKey: Self.digestKey)
        // Default ON when never set — `bool(forKey:)` alone would read a
        // missing key as false and silently disable the feature for everyone.
        self.turnedInEnabled = d.object(forKey: Self.turnedInKey) as? Bool ?? true
        let hour = d.object(forKey: Self.digestHourKey) as? Int ?? 8
        let minute = d.object(forKey: Self.digestMinuteKey) as? Int ?? 0
        self.digestTime = DateComponents(hour: hour, minute: minute)

        #if DEBUG
        // Screenshot seam: show the reminders feature fully expanded (in-memory
        // only — never calls requestAuthorization, so no permission prompt fires).
        if ProcessInfo.processInfo.arguments.contains("-LHFDemoData") {
            self.isEnabled = true
            self.digestEnabled = true
        }
        #endif
    }

    // MARK: Authorization

    func refreshAuthStatus() async {
        authStatus = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        center.delegate = foregroundDelegate
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthStatus()
        return granted
    }

    // MARK: Preferences (persisted; caller reschedules afterward)

    /// Enables/disables reminders. On enable, requests authorization. Rescheduling
    /// is left to the caller (it owns the current `items`).
    func setEnabled(_ on: Bool) async {
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            _ = await requestAuthorization()
        } else {
            cancelAll()
        }
    }

    func setOffset(_ offset: LeadOffset, on: Bool) {
        if on { leadOffsets.insert(offset) } else { leadOffsets.remove(offset) }
        defaults.set(leadOffsets.map(\.rawValue), forKey: Self.offsetsKey)
    }

    func setDigestEnabled(_ on: Bool) {
        digestEnabled = on
        defaults.set(on, forKey: Self.digestKey)
    }

    func setTurnedInEnabled(_ on: Bool) {
        turnedInEnabled = on
        defaults.set(on, forKey: Self.turnedInKey)
    }

    func setDigestTime(_ comps: DateComponents) {
        digestTime = DateComponents(hour: comps.hour ?? 8, minute: comps.minute ?? 0)
        defaults.set(digestTime.hour, forKey: Self.digestHourKey)
        defaults.set(digestTime.minute, forKey: Self.digestMinuteKey)
    }

    // MARK: Reschedule (idempotent)

    /// The item set the last `reschedule` planned from.
    ///
    /// Held so that a *preference* change — which happens on the Profile tab,
    /// far away from the dashboard view-model that owns the items — can re-plan
    /// without the editing screen having to reconstruct a `[DashItem]` of its
    /// own. `ProfileNotificationsSection` has `AppState` and this object in its
    /// environment and nothing else; asking it to rebuild the dashboard's item
    /// list would be a second, subtly-different copy of
    /// `DashboardViewModel.reload`, and the two would diverge the first time one
    /// of them learned about a new filter.
    ///
    /// Empty until the dashboard has scheduled at least once this launch, which
    /// is the honest failure mode: an edit made before that simply waits for the
    /// dashboard's own five-minute refresh to pick it up.
    private var lastScheduledItems: [DashItem] = []

    /// The in-flight debounce from `rescheduleAfterPreferenceChange`.
    private var pendingPreferenceReschedule: Task<Void, Never>?

    /// Cancels all app-scheduled reminders and re-adds them from the current items.
    /// Completed / submitted / too-old / rescheduled items drop off automatically.
    func reschedule(from items: [DashItem], now: Date = Date()) async {
        lastScheduledItems = items
        guard isEnabled else { cancelAll(); return }
        await refreshAuthStatus()
        guard authStatus == .authorized || authStatus == .provisional else { return }
        center.delegate = foregroundDelegate
        cancelAll()
        for request in plannedRequests(from: items, now: now) {
            try? await center.add(request)
        }
    }

    /// Re-plans from `lastScheduledItems` after the student changed a per-course
    /// preference, coalescing a burst of edits into one pass.
    ///
    /// The debounce is not politeness. Rescheduling is a full
    /// `removeAllPendingNotificationRequests()` followed by up to sixty
    /// `add(_:)` calls, and a student setting up a class flips five or six
    /// switches in about as many seconds — running the whole cycle per switch
    /// would mean the app spends that entire interval with an empty or
    /// half-populated pending queue. Coalescing means it is empty once, briefly,
    /// after they stop.
    func rescheduleAfterPreferenceChange(debounce: Duration = .milliseconds(600)) {
        pendingPreferenceReschedule?.cancel()
        guard isEnabled, !lastScheduledItems.isEmpty else { return }
        pendingPreferenceReschedule = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            await self.reschedule(from: self.lastScheduledItems)
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    // MARK: Grade changes

    /// How many individual grade notifications to post before collapsing the
    /// rest into one summary. A professor publishing a whole assignment group at
    /// once is normal; five separate banners for it is not.
    static let maxGradeNotifications = 3

    /// Posts "your grade posted" notifications for grades that changed since the
    /// last refresh. Delivered immediately rather than scheduled — the grade has
    /// *already* changed, so there is nothing to wait for.
    ///
    /// Safe against `reschedule`'s `cancelAll()`, which only clears *pending*
    /// requests: these have no trigger and are delivered on arrival.
    func notifyGradeChanges(_ changes: [AssignmentStore.ScoreChange]) async {
        guard isEnabled, !changes.isEmpty else { return }
        await refreshAuthStatus()
        guard authStatus == .authorized || authStatus == .provisional else { return }
        for request in Self.gradeRequests(changes) {
            try? await center.add(request)
        }
    }

    /// Pure request-building, so the wording and the collapse rule are testable
    /// without touching `UNUserNotificationCenter`.
    static func gradeRequests(_ changes: [AssignmentStore.ScoreChange]) -> [UNNotificationRequest] {
        guard !changes.isEmpty else { return [] }

        // Newly-posted grades are the news; regrades are a quieter follow-up.
        let ordered = changes.sorted { lhs, rhs in
            if lhs.isNewlyGraded != rhs.isNewlyGraded { return lhs.isNewlyGraded }
            return lhs.course < rhs.course
        }

        if ordered.count > maxGradeNotifications {
            let courses = Set(ordered.map(\.course)).sorted()
            let content = UNMutableNotificationContent()
            content.title = "📊 \(ordered.count) new grades"
            content.body = courses.count == 1
                ? "\(courses[0]) posted \(ordered.count) grades."
                : "Across \(courses.joined(separator: ", "))."
            content.sound = .default
            return [UNNotificationRequest(identifier: "grade:batch:\(Int(Date().timeIntervalSince1970))",
                                          content: content, trigger: nil)]
        }

        return ordered.map { change in
            let content = UNMutableNotificationContent()
            content.title = change.isNewlyGraded
                ? "📊 \(change.course) grade posted"
                : "📊 \(change.course) grade updated"
            content.body = "\(change.title). \(Self.formatScore(change))"
            content.sound = .default
            return UNNotificationRequest(
                identifier: "grade:\(change.assignmentID):\(change.earned)",
                content: content,
                trigger: nil
            )
        }
    }

    /// "18/20 (90%)", or just the raw number when the total isn't known or is
    /// zero (an ungraded-points item would otherwise divide by zero).
    static func formatScore(_ change: AssignmentStore.ScoreChange) -> String {
        let earned = Self.trim(change.earned)
        guard let max = change.max, max > 0 else { return earned }
        let percent = Int((change.earned / max * 100).rounded())
        return "\(earned)/\(Self.trim(max)) (\(percent)%)"
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.1f", value)
    }

    // MARK: The per-course layer

    /// The per-course settings the planner consults, resolved for one planning
    /// pass.
    ///
    /// Tests pass their own store; the app passes nothing and gets a fresh read
    /// of the same `UserDefaults` blob `AppState`'s store writes. Reading the
    /// blob afresh each pass rather than caching an instance is deliberate:
    /// `CoursePreferencesStore` persists synchronously on every mutation, so a
    /// fresh decode is always current, whereas a cached second instance would
    /// go stale the moment the student changed anything and would show it as a
    /// reminder that fires — or doesn't — against a setting they can see is off.
    /// This is a read-only use; nothing here ever mutates the returned store, so
    /// there is still exactly one writer.
    private func resolvedPreferences(_ explicit: CoursePreferencesStore?) -> CoursePreferencesStore {
        explicit ?? CoursePreferencesStore(defaults: defaults)
    }

    /// One candidate reminder: an item, the lead time it would fire at, and when
    /// that lands.
    private struct Candidate {
        let item: DashItem
        let offset: LeadOffset
        let fireDate: Date
        /// Whether this came from a `RecurringTask` occurrence (a weekly
        /// reading, a check-in) rather than from real coursework. Used both to
        /// honour the per-course recurring switch and as the last tiebreak when
        /// two candidates would otherwise fire at the same instant.
        let isRecurring: Bool

        var courseKey: String { item.assignment.course }
    }

    // MARK: Turned-in confirmations

    /// Posts one immediate "Turned in ✓" notification per newly-detected
    /// Canvas submission (see `AppState.updateSubmissionState` /
    /// `AppState.submissionNotifications`). Delivered with a nil trigger, like
    /// `notifyGradeChanges` — the submission has already happened, so there's
    /// nothing to wait for.
    ///
    /// Does NOT call `requestAuthorization()`: if the user has never granted
    /// (or has declined) notifications, this silently no-ops rather than
    /// prompting from a background Grade Watcher refresh. It reuses whatever
    /// authorization state the reminders flow already established, exactly
    /// like `notifyGradeChanges` does.
    func postTurnedInNotifications(_ notifications: [(title: String, body: String)]) async {
        guard isEnabled, turnedInEnabled, !notifications.isEmpty else { return }
        await refreshAuthStatus()
        guard authStatus == .authorized || authStatus == .provisional else { return }
        for request in Self.turnedInRequests(notifications) {
            try? await center.add(request)
        }
    }

    /// Pure request-building for turned-in confirmations, mirroring
    /// `gradeRequests` — unit-testable without `UNUserNotificationCenter`.
    ///
    /// Identifiers use the `turnedin:` prefix, which does not collide with
    /// any scheme already in use here: due-date reminders are
    /// `due:<assignment id>:<offset>` (built/removed in `plannedRequests` /
    /// `reschedule`'s `cancelAll()`), the daily summary is the fixed
    /// `digest:daily`, and grade alerts are `grade:<assignment id>:<earned>`
    /// or `grade:batch:<timestamp>`. A random UUID per call additionally
    /// guarantees two confirmations for the same assignment (e.g. a
    /// submission retracted and redone) never collide with each other either.
    static func turnedInRequests(_ notifications: [(title: String, body: String)]) -> [UNNotificationRequest] {
        notifications.map { notification in
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            return UNNotificationRequest(
                identifier: "turnedin:\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
        }
    }

    // MARK: Planning (pure; no UNUserNotificationCenter access — unit-testable)

    /// Builds the pending requests for `items`, honouring both the global
    /// reminder settings and each course's own.
    ///
    /// # The 60-request budget, and how it is shared out
    ///
    /// iOS keeps at most 64 pending local notifications per app and silently
    /// drops whatever doesn't fit, so this function's real job is deciding which
    /// sixty reminders are worth a slot. Until per-course preferences existed
    /// that was a flat `prefix(budget)` over every (item, lead time) pair sorted
    /// by fire date, and it was fine: every course contributed the same number
    /// of pairs per assignment, so "soonest first" spread across classes on its
    /// own, roughly in proportion to how much work each class had.
    ///
    /// Per-course lead times break that proportionality. A student who gives
    /// CIS 1200 all five lead times makes it contribute five pairs per
    /// assignment where an untouched course contributes two. Twelve CIS 1200
    /// assignments inside the fourteen-day horizon is sixty pairs on its own,
    /// and a flat sort by fire date hands it the entire budget. The student then
    /// stops being reminded about the four classes they never configured — with
    /// no error, no warning, and nothing to notice until something is missed.
    /// **The class you tuned eats the classes you didn't**, which is the worst
    /// possible direction for this failure to run: the courses least likely to
    /// be on your mind are exactly the ones that go quiet.
    ///
    /// So the budget is allocated **round-robin across courses**. Each course
    /// forms a queue of its own candidates, and the planner walks the queues in
    /// turn, taking one reminder from each per pass, until the budget runs out
    /// or every queue is empty. Three properties fall out, and they are the
    /// reasons for choosing it over the alternatives:
    ///
    /// - **No course can be starved by another.** With *n* courses in play and a
    ///   budget of *b*, every course gets its first `b / n` reminders before any
    ///   course gets its `(b / n) + 1`-th. A student with six classes is
    ///   guaranteed nine reminders for each of them.
    /// - **Nothing is wasted.** A course with three candidates takes three slots
    ///   and drops out of the rotation; its unused share flows to whoever still
    ///   has candidates. A fixed per-course quota — the obvious alternative —
    ///   would have left slots unfilled while other courses went unscheduled,
    ///   which is a worse outcome than the problem it fixes.
    /// - **A quiet course is not privileged either.** Round-robin allocates by
    ///   *course*, not by assignment, so a course with one assignment and a
    ///   course with twenty each take one slot per pass. The busy course still
    ///   ends up with far more reminders in total — it simply cannot take them
    ///   all before the quiet one has had any.
    ///
    /// Within a course, candidates are ordered **soonest-firing first**, and
    /// that is a different thing from soonest-*due*. The planner re-runs on
    /// every sync, on every app activation, and after every preference change,
    /// so a request scheduled eight days out is nearly certain to be cancelled
    /// and re-planned long before it would have fired. The slots that actually
    /// buy the student anything are the earliest-firing ones; the far-out tail
    /// is what the cut should fall on, and sorting by fire date makes that
    /// automatic. Ties break assignments ahead of recurring occurrences (a
    /// problem set outranks a weekly reading scheduled to the same minute) and
    /// then on the request identifier, so the same inputs always produce the
    /// same plan — `Set<LeadOffset>` has no iteration order to rely on.
    func plannedRequests(
        from items: [DashItem],
        now: Date = Date(),
        preferences: CoursePreferencesStore? = nil
    ) -> [UNNotificationRequest] {
        let prefs = resolvedPreferences(preferences)
        let horizon = now.addingTimeInterval(Double(Self.horizonDays) * 86_400)

        var byCourse: [String: [Candidate]] = [:]
        for item in items {
            guard !item.isCompleted, let due = item.due, due > now, due <= horizon else { continue }
            let course = item.assignment.course

            // A muted course produces nothing at all — not a quieter reminder,
            // not a digest line, nothing. That is the whole promise of the
            // switch.
            guard prefs.notificationsEnabled(course) else { continue }

            // The recurring switch is separate from the mute because the common
            // request is "keep telling me about assignments, stop telling me
            // about the weekly reading" — so it filters only the occurrences a
            // `RecurringTask` generated and leaves real coursework alone.
            let isRecurring = RecurringTask.isOccurrence(item.assignment)
            if isRecurring, !prefs.recurringEnabled(course) { continue }

            // `nil` here means the course never had its lead times set and
            // inherits whatever Settings currently says; an explicitly empty set
            // is the student saying "no lead-time reminders for this class" and
            // must not fall back to the global. Both cases are handled by
            // `effectiveLeadOffsets`, and the empty one simply produces no
            // candidates below.
            for offset in prefs.effectiveLeadOffsets(for: course, global: leadOffsets) {
                let fire = due.addingTimeInterval(-Double(offset.rawValue))
                guard fire > now else { continue }
                byCourse[course, default: []]
                    .append(Candidate(item: item, offset: offset, fireDate: fire, isRecurring: isRecurring))
            }
        }

        let budget = max(0, Self.maxPending - (digestEnabled ? 1 : 0))
        let calendar = Calendar.current

        var requests: [UNNotificationRequest] = Self.allocate(byCourse, budget: budget).map { pair in
            let content = UNMutableNotificationContent()
            // Owner's notification redesign (2026-08-26): the class name is
            // the headline and the lead phrase is the entire body — no
            // urgency emoji, no assignment title, no formatted date. The
            // notification's job is "look at this class now-ish"; the app is
            // one tap away for everything else. Urgency still shapes
            // BEHAVIOR (the time-sensitive interruption level below), it
            // just no longer shapes the text.
            let urgency = DueState(due: pair.item.due, now: pair.fireDate)
            content.title = pair.item.assignment.course
            content.body = pair.offset.headline
            content.sound = .default
            content.interruptionLevel = urgency.isTimeSensitive ? .timeSensitive : .active
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: pair.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            return UNNotificationRequest(identifier: Self.identifier(for: pair),
                                         content: content, trigger: trigger)
        }

        if digestEnabled, let digest = digestRequest(from: items, now: now, preferences: prefs) {
            requests.append(digest)
        }
        return requests
    }

    /// Stable, unique per (assignment, lead time) — the property `reschedule`'s
    /// cancel-and-re-add cycle depends on, since a request that re-plans to the
    /// same identifier simply replaces itself.
    private static func identifier(for candidate: Candidate) -> String {
        "due:\(candidate.item.assignment.id):\(candidate.offset.rawValue)"
    }

    /// Shares `budget` slots out across the per-course queues, round-robin. See
    /// `plannedRequests` for why this is round-robin and not a flat sort.
    ///
    /// Returned in fire-date order rather than in the order they were taken,
    /// because the caller's output is easier to reason about — and to assert on
    /// — when it reads as a timeline rather than as an interleaving artefact.
    private static func allocate(_ byCourse: [String: [Candidate]], budget: Int) -> [Candidate] {
        guard budget > 0, !byCourse.isEmpty else { return [] }

        // Each course's own queue, most urgent first.
        var queues = byCourse
            .map { (courseKey: $0.key, candidates: $0.value.sorted(by: isMoreUrgent)) }

        // The order courses take their turn in. Sorted by each course's most
        // urgent candidate so that when the budget runs out mid-pass, the slots
        // that were handed out went to the classes with something happening
        // soonest — and by course key after that, so the cut is deterministic
        // rather than dependent on dictionary iteration order.
        queues.sort { lhs, rhs in
            let l = lhs.candidates.first?.fireDate ?? .distantFuture
            let r = rhs.candidates.first?.fireDate ?? .distantFuture
            if l != r { return l < r }
            return lhs.courseKey < rhs.courseKey
        }

        var cursors = [Int](repeating: 0, count: queues.count)
        var chosen: [Candidate] = []
        chosen.reserveCapacity(min(budget, byCourse.values.reduce(0) { $0 + $1.count }))

        var tookSomething = true
        while chosen.count < budget && tookSomething {
            tookSomething = false
            for index in queues.indices {
                guard chosen.count < budget else { break }
                let cursor = cursors[index]
                guard cursor < queues[index].candidates.count else { continue }
                chosen.append(queues[index].candidates[cursor])
                cursors[index] = cursor + 1
                tookSomething = true
            }
        }

        return chosen.sorted(by: isMoreUrgent)
    }

    /// Soonest-firing first, then real coursework ahead of recurring
    /// occurrences, then by identifier. The last two exist purely so the plan is
    /// a function of its inputs: `Set<LeadOffset>` and `Dictionary` both iterate
    /// in an order that is not stable across runs, and a budget cut that landed
    /// differently on identical data would be untestable and unexplainable.
    private static func isMoreUrgent(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        if lhs.isRecurring != rhs.isRecurring { return !lhs.isRecurring }
        return identifier(for: lhs) < identifier(for: rhs)
    }

    /// The daily "what's due" summary.
    ///
    /// It counts through the same per-course gates the individual reminders use.
    /// A digest that included a muted class would be the mute leaking straight
    /// back in through a different door — the student turned that class off and
    /// would still be told about it every morning, which is worse than not
    /// having the switch, because now it looks broken.
    func digestRequest(
        from items: [DashItem],
        now: Date = Date(),
        preferences: CoursePreferencesStore? = nil
    ) -> UNNotificationRequest? {
        let prefs = resolvedPreferences(preferences)
        let soon = now.addingTimeInterval(86_400)
        let count = items.filter { item in
            guard !item.isCompleted, let due = item.due else { return false }
            guard due > now, due <= soon else { return false }
            let course = item.assignment.course
            guard prefs.notificationsEnabled(course) else { return false }
            if RecurringTask.isOccurrence(item.assignment), !prefs.recurringEnabled(course) {
                return false
            }
            return true
        }.count

        let content = UNMutableNotificationContent()
        content.title = "What's due"
        content.body = count == 0
            ? "nothing due in the next 24 hours. go enjoy life."
            : "\(count) assignment\(count == 1 ? "" : "s") due in the next 24 hours."
        content.sound = .default

        let comps = DateComponents(hour: digestTime.hour ?? 8, minute: digestTime.minute ?? 0)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        return UNNotificationRequest(identifier: "digest:daily", content: content, trigger: trigger)
    }

    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return f.string(from: date)
    }
}

/// Shows banners even when the app is in the foreground.
private final class ForegroundPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
