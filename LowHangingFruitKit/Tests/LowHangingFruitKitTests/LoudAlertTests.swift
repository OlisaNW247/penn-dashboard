import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The loud 10-minute alert: three Time Sensitive notifications a few seconds
/// apart, at due minus 10 minutes, for work that has not been handed in.
///
/// Everything drives `NotificationScheduler.plannedRequests`, which returns
/// requests instead of adding them, so nothing is scheduled and no permission
/// prompt can fire. Every test runs on its own `UserDefaults` suite for the
/// reason given at the top of `PerCourseNotificationTests`: `UserDefaults.lhf`
/// is the shared standard domain in a `swift test` run.
///
/// **What these cannot show.** The master "due-date reminders" switch is
/// honoured by `reschedule` (it returns before planning when reminders are
/// off), which needs a live `UNUserNotificationCenter` and so cannot run
/// here; and whether iOS really delivers these as Time Sensitive depends on
/// the entitlement in `App/LHFApp.entitlements`, which only a device build
/// proves.
@MainActor
@Suite("Loud 10-minute alert")
struct LoudAlertTests {

    private static let lead = NotificationScheduler.loudAlertLead
    private static let spacing = NotificationScheduler.loudAlertSpacing

    // MARK: Which items qualify

    @Test("Only unsubmitted, submittable, dated, upcoming work in a class with reminders on qualifies")
    func qualifyingItems() {
        withScheduler { scheduler, prefs, now in
            prefs.setNotificationsEnabled("MUTED 100", false)

            let taskID = UUID()
            let items: [DashItem] = [
                assignment("CIS 1200", "yes", due: now + 6 * 3600),
                assignment("CIS 1200", "quiz", due: now + 6 * 3600, kind: .quiz),
                assignment("CIS 1200", "discussion", due: now + 6 * 3600, kind: .discussion),
                // A due-date override moves the due time the planner sees;
                // the feed date underneath is long past.
                assignment("CIS 1200", "moved", due: now - 86_400, override: now + 6 * 3600),
                // Days out, not hours: there is no "imminent only" window.
                assignment("CIS 1200", "fiveDays", due: now + 5 * 86_400),
                // Excluded, one reason each.
                assignment("CIS 1200", "done", due: now + 6 * 3600, completed: true),
                assignment("CIS 1200", "undated", due: nil),
                assignment("CIS 1200", "overdue", due: now - 3600),
                assignment("CIS 1200", "event", due: now + 6 * 3600, kind: .event),
                assignment("CIS 1200", "nosubmit", due: now + 6 * 3600, requiresNoSubmission: true),
                occurrence("CIS 1200", taskID: taskID, due: now + 6 * 3600),
                assignment("CIS 1200", "beyondHorizon",
                           due: now + Double(NotificationScheduler.horizonDays + 1) * 86_400),
                assignment("CIS 1200", "tooLate", due: now + 5 * 60),
                assignment("MUTED 100", "muted", due: now + 6 * 3600),
            ]

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(loudItemIDs(requests) == [
                "canvas:yes", "canvas:quiz", "canvas:discussion", "canvas:moved", "canvas:fiveDays",
            ])
        }
    }

    /// A class that has switched its lead times off has opted out of those
    /// reminders, not of being warned about work it has not handed in. Only the
    /// class's reminders-off switch silences the alert.
    @Test("A class with no lead times still gets the alert; a muted class does not")
    func leadTimesDoNotGateTheAlert() {
        withScheduler { scheduler, prefs, now in
            prefs.setLeadOffsets("CIS 1200", [])
            prefs.setNotificationsEnabled("MATH 1400", false)
            let items = [
                assignment("CIS 1200", "a", due: now + 6 * 3600),
                assignment("MATH 1400", "b", due: now + 6 * 3600),
            ]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(loudItemIDs(requests) == ["canvas:a"])
            // The empty lead-time set still means no ordinary reminders for it.
            #expect(!requests.contains { $0.identifier.hasPrefix("due:canvas:a:") })
        }
    }

    /// The alert looks as far ahead as the plain reminders do, because a
    /// shorter window would leave it to chance whether the app re-planned
    /// inside it. The limit is `horizonDays`, the very constant the plain
    /// reminders use, not one of its own.
    @Test("The alert reaches as far as the reminder horizon: just inside qualifies, just outside does not")
    func horizonEdges() {
        withScheduler { scheduler, prefs, now in
            let horizon = Double(NotificationScheduler.horizonDays) * 86_400
            let items = [
                assignment("CIS 1200", "inside", due: now + horizon - 1),
                assignment("CIS 1200", "exactly", due: now + horizon),
                assignment("CIS 1200", "outside", due: now + horizon + 1),
            ]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(loudItemIDs(requests) == ["canvas:inside", "canvas:exactly"])
        }
    }

    /// Eleven items, all five days or more out and each a day apart: the ten
    /// nearest get the alert, and the eleventh, which the cap leaves out, keeps
    /// its plain 10-minute reminder rather than ending up with neither.
    @Test("An item 5 days out gets the alert among the 10 nearest; the 11th nearest does not and keeps its plain 10-minute reminder")
    func fiveDaysOutAndTheEleventhNearest() {
        withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            let items = (0..<11).map {
                assignment("CIS 1200", "i\($0)", due: now + 5 * 86_400 + Double($0) * 3600)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            #expect(loudItemIDs(requests) == Set((0..<10).map { "canvas:i\($0)" }),
                    "the first item is 5 days out and is among the ten nearest")
            let ids = Set(requests.map(\.identifier))
            for index in 0..<10 { #expect(!ids.contains("due:canvas:i\(index):600")) }
            #expect(ids.contains("due:canvas:i10:600"))
            #expect(!ids.contains { $0.hasPrefix("loud:canvas:i10:") })
        }
    }

    // MARK: The three notifications

    @Test("Three requests at due minus 10 minutes, then 3 and 6 seconds later")
    func idsAndTimes() throws {
        try withScheduler { scheduler, prefs, now in
            let due = now + 2 * 3600
            let requests = scheduler.plannedRequests(
                from: [assignment("CIS 1200", "hw", due: due)], now: now, preferences: prefs)
            let loud = loudRequests(requests)

            #expect(loud.map(\.identifier) == ["loud:canvas:hw:1", "loud:canvas:hw:2", "loud:canvas:hw:3"])
            #expect(Set(loud.map(\.identifier)).count == 3, "no two share an identifier")

            for (index, request) in loud.enumerated() {
                let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
                let expected = due.addingTimeInterval(-Self.lead + Double(index) * Self.spacing)
                    .timeIntervalSince(now)
                #expect(abs(trigger.timeInterval - expected) < 0.001,
                        "notification \(index + 1) fires \(expected)s from now, got \(trigger.timeInterval)")
                #expect(!trigger.repeats)
                #expect(trigger.timeInterval > 0, "the initialiser traps on a non-positive interval")
            }

            // Spaced by exactly the configured gap: this is the "triple buzz".
            let gaps = try zip(loud, loud.dropFirst()).map { a, b -> TimeInterval in
                let ta = try #require(a.trigger as? UNTimeIntervalNotificationTrigger)
                let tb = try #require(b.trigger as? UNTimeIntervalNotificationTrigger)
                return tb.timeInterval - ta.timeInterval
            }
            #expect(gaps.allSatisfy { abs($0 - Self.spacing) < 0.001 })
        }
    }

    @Test("Time Sensitive, default sound, one thread per item, in the reminders' own wording")
    func contentAndThreading() {
        withScheduler { scheduler, prefs, now in
            prefs.setDisplayName("CIS 1200", to: "Programming")
            let items = [
                assignment("CIS 1200", "a", due: now + 2 * 3600),
                assignment("CIS 1200", "b", due: now + 3 * 3600),
            ]
            let loud = loudRequests(scheduler.plannedRequests(from: items, now: now, preferences: prefs))
            #expect(loud.count == 6)

            for request in loud {
                #expect(request.content.interruptionLevel == .timeSensitive)
                #expect(request.content.sound == .default)
                // The class as the student sees it on the card (their rename),
                // then the assignment's name and the 10-minute phrase.
                #expect(request.content.title == "Programming")
                let expectedBody = request.identifier.contains(":a:")
                    ? "HW a. Due in 10 minutes" : "HW b. Due in 10 minutes"
                #expect(request.content.body == expectedBody)
            }

            // One thread per item so each item's three stack together.
            let threads = Dictionary(grouping: loud, by: { $0.content.threadIdentifier })
            #expect(threads.count == 2)
            #expect(threads.values.allSatisfy { $0.count == 3 })
            #expect(Set(loud.map(\.content.threadIdentifier)).count == 2)
        }
    }

    /// The planner re-runs on every sync and activation. A re-plan that lands
    /// between the first and third notification must keep the ones still ahead,
    /// under the same identifiers, rather than cancel them and add nothing.
    @Test("A re-plan partway through the alert keeps the notifications still ahead")
    func partiallyElapsedAlert() throws {
        try withScheduler { scheduler, prefs, now in
            let due = now + 2 * 3600
            let item = assignment("CIS 1200", "hw", due: due)
            let first = due.addingTimeInterval(-Self.lead)

            // One second after the first has fired: #2 and #3 remain.
            let afterOne = scheduler.plannedRequests(
                from: [item], now: first.addingTimeInterval(1), preferences: prefs)
            #expect(loudRequests(afterOne).map(\.identifier) == ["loud:canvas:hw:2", "loud:canvas:hw:3"])
            let t2 = try #require(loudRequests(afterOne)[0].trigger as? UNTimeIntervalNotificationTrigger)
            #expect(abs(t2.timeInterval - 2) < 0.001, "3 s after the first, 1 s having passed")

            // Four seconds in: only #3.
            let afterTwo = scheduler.plannedRequests(
                from: [item], now: first.addingTimeInterval(4), preferences: prefs)
            #expect(loudRequests(afterTwo).map(\.identifier) == ["loud:canvas:hw:3"])

            // Past all three: none, and no ordinary 10-minute reminder either.
            let afterAll = scheduler.plannedRequests(
                from: [item], now: first.addingTimeInterval(7), preferences: prefs)
            #expect(loudRequests(afterAll).isEmpty)
        }
    }

    // MARK: No double alert with the plain 10-minute reminder

    @Test("With the plain 10-minute reminder also selected, the item gets only the loud one")
    func noDoubleAlertGlobal() {
        withScheduler(leadTimes: [.m10, .h1]) { scheduler, prefs, now in
            let items = [assignment("CIS 1200", "hw", due: now + 5 * 3600)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let ids = Set(requests.map(\.identifier))
            #expect(!ids.contains("due:canvas:hw:600"), "the loud alert replaces the plain 10-minute reminder")
            #expect(ids.contains("due:canvas:hw:3600"), "the other lead times are untouched")
            #expect(loudRequests(requests).count == 3)
        }
    }

    @Test("The same holds when a class chose the 10-minute reminder for itself")
    func noDoubleAlertPerClass() {
        withScheduler { scheduler, prefs, now in
            prefs.setLeadOffsets("CIS 1200", [.m10])
            let items = [
                assignment("CIS 1200", "a", due: now + 5 * 3600),
                assignment("MATH 1400", "b", due: now + 5 * 3600),
            ]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let ids = Set(requests.map(\.identifier))
            #expect(!ids.contains("due:canvas:a:600"))
            #expect(dueRequests(requests).filter { $0.identifier.hasPrefix("due:canvas:a:") }.isEmpty)
            #expect(loudItemIDs(requests) == ["canvas:a", "canvas:b"])
        }
    }

    @Test("With the alert off, the plain 10-minute reminder is back")
    func plainReminderReturnsWhenAlertIsOff() {
        withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            scheduler.setLoudAlertEnabled(false)
            let items = [assignment("CIS 1200", "hw", due: now + 5 * 3600)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.map(\.identifier) == ["due:canvas:hw:600"])
        }
    }

    /// An item that does not qualify for the alert keeps its plain reminder:
    /// dropping it for every item would leave a no-alert, no-reminder gap for
    /// work the alert never covered.
    @Test("An item the alert does not cover keeps its plain 10-minute reminder")
    func plainReminderStaysWhereTheAlertDoesNotReach() {
        withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            let items = [
                assignment("CIS 1200", "reading", due: now + 5 * 3600, kind: .event),
                assignment("CIS 1200", "nosubmit", due: now + 5 * 3600, requiresNoSubmission: true),
            ]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(Set(requests.map(\.identifier)) == ["due:canvas:reading:600", "due:canvas:nosubmit:600"])
            #expect(loudRequests(requests).isEmpty)
        }
    }

    // MARK: The 60-request budget

    @Test("Loud alerts take priority for the nearest items and the total stays under the cap")
    func capAndPriority() {
        withScheduler { scheduler, prefs, now in
            // 25 items in the next ~38 hours across three classes. Ordinary
            // candidates (1h for all, 24h for the later ones) alone would come
            // to 35; with 30 loud requests on top the total is 65 for 60 slots.
            let courses = ["CIS 1200", "MATH 1400", "PHYS 0150"]
            let items = (0..<25).map {
                assignment(courses[$0 % 3], "i\($0)", due: now + 2 * 3600 + Double($0) * 5400)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            #expect(requests.count == NotificationScheduler.maxPending)
            #expect(Set(requests.map(\.identifier)).count == requests.count, "no identifier twice")

            let loud = loudRequests(requests)
            #expect(loud.count == NotificationScheduler.maxLoudItems * NotificationScheduler.loudAlertCount)
            // Exactly the ten soonest-due items, all three notifications each.
            #expect(loudItemIDs(requests) == Set((0..<10).map { "canvas:i\($0)" }))
            #expect(Dictionary(grouping: loud, by: { $0.content.threadIdentifier }).values.allSatisfy { $0.count == 3 })

            // The rest of the budget still goes to ordinary reminders, and
            // across classes: the loud alerts did not starve a class.
            let ordinary = dueRequests(requests)
            #expect(ordinary.count == NotificationScheduler.maxPending - loud.count)
            let ordinaryCourses = Set(ordinary.compactMap { request in
                items.first { request.identifier.hasPrefix("due:\($0.assignment.id):") }?.assignment.course
            })
            #expect(ordinaryCourses == Set(courses))
        }
    }

    @Test("Even a pile of work with every lead time on never exceeds the cap")
    func neverOverTheCap() {
        withScheduler(leadTimes: Set(LeadOffset.offered)) { scheduler, prefs, now in
            let items = (0..<80).map {
                assignment("CIS 1200", "i\($0)", due: now + 1800 + Double($0) * 1200)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.count <= NotificationScheduler.maxPending)
            #expect(loudRequests(requests).count
                    == NotificationScheduler.maxLoudItems * NotificationScheduler.loudAlertCount)
        }
    }

    @Test("The alert goes to the soonest items, however the dashboard orders them")
    func nearestFirstWhateverTheInputOrder() {
        withScheduler { scheduler, prefs, now in
            // Twelve items, listed furthest-first; only the ten nearest get it.
            let items = (0..<12).reversed().map {
                assignment("CIS 1200", "i\($0)", due: now + 2 * 3600 + Double($0) * 3600)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(loudItemIDs(requests) == Set((0..<10).map { "canvas:i\($0)" }))
            // And the loud requests come out nearest-first, ahead of the rest.
            #expect(requests.prefix(3).map(\.identifier)
                    == ["loud:canvas:i0:1", "loud:canvas:i0:2", "loud:canvas:i0:3"])
        }
    }

    @Test("An item the cap leaves out keeps its plain 10-minute reminder")
    func cutItemKeepsPlainReminder() {
        withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            let items = (0..<12).map {
                assignment("CIS 1200", "i\($0)", due: now + 2 * 3600 + Double($0) * 3600)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let ids = Set(requests.map(\.identifier))
            for index in 0..<10 { #expect(!ids.contains("due:canvas:i\(index):600")) }
            for index in 10..<12 { #expect(ids.contains("due:canvas:i\(index):600")) }
        }
    }

    @Test("With nothing eligible for the alert the ordinary reminders keep the whole budget")
    func ordinaryBudgetUntouchedWithoutLoudItems() {
        withScheduler { scheduler, prefs, now in
            // Same shape as `NotificationSchedulerTests.testCapsAtMaxPending`,
            // but with items that take no submission, which the alert skips.
            let items = (0..<50).map {
                assignment("CIS 1200", "i\($0)", due: now + 3 * 86_400 + Double($0) * 60, kind: .event)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(loudRequests(requests).isEmpty)
            #expect(requests.count == NotificationScheduler.maxPending)
        }
    }

    // MARK: The switch

    @Test("With the alert switched off no loud request is planned, and the ordinary ones are unchanged")
    func switchedOff() {
        withScheduler { scheduler, prefs, now in
            let items = [
                assignment("CIS 1200", "a", due: now + 5 * 3600),
                assignment("CIS 1200", "b", due: now + 30 * 3600),
            ]
            let on = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            scheduler.setLoudAlertEnabled(false)
            let off = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            #expect(loudRequests(on).count == 6)
            #expect(loudRequests(off).isEmpty)
            #expect(Set(dueRequests(off).map(\.identifier)) == Set(dueRequests(on).map(\.identifier)))
        }
    }

    @Test("It is on for an install that never touched it")
    func defaultsOn() {
        withScratchDefaults { defaults in
            #expect(defaults.object(forKey: "notif.loudAlertEnabled") == nil)
            #expect(NotificationScheduler(defaults: defaults).loudAlertEnabled)
        }
    }

    @Test("The switch is saved in the injected defaults and survives a relaunch")
    func persistence() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            scheduler.setLoudAlertEnabled(false)
            #expect(!scheduler.loudAlertEnabled)
            #expect(defaults.object(forKey: "notif.loudAlertEnabled") as? Bool == false)

            let relaunched = NotificationScheduler(defaults: defaults)
            #expect(!relaunched.loudAlertEnabled)
            relaunched.setLoudAlertEnabled(true)
            #expect(NotificationScheduler(defaults: defaults).loudAlertEnabled)
        }
    }

    @Test("Turning it off is independent of the lead-time and turned-in settings")
    func independentOfTheOtherSwitches() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            let leadTimes = scheduler.leadOffsets
            let turnedIn = scheduler.turnedInEnabled
            scheduler.setLoudAlertEnabled(false)
            #expect(scheduler.leadOffsets == leadTimes)
            #expect(scheduler.turnedInEnabled == turnedIn)
        }
    }

    // MARK: - Fixture

    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a scratch defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// A scheduler over a scratch suite, the per-course store over the same
    /// suite, and a `now` read once so every time is arithmetic. The global
    /// lead times default to the app's own (`LeadOffset.defaults`).
    private func withScheduler(
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) throws -> Void
    ) rethrows {
        try withScratchDefaults { defaults in
            try body(NotificationScheduler(defaults: defaults),
                     CoursePreferencesStore(defaults: defaults),
                     Date())
        }
    }

    /// As above with exactly `leadTimes` set globally.
    private func withScheduler(
        leadTimes: Set<LeadOffset>,
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) throws -> Void
    ) rethrows {
        try withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            for offset in LeadOffset.allCases {
                scheduler.setOffset(offset, on: leadTimes.contains(offset))
            }
            try body(scheduler, CoursePreferencesStore(defaults: defaults), Date())
        }
    }

    // MARK: Item builders and plan readers

    private func assignment(
        _ course: String, _ id: String, due: Date?,
        kind: Assignment.Kind = .assignment,
        completed: Bool = false,
        requiresNoSubmission: Bool = false,
        override: Date? = nil
    ) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: kind,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: override, isCompleted: completed, completedAt: nil,
            requiresNoSubmission: requiresNoSubmission
        )
    }

    /// One occurrence of a recurring task (a weekly reading), built through the
    /// same minting function the generator uses so the test cannot drift from
    /// the format.
    private func occurrence(_ course: String, taskID: UUID, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(
                source: .canvasSuggestion,
                sourceID: RecurringTask.occurrenceSourceID(taskID: taskID, due: due),
                kind: .assignment, course: course, title: "Weekly reading",
                dueAt: due, url: nil
            ),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    private func loudRequests(_ requests: [UNNotificationRequest]) -> [UNNotificationRequest] {
        requests.filter { $0.identifier.hasPrefix("loud:") }
    }

    private func dueRequests(_ requests: [UNNotificationRequest]) -> [UNNotificationRequest] {
        requests.filter { $0.identifier.hasPrefix("due:") }
    }

    /// The `Assignment.id` of every item with at least one loud request,
    /// recovered from the identifier (`loud:<Assignment.id>:<n>`).
    private func loudItemIDs(_ requests: [UNNotificationRequest]) -> Set<String> {
        Set(loudRequests(requests).map { request in
            let body = request.identifier.dropFirst("loud:".count)
            return String(body.prefix(upTo: body.lastIndex(of: ":") ?? body.endIndex))
        })
    }
}
