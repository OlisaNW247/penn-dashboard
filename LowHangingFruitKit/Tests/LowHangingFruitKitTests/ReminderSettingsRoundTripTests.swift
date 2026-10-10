import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The global reminder settings and what a reminder says, after the review of
/// 2026-10-10:
///
/// - A saved EMPTY lead-time list is the student's answer ("no lead-time
///   reminders") and must survive a relaunch. It used to read back as the
///   defaults, so switching every lead time off was undone silently.
/// - The notification title is the class as the card shows it (rename applied,
///   "Misc" when blank), and the thread is the raw code so a rename never
///   splits a class's reminders into two lock-screen stacks.
///
/// Everything drives `plannedRequests`, which returns requests without adding
/// them, so no notification is scheduled and no permission prompt can fire.
/// Every test runs on its own `UserDefaults` suite: `UserDefaults.lhf` is the
/// shared standard domain in a `swift test` run (see
/// `PerCourseNotificationTests`).
@MainActor
@Suite("Reminder settings and wording")
struct ReminderSettingsRoundTripTests {

    // MARK: A saved empty selection

    @Test("switching every lead time off survives a relaunch and schedules nothing")
    func savedEmptySelectionSurvivesRelaunch() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            for offset in LeadOffset.allCases { scheduler.setOffset(offset, on: false) }
            #expect(scheduler.leadOffsets.isEmpty)

            // On disk it is a present, empty array, not a missing key.
            #expect((defaults.array(forKey: "notif.leadOffsets") as? [Int]) == [])

            let relaunched = NotificationScheduler(defaults: defaults)
            #expect(relaunched.leadOffsets.isEmpty, "the defaults must not come back")
            #expect(!relaunched.hasActiveLeadTimes)

            let now = Date()
            let items = [assignment("CIS 1200", "hw", due: now + 5 * 86_400)]
            let requests = relaunched.plannedRequests(
                from: items, now: now, preferences: CoursePreferencesStore(defaults: defaults))
            #expect(requests.isEmpty, "no lead times means no reminders")
        }
    }

    @Test("an empty array written straight to disk is honoured")
    func presentEmptyKeyIsHonoured() {
        withScratchDefaults { defaults in
            defaults.set([Int](), forKey: "notif.leadOffsets")
            #expect(NotificationScheduler(defaults: defaults).leadOffsets.isEmpty)
        }
    }

    @Test("a student who never chose still gets the defaults")
    func neverSetGetsTheDefaults() {
        withScratchDefaults { defaults in
            #expect(defaults.object(forKey: "notif.leadOffsets") == nil)
            let scheduler = NotificationScheduler(defaults: defaults)
            #expect(scheduler.leadOffsets == LeadOffset.defaults)
            #expect(scheduler.hasActiveLeadTimes)

            let now = Date()
            let items = [assignment("CIS 1200", "hw", due: now + 5 * 86_400)]
            let requests = scheduler.plannedRequests(
                from: items, now: now, preferences: CoursePreferencesStore(defaults: defaults))
            #expect(Set(requests.map(\.identifier)) == ["due:canvas:hw:86400", "due:canvas:hw:3600"])
        }
    }

    @Test("turning a switch back on after an empty save is remembered too")
    func emptyThenOneOn() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            for offset in LeadOffset.allCases { scheduler.setOffset(offset, on: false) }
            scheduler.setOffset(.h3, on: true)
            #expect(NotificationScheduler(defaults: defaults).leadOffsets == [.h3])
        }
    }

    @Test("only offered lead times count as active, so a lone retired one reads as none")
    func activeMeansOffered() {
        withScratchDefaults { defaults in
            defaults.set([LeadOffset.d7.rawValue], forKey: "notif.leadOffsets")
            let scheduler = NotificationScheduler(defaults: defaults)
            #expect(scheduler.leadOffsets == [.d7])
            #expect(!scheduler.hasActiveLeadTimes)

            scheduler.setOffset(.h1, on: true)
            #expect(scheduler.hasActiveLeadTimes)
        }
    }

    // MARK: Re-planning after a preference change

    @Test("a preference change plans from the dashboard's live items when it has registered")
    func preferenceRescheduleUsesLiveItems() {
        withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            #expect(scheduler.itemsForPreferenceReschedule().isEmpty,
                    "nothing recorded and no dashboard registered yet")

            let items = [assignment("CIS 1200", "hw", due: Date().addingTimeInterval(86_400))]
            scheduler.liveItems = { items }
            #expect(scheduler.itemsForPreferenceReschedule().map(\.assignment.id) == ["canvas:hw"])

            // Read each time, so it follows the dashboard rather than a copy.
            scheduler.liveItems = { [] }
            #expect(scheduler.itemsForPreferenceReschedule().isEmpty)
        }
    }

    // MARK: Title and thread

    @Test("the title is the student's rename, and the thread stays on the raw code")
    func renamedClassTitlesTheReminder() {
        withScheduler { scheduler, prefs, now in
            prefs.setDisplayName("CIS 1210", to: "Algorithms")
            let items = [assignment("CIS 1210", "ps4", due: now + 2 * 86_400)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            #expect(!requests.isEmpty)
            for request in requests {
                #expect(request.content.title == "Algorithms")
                #expect(request.content.threadIdentifier == "CIS 1210")
            }
        }
    }

    @Test("the app's own path, a fresh read of the same defaults, sees a rename made elsewhere")
    func renameIsReadFreshWithoutAnExplicitStore() throws {
        try withScratchDefaults { defaults in
            let scheduler = NotificationScheduler(defaults: defaults)
            let now = Date()
            let items = [assignment("CIS 1210", "ps4", due: now + 2 * 86_400)]

            let before = try #require(scheduler.plannedRequests(from: items, now: now).first)
            #expect(before.content.title == "CIS 1210", "no rename yet")

            CoursePreferencesStore(defaults: defaults).setDisplayName("CIS 1210", to: "Algorithms")
            let renamed = scheduler.plannedRequests(from: items, now: now)
            #expect(renamed.allSatisfy { $0.content.title == "Algorithms" })
        }
    }

    @Test("a class that was never renamed still titles the reminder with its code")
    func unrenamedClassKeepsItsCode() {
        withScheduler { scheduler, prefs, now in
            prefs.setDisplayName("MATH 1400", to: "Calculus")
            let items = [assignment("CIS 1200", "hw", due: now + 2 * 86_400)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(!requests.isEmpty)
            #expect(requests.allSatisfy { $0.content.title == "CIS 1200" })
            #expect(requests.allSatisfy { $0.content.threadIdentifier == "CIS 1200" })
        }
    }

    @Test("work with no class is titled Misc, as its card is, and is not given an empty title")
    func blankClassIsMisc() {
        withScheduler { scheduler, prefs, now in
            let items = [assignment("", "chore", due: now + 2 * 86_400),
                         assignment("   ", "errand", due: now + 3 * 86_400)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            #expect(!requests.isEmpty)
            for request in requests {
                #expect(request.content.title == "Misc")
                #expect(!request.content.title.isEmpty)
            }
        }
    }

    @Test("the thread of a classless reminder is the raw, blank code, not the Misc label")
    func blankClassThread() throws {
        try withScheduler { scheduler, prefs, now in
            let items = [assignment("", "chore", due: now + 2 * 86_400)]
            let request = try #require(
                scheduler.plannedRequests(from: items, now: now, preferences: prefs).first)
            #expect(request.content.threadIdentifier == "")
        }
    }

    @Test("one class's reminders share a thread, and two classes do not")
    func threadsGroupByClass() {
        withScheduler { scheduler, prefs, now in
            let items = [assignment("CIS 1200", "a", due: now + 2 * 86_400),
                         assignment("CIS 1200", "b", due: now + 3 * 86_400),
                         assignment("MATH 1400", "c", due: now + 2 * 86_400)]
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let threads = Dictionary(grouping: requests, by: \.content.threadIdentifier)
            #expect(Set(threads.keys) == ["CIS 1200", "MATH 1400"])
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

    /// A scheduler with the default lead times, a preferences store over the
    /// same scratch suite, and a `now` read once.
    private func withScheduler(
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) throws -> Void
    ) rethrows {
        try withScratchDefaults { defaults in
            try body(NotificationScheduler(defaults: defaults),
                     CoursePreferencesStore(defaults: defaults),
                     Date())
        }
    }

    private func assignment(_ course: String, _ id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }
}
