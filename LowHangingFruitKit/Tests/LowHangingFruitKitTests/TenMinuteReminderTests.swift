import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// "10 minutes before" (`LeadOffset.m10`), the fifth reminder lead time.
///
/// Two things about it are easy to get wrong and silent when wrong, which is
/// why it has a suite of its own rather than a line in the neighbours:
///
/// - **It is opt-in.** A student who saved their reminder settings before the
///   case existed must get exactly the reminders they got before, with no
///   10-minute nudge appearing on its own. Nothing about adding an enum case
///   guarantees that; it holds only because `LeadOffset.defaults` and the
///   saved selections do not mention it, and these tests are what would notice
///   if a later change made `offered` double as the default.
/// - **It sits right at the edge of "too late".** The planner drops any
///   reminder whose fire time is already behind it, and a 10-minute lead is
///   the first one a student can plausibly be inside of when they open the app
///   (an item due in 5 minutes has no 10-minute reminder left to give).
///
/// Everything drives `NotificationScheduler.plannedRequests`, which returns
/// requests instead of adding them, so no notification is ever scheduled and
/// no permission prompt can fire. Every test runs on its own `UserDefaults`
/// suite for the reason given at the top of `PerCourseNotificationTests`:
/// `UserDefaults.lhf` is the shared standard domain in a `swift test` run.
@MainActor
@Suite("10-minute reminder")
struct TenMinuteReminderTests {

    // MARK: The case itself

    /// Raw values are seconds and are persisted as ints in two places, so this
    /// number is a promise to every phone that ever saves it.
    @Test("m10's raw value is 600 seconds and it decodes back from that int")
    func rawValueIsFrozen() {
        #expect(LeadOffset.m10.rawValue == 600)
        #expect(LeadOffset(rawValue: 600) == .m10)
        // The neighbours did not move.
        #expect(LeadOffset.h1.rawValue == 3600)
        #expect(LeadOffset.h24.rawValue == 86_400)
    }

    @Test("m10 is worded in the voice of the other lead times")
    func wording() {
        #expect(LeadOffset.m10.label == "10 minutes before")
        #expect(LeadOffset.m10.headline == "Due in 10 minutes")
        // Same shape as its neighbours: the Profile summary strips " before"
        // from the label, and the notification body is the headline alone.
        #expect(LeadOffset.m10.label.hasSuffix(" before"))
        #expect(LeadOffset.m10.headline.hasPrefix("Due in "))
    }

    @Test("m10 is offered first, is not a default, and is not shown at first run")
    func listMembership() {
        #expect(LeadOffset.offered == [.m10, .h1, .h3, .h24, .d2])
        #expect(LeadOffset.offered.contains(.m10))
        #expect(!LeadOffset.defaults.contains(.m10))
        #expect(LeadOffset.defaults == [.h24, .h1])
        #expect(!LeadOffset.onboardingOffered.contains(.m10))
        #expect(LeadOffset.onboardingOffered == [.h1, .h3, .h24, .d2])
    }

    /// A first-run pill for a lead time the planner skips would be a switch
    /// that does nothing, which is exactly how `.d7` would have behaved had it
    /// stayed on screen after leaving `offered`.
    @Test("Everything the first-run screen shows is something the scheduler will fire")
    func onboardingListIsASubsetOfOffered() {
        #expect(Set(LeadOffset.onboardingOffered).isSubset(of: Set(LeadOffset.offered)))
        #expect(Set(LeadOffset.onboardingOffered).count == LeadOffset.onboardingOffered.count,
                "no pill is shown twice")
    }

    // MARK: Persistence

    @Test("m10 round-trips through the global reminder setting")
    func roundTripsThroughTheGlobalStore() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            #expect(!scheduler.leadOffsets.contains(.m10), "off until the student turns it on")

            scheduler.setOffset(.m10, on: true)
            #expect(scheduler.leadOffsets == LeadOffset.defaults.union([.m10]))
            // On disk it is the raw second count, like every other lead time.
            #expect((defaults.array(forKey: "notif.leadOffsets") as? [Int])?.contains(600) == true)

            // A relaunch: a second scheduler over the same defaults.
            let relaunched = NotificationScheduler(defaults: defaults)
            #expect(relaunched.leadOffsets == LeadOffset.defaults.union([.m10]))

            relaunched.setOffset(.m10, on: false)
            #expect(NotificationScheduler(defaults: defaults).leadOffsets == LeadOffset.defaults)
        }
    }

    @Test("m10 round-trips through a course's own override, alone or with others")
    func roundTripsThroughCoursePreferences() {
        withScratchDefaults { defaults in
            let prefs = CoursePreferencesStore(defaults: defaults)
            prefs.setLeadOffsets("CIS 1200", [.m10])
            prefs.setLeadOffsets("MATH 1400", [.m10, .d2])

            let reloaded = CoursePreferencesStore(defaults: defaults)
            #expect(reloaded.leadOffsets(for: "CIS 1200") == [.m10])
            #expect(reloaded.leadOffsets(for: "MATH 1400") == [.m10, .d2])
            #expect(reloaded.leadOffsets(for: "PHYS 0150") == nil, "an untouched course still inherits")
        }

        // And the value itself, independent of the store: the same JSON shape
        // the blob uses, sorted raw seconds.
        let record = CoursePreferences(courseKey: "CIS 1200", leadOffsets: [.d2, .m10])
        let json = try? JSONEncoder().encode(record)
        let decoded = json.flatMap { try? JSONDecoder().decode(CoursePreferences.self, from: $0) }
        #expect(decoded?.leadOffsets == [.d2, .m10])
        if let json, let text = String(data: json, encoding: .utf8) {
            #expect(text.contains("[600,172800]"), "stored as raw seconds, shortest first: \(text)")
        } else {
            Issue.record("could not encode a CoursePreferences record")
        }
    }

    // MARK: Scheduling

    @Test("A 10-minute reminder for an item due in 30 minutes fires at due minus 10 minutes")
    func schedulesAtDueMinusTenMinutes() throws {
        try withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            let due = now + 30 * 60
            let item = assignment("CIS 1200", "hw", due: due)
            let requests = scheduler.plannedRequests(from: [item], now: now, preferences: prefs)

            #expect(requests.map(\.identifier) == ["due:canvas:hw:600"])
            let request = try #require(requests.first)
            #expect(request.content.title == "CIS 1200")
            #expect(request.content.body == "Due in 10 minutes")

            // The trigger carries minute-resolution components for due − 10
            // minutes. Minute resolution floors the fire time, so it may land
            // up to a minute early but never late and never on another minute.
            let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
            #expect(!trigger.repeats)
            let fire = due - 600
            let calendar = Calendar.current
            #expect(trigger.dateComponents
                    == calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire))
            let next = try #require(trigger.nextTriggerDate())
            #expect(next <= fire)
            #expect(fire.timeIntervalSince(next) < 60)
        }
    }

    @Test("A 10-minute reminder is not scheduled once its time has passed")
    func tooLateIsNotScheduled() {
        withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            // Due in 5 minutes: the 10-minute reminder would have fired 5
            // minutes ago.
            let items = [
                assignment("CIS 1200", "five", due: now + 5 * 60),
                // Just outside and just inside the boundary. Not exactly 600 s:
                // `fire > now` is strict and the arithmetic is on `Date`s.
                assignment("CIS 1200", "justPast", due: now + 599),
                assignment("CIS 1200", "justAhead", due: now + 601),
            ]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.map(\.identifier) == ["due:canvas:justAhead:600"])
        }
    }

    /// The time-sensitive level comes from `DueState(due:now: fireDate)`, so it
    /// is decided by how close to the deadline the reminder lands. Ten minutes
    /// out is the most urgent tier there is.
    @Test("A 10-minute reminder breaks through Focus; a 1-day one does not")
    func interruptionLevel() {
        withScheduler(leadTimes: [.m10, .h24]) { scheduler, prefs, now in
            let requests = scheduler.plannedRequests(
                from: [assignment("CIS 1200", "hw", due: now + 3 * 86_400)],
                now: now, preferences: prefs)
            let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.identifier, $0) })
            #expect(byID["due:canvas:hw:600"]?.content.interruptionLevel == .timeSensitive)
            #expect(byID["due:canvas:hw:86400"]?.content.interruptionLevel == .active)
        }
    }

    // MARK: Opt-in: nothing changes for an existing install

    /// The on-disk shape an install from before `.m10` wrote: raw seconds under
    /// `notif.leadOffsets` (the key `SharedDefaults.legacyKeys` also lists),
    /// here including the since-retired `.d7`. Read back, planned, and
    /// compared with exactly the reminders that install always got.
    @Test("A selection saved before m10 existed schedules exactly what it always did")
    func savedSelectionPredatingM10IsUnchanged() {
        withScratchDefaults { defaults in
            defaults.set([86_400, 3600, 604_800], forKey: "notif.leadOffsets")
            let scheduler = NotificationScheduler(defaults: defaults)
            let prefs = CoursePreferencesStore(defaults: defaults)
            let now = Date()

            #expect(scheduler.leadOffsets == [.h24, .h1, .d7])
            let items = [assignment("CIS 1200", "hw", due: now + 5 * 86_400)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(Set(requests.map(\.identifier))
                    == ["due:canvas:hw:86400", "due:canvas:hw:3600"])
        }
    }

    @Test("An install that never touched reminder settings gets no 10-minute reminder")
    func freshInstallGetsNoTenMinuteReminder() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            let prefs = CoursePreferencesStore(defaults: defaults)
            let now = Date()

            #expect(scheduler.leadOffsets == LeadOffset.defaults)
            let items = [assignment("CIS 1200", "hw", due: now + 5 * 86_400)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(Set(requests.map(\.identifier))
                    == ["due:canvas:hw:86400", "due:canvas:hw:3600"])
        }
    }

    @Test("A per-class set saved before m10 existed is unchanged too")
    func perClassSelectionPredatingM10IsUnchanged() {
        withScratchDefaults { defaults in
            let scheduler = makeScheduler(on: defaults, leadTimes: [.h24, .h1])
            CoursePreferencesStore(defaults: defaults).setLeadOffsets("CIS 1200", [.d2, .h1])

            // A relaunch: the planner reads a store opened afresh over the
            // same defaults, as it does in the app.
            let reloaded = CoursePreferencesStore(defaults: defaults)
            let now = Date()
            let items = [
                assignment("CIS 1200", "a", due: now + 5 * 86_400),
                assignment("MATH 1400", "b", due: now + 5 * 86_400),
            ]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: reloaded)
            #expect(Set(requests.map(\.identifier)) == [
                "due:canvas:a:172800", "due:canvas:a:3600",
                "due:canvas:b:86400", "due:canvas:b:3600",
            ])
        }
    }

    // MARK: Per-class override

    @Test("A class can choose 10 minutes alone, and the others keep the global set")
    func perClassOverrideCanSelectM10Alone() {
        withScheduler(leadTimes: [.h24, .h1]) { scheduler, prefs, now in
            prefs.setLeadOffsets("CIS 1200", [.m10])
            let items = [
                assignment("CIS 1200", "a", due: now + 5 * 86_400),
                assignment("MATH 1400", "b", due: now + 5 * 86_400),
            ]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(Set(requests.map(\.identifier)) == [
                "due:canvas:a:600",
                "due:canvas:b:86400", "due:canvas:b:3600",
            ])
        }
    }

    @Test("Turning m10 on globally is inherited by a class that follows the defaults")
    func globalM10IsInherited() {
        withScheduler(leadTimes: [.m10]) { scheduler, prefs, now in
            let items = [assignment("CIS 1200", "a", due: now + 5 * 86_400)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.map(\.identifier) == ["due:canvas:a:600"])
        }
    }

    // MARK: The 60-request budget with five offered lead times

    /// With five lead times a heavily-configured class has more candidates per
    /// assignment, and the new one fires *latest* for any given item. Within a
    /// class the planner keeps the soonest-firing reminders and cuts the
    /// far-out tail, so the cut must never take something that fires earlier
    /// than something it kept.
    @Test("Within a class the budget keeps the earliest-firing reminders, whatever their lead time")
    func budgetKeepsTheEarliestFiringWithinAClass() {
        withScheduler(leadTimes: Set(LeadOffset.offered)) { scheduler, prefs, now in
            // 14 items × 5 lead times = 70 candidates for 60 slots, all firing
            // in the future (the nearest item is due three days out).
            let items = (0..<14).map {
                assignment("CIS 1200", "a\($0)", due: now + 3 * 86_400 + Double($0) * 3600)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.count == NotificationScheduler.maxPending)

            let all = candidateFireDates(items, now: now)
            #expect(all.count == 70)
            let keptIDs = Set(requests.map(\.identifier))
            let kept = all.filter { keptIDs.contains($0.key) }.map(\.value)
            let dropped = all.filter { !keptIDs.contains($0.key) }.map(\.value)
            #expect(kept.count == NotificationScheduler.maxPending)
            #expect(dropped.count == 10)
            #expect((kept.max() ?? .distantPast) <= (dropped.min() ?? .distantFuture),
                    "everything dropped fires no earlier than everything kept")
        }
    }

    /// The case the new lead time makes plausible: a class buried in far-out
    /// work, and one item due in half an hour whose only remaining reminder is
    /// the 10-minute one.
    @Test("A near 10-minute reminder is not crowded out by far-out work in its own class")
    func nearReminderSurvivesCrowdingInItsOwnClass() {
        withScheduler(leadTimes: Set(LeadOffset.offered)) { scheduler, prefs, now in
            var items = (0..<14).map {
                assignment("CIS 1200", "far\($0)", due: now + 5 * 86_400 + Double($0) * 3600)
            }
            items.append(assignment("CIS 1200", "near", due: now + 30 * 60))

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.count == NotificationScheduler.maxPending)
            #expect(requests.contains { $0.identifier == "due:canvas:near:600" })
        }
    }

    @Test("A near 10-minute reminder in a quiet class survives a class with far more work")
    func nearReminderSurvivesAnotherClassesCrowding() {
        withScheduler(leadTimes: Set(LeadOffset.offered)) { scheduler, prefs, now in
            var items = (0..<14).map {
                assignment("CIS 1200", "far\($0)", due: now + 2 * 86_400 + Double($0) * 3600)
            }
            items.append(assignment("MATH 1400", "near", due: now + 30 * 60))

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.count == NotificationScheduler.maxPending)
            #expect(requests.contains { $0.identifier == "due:canvas:near:600" })
        }
    }

    // MARK: - Fixture

    /// A throwaway `UserDefaults` suite, removed afterwards.
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a scratch defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// A scheduler over `defaults` whose global lead times are exactly
    /// `leadTimes`. Every case is set explicitly so the result does not depend
    /// on what the scheduler started with.
    private func makeScheduler(on defaults: UserDefaults,
                               leadTimes: Set<LeadOffset>) -> NotificationScheduler {
        let scheduler = NotificationScheduler(defaults: defaults)
        for offset in LeadOffset.allCases {
            scheduler.setOffset(offset, on: leadTimes.contains(offset))
        }
        return scheduler
    }

    /// A scheduler with exactly `leadTimes` globally, a preferences store over
    /// the same scratch suite, and a `now` read once so lead times are
    /// arithmetic rather than a race with the clock.
    private func withScheduler(
        leadTimes: Set<LeadOffset>,
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) throws -> Void
    ) rethrows {
        try withScratchDefaults { defaults in
            try body(makeScheduler(on: defaults, leadTimes: leadTimes),
                     CoursePreferencesStore(defaults: defaults),
                     Date())
        }
    }

    // MARK: Item builders and plan readers

    private func assignment(_ course: String, _ id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    /// Every (item, offered lead time) the planner could produce for `items`
    /// whose fire time is still ahead, keyed by request identifier. Computed
    /// from the items alone, so it is an independent statement of what the
    /// full candidate set is rather than a replay of the planner.
    private func candidateFireDates(_ items: [DashItem], now: Date) -> [String: Date] {
        var result: [String: Date] = [:]
        for item in items {
            guard let due = item.due else { continue }
            for offset in LeadOffset.offered {
                let fire = due.addingTimeInterval(-Double(offset.rawValue))
                if fire > now { result["due:\(item.assignment.id):\(offset.rawValue)"] = fire }
            }
        }
        return result
    }
}
