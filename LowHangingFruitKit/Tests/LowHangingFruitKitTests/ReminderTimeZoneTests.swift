import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A reminder is planned from an instant (due minus the lead time) and handed
/// to the system as wall-clock components. Components with no zone are read
/// in whatever zone the phone is in when the reminder is due, so a student who
/// flies after the plan is made is reminded at the right hour on the wrong
/// clock (hardening plan C6, NOT-06). The planner pins the zone it read them
/// in.
///
/// These tests do not trust the planner's own account of that. They ask the
/// system what the trigger means: `UNCalendarNotificationTrigger
/// .nextTriggerDate()` resolves the components the way delivery does, needs no
/// notification center, and runs in this test process. Whether iOS on a phone
/// resolves them the same way is the one thing only a device can confirm.
/// Zones a long way apart, so at least three of them are not the machine's.
private let reminderZones = ["Asia/Tokyo", "Pacific/Auckland", "America/Los_Angeles", "Europe/London"]

@MainActor
@Suite("Reminder time zone")
struct ReminderTimeZoneTests {

    @Test("An ordinary reminder's trigger means the instant it was planned for, whatever zone the phone is in later",
          arguments: reminderZones)
    func triggerIsTheInstantItWasPlannedFor(zone: String) throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let (scheduler, name) = try makeScheduler()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let now = Date()
        let items = [
            item("CIS 1200", "a", due: now + 30 * 3600),
            item("MATH 1400", "b", due: now + 100 * 3600),
        ]

        let requests = scheduler.plannedRequests(from: items, now: now, calendar: calendar)
            .filter { $0.identifier.hasPrefix("due:") }
        #expect(!requests.isEmpty)

        for request in requests {
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger, "\(request.identifier)")
            #expect(trigger.dateComponents.timeZone == timeZone, "\(request.identifier) pins the zone it was read in")

            // The instant planned, to the minute: components stop at minutes.
            let lead = try #require(Int(request.identifier.split(separator: ":").last ?? ""))
            let due = try #require(items.first { request.identifier.hasPrefix("due:\($0.assignment.id):") }?.due)
            let planned = due.addingTimeInterval(-Double(lead))
            let minute = Date(timeIntervalSince1970: (planned.timeIntervalSince1970 / 60).rounded(.down) * 60)
            #expect(trigger.nextTriggerDate() == minute,
                    "\(request.identifier) in \(zone): fires when it was planned to, not in the phone's zone")
        }
    }

    @Test("With no calendar given, the zone pinned is the phone's current one")
    func defaultsToTheCurrentZone() throws {
        let (scheduler, name) = try makeScheduler()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let now = Date()
        let requests = scheduler.plannedRequests(from: [item("CIS 1200", "a", due: now + 30 * 3600)], now: now)
            .filter { $0.identifier.hasPrefix("due:") }
        #expect(!requests.isEmpty)
        for request in requests {
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            #expect(trigger.dateComponents.timeZone == Calendar.current.timeZone)
        }
    }

    // MARK: Fixture

    /// A scheduler over a scratch suite, loud alert off (its buzzes use
    /// interval triggers and are not under test), with the two default lead
    /// times on.
    private func makeScheduler() throws -> (NotificationScheduler, String) {
        let name = "lhf.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let scheduler = NotificationScheduler(defaults: defaults)
        scheduler.setLoudAlertEnabled(false)
        for offset in LeadOffset.allCases {
            scheduler.setOffset(offset, on: offset == .h24 || offset == .h1)
        }
        return (scheduler, name)
    }

    private func item(_ course: String, _ id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }
}
