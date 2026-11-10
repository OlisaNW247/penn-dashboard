import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The Sweeper page's model: per-class lead time and sound, where the planner
/// applies them, and the "next sweep" the page's card shows.
///
/// Every test runs on its own scratch `UserDefaults` suite and hands the
/// scheduler and the per-class store that same suite, so nothing is written to
/// the shared domain that other suites' `AppState.init` reads (see the
/// shared-`UserDefaults` traps in CLAUDE.md).
@MainActor
@Suite("Sweeper per-class overrides and next sweep")
struct SweeperOverridesTests {

    // MARK: Resolution

    @Test("A class follows the defaults until it chooses, and the default moves it")
    func resolutionFallsBack() {
        var settings = SweeperSettings(defaultMinutes: 10, defaultSound: .smooth)
        #expect(settings.resolved(for: "CIS 1200").minutes == 10)
        #expect(settings.resolved(for: "CIS 1200").sound == .smooth)
        #expect(!settings.hasOverride("CIS 1200"))

        settings.minutesOverrides["CIS 1200"] = 30
        #expect(settings.resolved(for: "CIS 1200").minutes == 30)
        #expect(settings.resolved(for: "CIS 1200").sound == .smooth)
        #expect(settings.hasOverride("CIS 1200"))
        #expect(settings.resolved(for: "MATH 1400").minutes == 10)

        // Only the field the class chose is its own; the other still follows.
        settings.soundOverrides["CIS 1200"] = .chime
        settings.defaultMinutes = 5
        settings.defaultSound = .pulse
        #expect(settings.resolved(for: "CIS 1200") == (30, .chime))
        #expect(settings.resolved(for: "MATH 1400") == (5, .pulse))
    }

    @Test("The subtitle appears only for a class with an override")
    func subtitle() {
        var settings = SweeperSettings()
        #expect(SweeperText.overrideSubtitle(settings, course: "A") == nil)
        settings.minutesOverrides["A"] = 30
        #expect(SweeperText.overrideSubtitle(settings, course: "A") == "30m")
        settings.soundOverrides["A"] = .chime
        #expect(SweeperText.overrideSubtitle(settings, course: "A") == "30m · gentle chime")
        settings.minutesOverrides["A"] = nil
        #expect(SweeperText.overrideSubtitle(settings, course: "A") == "gentle chime")
        settings.minutesOverrides["B"] = 60
        #expect(SweeperText.overrideSubtitle(settings, course: "B") == "1h")
    }

    @Test("Countdown reads h:mm:ss and the bar fills over the last four hours")
    func countdownAndProgress() {
        #expect(SweeperText.countdown(2 * 3600 + 14 * 60 + 7) == "2:14:07")
        #expect(SweeperText.countdown(59.9) == "0:00:59")
        #expect(SweeperText.countdown(-5) == "0:00:00")
        #expect(SweeperText.progress(remaining: 5 * 3600) == 0)
        #expect(SweeperText.progress(remaining: 2 * 3600) == 0.5)
        #expect(SweeperText.progress(remaining: 0) == 1)
        #expect(SweeperText.progress(remaining: -10) == 1)
    }

    // MARK: Persistence

    @Test("Overrides survive a relaunch, and an unoffered value does not get in")
    func persistenceRoundTrip() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            #expect(scheduler.sweeperMinutesOverrides.isEmpty)
            #expect(scheduler.sweeperSoundOverrides.isEmpty)
            scheduler.setSweeperCourseMinutes("CIS 1200", minutes: 30)
            scheduler.setSweeperCourseSound("CIS 1200", sound: .chime)
            scheduler.setSweeperCourseMinutes("MATH 1400", minutes: 7)   // not offered

            let restored = NotificationScheduler(defaults: defaults)
            #expect(restored.sweeperMinutesOverrides == ["CIS 1200": 30])
            #expect(restored.sweeperSoundOverrides == ["CIS 1200": .chime])
            #expect(restored.sweeperSettings.resolved(for: "CIS 1200") == (30, .chime))

            // nil goes back to the default and the key empties out.
            restored.setSweeperCourseMinutes("CIS 1200", minutes: nil)
            restored.setSweeperCourseSound("CIS 1200", sound: nil)
            let again = NotificationScheduler(defaults: defaults)
            #expect(again.sweeperMinutesOverrides.isEmpty)
            #expect(again.sweeperSoundOverrides.isEmpty)
            #expect(defaults.object(forKey: "notif.sweeperCourseMinutesV1") == nil)
            #expect(defaults.object(forKey: "notif.sweeperCourseSoundV1") == nil)
        }
    }

    @Test("A saved value that is no longer a choice is dropped on read")
    func staleSavedValuesDropped() {
        withScratchDefaults { defaults in
            defaults.set(["A": 30, "B": 7], forKey: "notif.sweeperCourseMinutesV1")
            defaults.set(["A": "chime", "B": "gone"], forKey: "notif.sweeperCourseSoundV1")
            let scheduler = NotificationScheduler(defaults: defaults)
            #expect(scheduler.sweeperMinutesOverrides == ["A": 30])
            #expect(scheduler.sweeperSoundOverrides == ["A": .chime])
        }
    }

    @Test("Reset clears one class's lead time and sound, not its switch or other classes")
    func reset() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            scheduler.setSweeperCourseMinutes("A", minutes: 30)
            scheduler.setSweeperCourseSound("A", sound: .pulse)
            scheduler.setSweeperCourseMinutes("B", minutes: 60)
            scheduler.setSweeperCourse("A", enabled: false)

            scheduler.resetSweeperCourseOverrides("A")
            #expect(!scheduler.sweeperSettings.hasOverride("A"))
            #expect(scheduler.sweeperSettings.hasOverride("B"))
            #expect(scheduler.sweeperExcludedCourses == ["A"])

            let restored = NotificationScheduler(defaults: defaults)
            #expect(restored.sweeperMinutesOverrides == ["B": 60])
            #expect(restored.sweeperSoundOverrides.isEmpty)
        }
    }

    // MARK: Where the planner applies them

    @Test("The alarm and the buzzes use the class's own lead time and sound")
    func plannerAppliesOverrides() throws {
        try withScheduler { scheduler, prefs, now in
            scheduler.setSweeperCourseMinutes("CIS 1200", minutes: 30)
            scheduler.setSweeperCourseSound("CIS 1200", sound: .chime)
            let due = now + 4 * 3600
            let items = [item("CIS 1200", "own", due: due), item("MATH 1400", "default", due: due)]

            let alarms = scheduler.plannedAlarms(from: items, now: now, preferences: prefs)
            let own = try #require(alarms.first { $0.assignmentID == "canvas:own" })
            let plain = try #require(alarms.first { $0.assignmentID == "canvas:default" })
            #expect(own.fireDate == due - 30 * 60)
            #expect(own.sound == .chime)
            #expect(plain.fireDate == due - 10 * 60)
            #expect(plain.sound == .smooth)

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
                .filter { $0.identifier.hasPrefix("loud:") }
            let ownBuzz = try #require(requests.first { $0.identifier.contains("canvas:own") })
            let plainBuzz = try #require(requests.first { $0.identifier.contains("canvas:default") })
            #expect(ownBuzz.content.body.contains("Due in 30 minutes"))
            #expect(plainBuzz.content.body.contains("Due in 10 minutes"))
            let trigger = try #require(ownBuzz.trigger as? UNTimeIntervalNotificationTrigger)
            #expect(trigger.timeInterval == 4 * 3600 - 30 * 60)
            #expect(ownBuzz.content.sound == UNNotificationSound(named: UNNotificationSoundName(rawValue: "sweeper-chime.wav")))
        }
    }

    // MARK: Next sweep

    @Test("The soonest ring wins, with each class's own lead")
    func nextSweepUsesPerClassLead() throws {
        try withScheduler { scheduler, prefs, now in
            // A is due later but rings first because its lead is an hour.
            scheduler.setSweeperCourseMinutes("A", minutes: 60)
            let items = [item("A", "a", due: now + 3 * 3600 + 600),
                         item("B", "b", due: now + 3 * 3600)]
            let ring = try #require(nextSweep(scheduler, prefs, items, now))
            #expect(ring.item.id == "canvas:a")
            #expect(ring.ringAt == now + 3 * 3600 + 600 - 3600)
            #expect(ring.minutes == 60)
        }
    }

    @Test("Excluded, past, finished, off and muted work never rings next")
    func nextSweepSkips() throws {
        try withScheduler { scheduler, prefs, now in
            prefs.setNotificationsEnabled("MUTED", false)
            scheduler.setSweeperCourse("OFF", enabled: false)
            let items = [
                item("OFF", "excluded", due: now + 2 * 3600),
                item("MUTED", "muted", due: now + 2 * 3600),
                item("A", "done", due: now + 2 * 3600, completed: true),
                item("A", "nodate", due: nil),
                item("A", "past", due: now - 3600),
                // Due in 5 minutes with a 10-minute lead: the ring time is past.
                item("A", "tooLate", due: now + 5 * 60),
                item("A", "keeps", due: now + 5 * 3600),
            ]
            let ring = try #require(nextSweep(scheduler, prefs, items, now))
            #expect(ring.item.id == "canvas:keeps")
            #expect(ring.ringAt > now)

            scheduler.setLoudAlertEnabled(false)
            #expect(nextSweep(scheduler, prefs, items, now) == nil)
        }
    }

    @Test("Nothing upcoming reads as nil")
    func nextSweepEmpty() {
        withScheduler { scheduler, prefs, now in
            #expect(nextSweep(scheduler, prefs, [], now) == nil)
        }
    }

    /// The card must never promise an alarm the planner would not set: over a
    /// mixed set, the card's ring is the planner's earliest alarm.
    @Test("The next sweep is the planner's earliest alarm")
    func nextSweepAgreesWithPlanner() throws {
        try withScheduler { scheduler, prefs, now in
            scheduler.setSweeperCourseMinutes("A", minutes: 30)
            scheduler.setSweeperCourse("C", enabled: false)
            let items = [
                item("A", "a1", due: now + 2 * 3600),
                item("B", "b1", due: now + 90 * 60),
                item("C", "c1", due: now + 40 * 60),
                item("B", "b2", due: now + 6 * 3600, kind: .event),
                item("A", "a2", due: now + 20 * 60, completed: true),
            ]
            let ring = try #require(nextSweep(scheduler, prefs, items, now))
            let earliest = try #require(scheduler.plannedAlarms(from: items, now: now, preferences: prefs)
                .min { $0.fireDate < $1.fireDate })
            #expect(ring.ringAt == earliest.fireDate)
            #expect("canvas:\(ring.item.assignment.sourceID)" == earliest.assignmentID)
        }
    }

    // MARK: Helpers

    private func nextSweep(_ scheduler: NotificationScheduler, _ prefs: CoursePreferencesStore,
                           _ items: [DashItem], _ now: Date) -> SweepRing? {
        SweeperSettings.nextSweep(in: items, now: now, settings: scheduler.sweeperSettings,
                                  courseRemindersOn: { prefs.notificationsEnabled($0) })
    }

    private func item(_ course: String, _ id: String, due: Date?,
                      kind: Assignment.Kind = .assignment, completed: Bool = false) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: kind,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: completed, completedAt: nil)
    }

    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a scratch defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func withScheduler(
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) throws -> Void
    ) rethrows {
        try withScratchDefaults { defaults in
            try body(NotificationScheduler(defaults: defaults),
                     CoursePreferencesStore(defaults: defaults),
                     Date())
        }
    }
}
