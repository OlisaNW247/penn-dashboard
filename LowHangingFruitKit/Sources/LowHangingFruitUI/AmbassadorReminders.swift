import Foundation
import UserNotifications
import LowHangingFruitKit

/// How often the ambassador wants the nudge. Since 2026-11-21 the one on
/// offer is twice a week (Marco: twice a week is the right cadence for the
/// anonymous chats), with "every day" and "off" beside it. `.weekdays` stays
/// in the enum only so a phone that stored it still decodes and keeps its
/// five reminders; the picker no longer lists it (`offered`).
enum AmbassadorReminderCadence: String, CaseIterable, Codable, Sendable, Identifiable {
    case daily
    case weekdays
    case twiceWeekly
    case off

    var id: String { rawValue }

    /// What the picker shows, in order.
    static var offered: [AmbassadorReminderCadence] { [.twiceWeekly, .daily, .off] }

    var label: String {
        switch self {
        case .daily: return "every day"
        case .weekdays: return "weekdays"
        case .twiceWeekly: return "2 a week"
        case .off: return "off"
        }
    }
}

/// The ambassador's reminder as local notifications: the pure half.
///
/// **One repeating request, not one per day.** The post changes every day,
/// so the tempting plan is a notification per day with that day's post in
/// its body. iOS keeps about sixty-four pending local notifications, and the
/// due-date planner already budgets sixty of them (`NotificationScheduler.
/// maxPending`); fourteen more would push the queue over the cap and iOS
/// would drop reminders about real coursework to make room for a marketing
/// nudge, which is the wrong trade in every case. So the nudge is one
/// `UNCalendarNotificationTrigger` that repeats daily (one slot), or five
/// weekly ones for weekdays (five slots), with a fixed body that says a post
/// is ready, and the app fetches the actual words when it is opened. The
/// slots it does take are reserved out of the planner's budget
/// (`NotificationScheduler.reservedForeignSlots`) so the total never passes
/// sixty.
///
/// **The identifier prefix is the contract with the planner.** Every request
/// here starts with `ambassador:`, and `applyNotifications` leaves pending
/// requests with that prefix alone instead of removing them as stale. Without
/// that carve-out the reminder would be removed within five minutes of being
/// scheduled, by the first reschedule pass, because it is not in the
/// due-date plan. `removeAllPending()` (reminders switched off) and the
/// update wall's clear still take it; `AmbassadorModel` puts it back when the
/// app next becomes active.
enum AmbassadorReminders {
    static let identifierPrefix = "ambassador:"
    static let categoryIdentifier = "ambassador.daily"
    /// 7 pm: after classes, before the evening scroll, when the anonymous
    /// apps are busiest.
    static let defaultHour = 19
    static let defaultMinute = 0

    nonisolated static func isAmbassadorIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    /// How many of the pending-notification slots the cadence occupies.
    nonisolated static func reservedSlots(for cadence: AmbassadorReminderCadence) -> Int {
        switch cadence {
        case .daily: return 1
        case .weekdays: return 5
        case .twiceWeekly: return 2
        case .off: return 0
        }
    }

    /// The requests for `cadence` at `hour:minute`, in the phone's calendar.
    /// Empty when off. Deterministic identifiers, so re-adding replaces in
    /// place and a changed cadence can remove exactly the ones it no longer
    /// wants.
    nonisolated static func requests(
        cadence: AmbassadorReminderCadence,
        hour: Int = defaultHour,
        minute: Int = defaultMinute,
        firstName: String? = nil
    ) -> [UNNotificationRequest] {
        switch cadence {
        case .off:
            return []
        case .daily:
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            return [request(identifier: identifierPrefix + "daily", components: components, firstName: firstName)]
        case .weekdays, .twiceWeekly:
            // Monday (2) to Friday (6) in `Calendar`'s weekday numbering, or
            // Monday and Thursday for twice a week. The same identifier
            // scheme, so a change of cadence replaces in place.
            let days = cadence == .weekdays ? Array(2...6) : [2, 5]
            return days.map { weekday in
                var components = DateComponents()
                components.weekday = weekday
                components.hour = hour
                components.minute = minute
                return request(identifier: identifierPrefix + "weekday:\(weekday)", components: components, firstName: firstName)
            }
        }
    }

    private nonisolated static func request(identifier: String, components: DateComponents, firstName: String?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "smooth"
        content.body = body(firstName: firstName)
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.interruptionLevel = .active
        content.userInfo = ["ambassador": "daily"]
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    }

    /// The fixed body. It cannot name the platform or quote the post, since
    /// one request repeats every day (see the type's note); it says what is
    /// true every day.
    nonisolated static func body(firstName: String?) -> String {
        if let firstName, !firstName.isEmpty {
            return "today's post is written, \(firstName.lowercased()). tap to copy it."
        }
        return "today's post is written. tap to copy it."
    }
}
