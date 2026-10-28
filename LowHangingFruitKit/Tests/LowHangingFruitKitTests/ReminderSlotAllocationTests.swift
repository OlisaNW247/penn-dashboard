import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// How the sixty pending-notification slots are shared out: the reminders that
/// fire in the next 48 hours first, then round-robin by class for the rest
/// (hardening plan C4, NOT-04).
///
/// The planner was round-robin by class and nothing else, so a class with a
/// lot due tomorrow was held to the same share as a class whose work is due
/// next month, and a reminder for tomorrow could be the one the cut fell on
/// while a reminder three weeks out was kept. `PerCourseNotificationTests`
/// pins the fairness half (no class starves another); this pins the urgency
/// half. Every test plans through `plannedRequests`, which is pure, on its own
/// `UserDefaults` suite.
@Suite("Reminder slot allocation: urgent first")
struct ReminderSlotAllocationTests {

    // MARK: Urgent reminders are reserved first

    /// The class with the work due tomorrow has 50 reminders firing inside 48
    /// hours; five quiet classes have 20 reminders each, all weeks out. A flat
    /// round-robin gives each of the six classes ten slots, so the busy class
    /// keeps 10 of its 50 and the quiet classes keep ten reminders that are
    /// nowhere near firing. Urgent-first keeps all 50 and shares the other ten.
    @Test("Reminders firing in the next 48 hours get slots before any later one, whatever class they belong to")
    @MainActor
    func urgentBeforeLater() {
        withScheduler(leadTimes: [.h1]) { scheduler, now in
            var items = (0..<50).map {
                item("CIS 1200", "now\($0)", due: now + 3 * 3600 + Double($0) * 3000)
            }
            let quiet = ["MATH 1400", "PHYS 0150", "ECON 0100", "ENGL 0050", "HIST 0100"]
            for course in quiet {
                for i in 0..<20 {
                    items.append(item(course, "\(course)-\(i)", due: now + 5 * 86_400 + Double(i) * 3600))
                }
            }

            let requests = scheduler.plannedRequests(from: items, now: now)
            let counts = countsByCourse(requests, in: items)

            #expect(requests.count == NotificationScheduler.maxPending)
            #expect(counts["CIS 1200"] == 50, "every urgent reminder keeps its slot")
            for course in quiet {
                #expect(counts[course] == 2, "\(course): the other ten slots are shared by class")
            }
        }
    }

    /// More than the budget fires inside the window, so the urgent round itself
    /// has to be shared, or one class would take all sixty and the others would
    /// go quiet on the day it matters most.
    @Test("When more than the budget is urgent, the urgent round is still shared by class")
    @MainActor
    func urgentRoundIsSharedByClass() {
        withScheduler(leadTimes: [.h1]) { scheduler, now in
            var items: [DashItem] = []
            for course in ["CIS 1200", "MATH 1400", "PHYS 0150"] {
                for i in 0..<30 {
                    items.append(item(course, "\(course)-\(i)", due: now + 3 * 3600 + Double(i) * 3000))
                }
            }
            let requests = scheduler.plannedRequests(from: items, now: now)
            let counts = countsByCourse(requests, in: items)

            #expect(requests.count == NotificationScheduler.maxPending)
            #expect(counts == ["CIS 1200": 20, "MATH 1400": 20, "PHYS 0150": 20])
        }
    }

    /// Deliberately not main-actor: the urgency rule is pure and declared
    /// `nonisolated`, and this is the test that holds it to that. The suite is
    /// not isolated either, so this calls it from a nonisolated context (a
    /// compile-time check) and from a detached task (a run-time one, the
    /// `decidedText` trap in CLAUDE.md: a helper that quietly inherits
    /// main-actor isolation dies in `_dispatch_assert_queue_fail` off the main
    /// actor, with no "Fatal error" line).
    @Test("The window is 48 hours and its end is inclusive, and the rule can be called off the main actor")
    func windowBoundary() async {
        let now = Date()
        #expect(NotificationScheduler.urgentWindow == 48 * 3600)
        #expect(NotificationScheduler.isUrgent(fireDate: now + 1, now: now))
        #expect(NotificationScheduler.isUrgent(fireDate: now + 48 * 3600, now: now))
        #expect(!NotificationScheduler.isUrgent(fireDate: now + 48 * 3600 + 1, now: now))

        let offMain = await Task.detached {
            (NotificationScheduler.isUrgent(fireDate: now + 48 * 3600, now: now),
             NotificationScheduler.isUrgent(fireDate: now + 48 * 3600 + 1, now: now),
             NotificationScheduler.urgentWindow)
        }.value
        #expect(offMain.0 && !offMain.1 && offMain.2 == 48 * 3600)
    }

    /// Urgency is about when the reminder fires, not when the work is due. The
    /// work here is due in 50 hours, and three of its four reminders fire in
    /// 2, 26 and 47 hours. Forty other classes with weeks to go share the rest.
    /// Round-robin gave the first class two slots of the four; judged on the
    /// fire date all three urgent ones are reserved.
    @Test("Urgency is judged on when a reminder fires, not when the work is due")
    @MainActor
    func urgencyIsTheFireDate() {
        withScheduler(leadTimes: [.d2, .h24, .h3, .h1]) { scheduler, now in
            var items = [item("CIS 1200", "soon", due: now + 50 * 3600)]
            for c in 0..<40 {
                for i in 0..<2 {
                    items.append(item("C\(c)", "c\(c)-\(i)", due: now + 10 * 86_400 + Double(i) * 3600))
                }
            }
            let ids = Set(scheduler.plannedRequests(from: items, now: now).map(\.identifier))
            for offset in [LeadOffset.d2, .h24, .h3] {
                #expect(ids.contains("due:canvas:soon:\(offset.rawValue)"), "fires inside 48 hours: \(offset)")
            }
        }
    }

    // MARK: The slots the buzzes kept are freed in alarm mode

    @Test("In alarm mode the thirty slots kept for the buzzes go to the other reminders, and a fallback to the buzzes stays in the cap")
    @MainActor
    func alarmModeFreesTheBuzzSlots() {
        withScheduler(leadTimes: [.h1], loudAlerts: true) { scheduler, now in
            let courses = ["CIS 1200", "MATH 1400", "PHYS 0150"]
            let items = (0..<60).map {
                item(courses[$0 % 3], "w\($0)", due: now + 2 * 3600 + Double($0) * 1800)
            }
            let buzzMode = scheduler.plannedRequests(from: items, now: now, loudAlertsAsAlarms: false)
            let alarmMode = scheduler.plannedRequests(from: items, now: now, loudAlertsAsAlarms: true)

            let buzzes = buzzMode.filter { $0.identifier.hasPrefix("loud:") }
            let plainInBuzzMode = buzzMode.filter { $0.identifier.hasPrefix("due:") }
            let plainInAlarmMode = alarmMode.filter { $0.identifier.hasPrefix("due:") }

            #expect(buzzes.count == NotificationScheduler.maxLoudItems * NotificationScheduler.loudAlertCount)
            #expect(buzzMode.count == NotificationScheduler.maxPending)
            #expect(alarmMode.allSatisfy { !$0.identifier.hasPrefix("loud:") })
            #expect(plainInAlarmMode.count == NotificationScheduler.maxPending)
            #expect(plainInAlarmMode.count == plainInBuzzMode.count + buzzes.count,
                    "the buzzes' slots are in use by plain reminders")
            #expect(Set(plainInBuzzMode.map(\.identifier)).isSubset(of: Set(plainInAlarmMode.map(\.identifier))))
        }
    }

    @Test("The same items and settings always produce the same plan, urgent round included")
    @MainActor
    func deterministic() {
        withScheduler(leadTimes: [.h1, .h24]) { scheduler, now in
            var items: [DashItem] = []
            for course in ["CIS 1200", "MATH 1400", "PHYS 0150"] {
                for i in 0..<40 {
                    items.append(item(course, "\(course)-\(i)", due: now + 2 * 3600 + Double(i) * 4000))
                }
            }
            let first = scheduler.plannedRequests(from: items, now: now).map(\.identifier)
            let second = scheduler.plannedRequests(from: items.reversed(), now: now).map(\.identifier)
            #expect(first == second)
        }
    }

    // MARK: Fixture

    /// A scheduler over a scratch defaults suite with exactly `leadTimes` on.
    /// The loud alert is off unless asked for: it draws on the same budget.
    @MainActor
    private func withScheduler(
        leadTimes: Set<LeadOffset>, loudAlerts: Bool = false,
        _ body: (NotificationScheduler, Date) -> Void
    ) {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a scratch defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let scheduler = NotificationScheduler(defaults: defaults)
        scheduler.setLoudAlertEnabled(loudAlerts)
        for offset in LeadOffset.allCases {
            scheduler.setOffset(offset, on: leadTimes.contains(offset))
        }
        body(scheduler, Date())
    }

    private func item(_ course: String, _ id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    /// Plain reminders per class, mapped back to the item by identifier.
    private func countsByCourse(_ requests: [UNNotificationRequest], in items: [DashItem]) -> [String: Int] {
        requests.filter { $0.identifier.hasPrefix("due:") }.reduce(into: [:]) { counts, request in
            guard let course = items.first(where: { request.identifier.hasPrefix("due:\($0.assignment.id):") })?
                .assignment.course else { return }
            counts[course, default: 0] += 1
        }
    }
}
