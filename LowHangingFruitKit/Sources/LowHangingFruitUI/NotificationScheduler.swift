import Foundation
import UserNotifications
import LowHangingFruitKit

/// Schedules local due-date reminders. Cross-platform: `UNUserNotificationCenter`
/// works on iOS 17 and macOS 14, and local notifications need no entitlement and
/// no Info.plist usage string. Notification logic lives in the app/UI layer (not
/// in the data-layer `AppState`) and reads the override-aware `DashItem`s from the
/// view-model so manually-adjusted due dates are respected.
@MainActor
final class NotificationScheduler: ObservableObject {

    /// How far before a due date a reminder fires.
    enum LeadOffset: Int, CaseIterable, Identifiable, Codable {
        case h1 = 3600
        case h3 = 10800
        case h24 = 86_400
        case d2 = 172_800
        case d7 = 604_800

        var id: Int { rawValue }

        /// Settings-row label.
        var label: String {
            switch self {
            case .h1:  return "1 hour before"
            case .h3:  return "3 hours before"
            case .h24: return "1 day before"
            case .d2:  return "2 days before"
            case .d7:  return "1 week before"
            }
        }

        /// Notification headline prefix.
        var headline: String {
            switch self {
            case .h1:  return "Due in 1 hour"
            case .h3:  return "Due in 3 hours"
            case .h24: return "Due tomorrow"
            case .d2:  return "Due in 2 days"
            case .d7:  return "Due in a week"
            }
        }
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var leadOffsets: Set<LeadOffset>
    @Published private(set) var digestEnabled: Bool
    @Published private(set) var digestTime: DateComponents
    @Published private(set) var authStatus: UNAuthorizationStatus = .notDetermined

    // Lazy so launch on an unbundled binary never touches the notification center.
    private lazy var center = UNUserNotificationCenter.current()
    private let foregroundDelegate = ForegroundPresentationDelegate()

    private static let enabledKey      = "notif.enabled"
    private static let offsetsKey      = "notif.leadOffsets"
    private static let digestKey       = "notif.digestEnabled"
    private static let digestHourKey   = "notif.digestHour"
    private static let digestMinuteKey = "notif.digestMinute"

    /// iOS caps pending local notifications at 64; stay under it with headroom.
    static let maxPending = 60
    static let horizonDays = 14

    init() {
        let d = UserDefaults.standard
        self.isEnabled = d.bool(forKey: Self.enabledKey)
        if let raw = d.array(forKey: Self.offsetsKey) as? [Int], !raw.isEmpty {
            self.leadOffsets = Set(raw.compactMap(LeadOffset.init(rawValue:)))
        } else {
            self.leadOffsets = [.h24, .h1]
        }
        self.digestEnabled = d.bool(forKey: Self.digestKey)
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
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            _ = await requestAuthorization()
        } else {
            cancelAll()
        }
    }

    func setOffset(_ offset: LeadOffset, on: Bool) {
        if on { leadOffsets.insert(offset) } else { leadOffsets.remove(offset) }
        UserDefaults.standard.set(leadOffsets.map(\.rawValue), forKey: Self.offsetsKey)
    }

    func setDigestEnabled(_ on: Bool) {
        digestEnabled = on
        UserDefaults.standard.set(on, forKey: Self.digestKey)
    }

    func setDigestTime(_ comps: DateComponents) {
        digestTime = DateComponents(hour: comps.hour ?? 8, minute: comps.minute ?? 0)
        UserDefaults.standard.set(digestTime.hour, forKey: Self.digestHourKey)
        UserDefaults.standard.set(digestTime.minute, forKey: Self.digestMinuteKey)
    }

    // MARK: Reschedule (idempotent)

    /// Cancels all app-scheduled reminders and re-adds them from the current items.
    /// Completed / submitted / too-old / rescheduled items drop off automatically.
    func reschedule(from items: [DashItem], now: Date = Date()) async {
        guard isEnabled else { cancelAll(); return }
        await refreshAuthStatus()
        guard authStatus == .authorized || authStatus == .provisional else { return }
        center.delegate = foregroundDelegate
        cancelAll()
        for request in plannedRequests(from: items, now: now) {
            try? await center.add(request)
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
            content.body = "\(change.title) — \(Self.formatScore(change))"
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

    // MARK: Planning (pure; no UNUserNotificationCenter access — unit-testable)

    func plannedRequests(from items: [DashItem], now: Date = Date()) -> [UNNotificationRequest] {
        let horizon = now.addingTimeInterval(Double(Self.horizonDays) * 86_400)

        struct Pair { let item: DashItem; let offset: LeadOffset; let fireDate: Date }
        var pairs: [Pair] = []
        for item in items {
            guard !item.isCompleted, let due = item.due, due > now, due <= horizon else { continue }
            for offset in leadOffsets {
                let fire = due.addingTimeInterval(-Double(offset.rawValue))
                if fire > now { pairs.append(Pair(item: item, offset: offset, fireDate: fire)) }
            }
        }
        pairs.sort { $0.fireDate < $1.fireDate }

        let budget = max(0, Self.maxPending - (digestEnabled ? 1 : 0))
        let calendar = Calendar.current

        var requests: [UNNotificationRequest] = pairs.prefix(budget).map { pair in
            let content = UNMutableNotificationContent()
            // Lead the title with a colored urgency dot (iOS won't let us tint
            // notification text, so the emoji carries the tier through).
            let urgency = DueState(due: pair.item.due, now: pair.fireDate)
            content.title = "\(urgency.urgencyEmoji) \(pair.offset.headline): \(pair.item.assignment.title)"
            content.body = "\(pair.item.assignment.course) · due \(Self.format(pair.item.due ?? pair.fireDate))"
            content.sound = .default
            content.interruptionLevel = urgency.isTimeSensitive ? .timeSensitive : .active
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: pair.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let id = "due:\(pair.item.assignment.id):\(pair.offset.rawValue)"
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }

        if digestEnabled, let digest = digestRequest(from: items, now: now) {
            requests.append(digest)
        }
        return requests
    }

    func digestRequest(from items: [DashItem], now: Date = Date()) -> UNNotificationRequest? {
        let soon = now.addingTimeInterval(86_400)
        let count = items.filter { item in
            guard !item.isCompleted, let due = item.due else { return false }
            return due > now && due <= soon
        }.count

        let content = UNMutableNotificationContent()
        content.title = "What's due"
        content.body = count == 0
            ? "Nothing due in the next 24 hours — go enjoy life."
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
