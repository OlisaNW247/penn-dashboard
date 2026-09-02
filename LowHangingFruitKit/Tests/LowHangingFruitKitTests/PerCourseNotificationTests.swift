import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The per-course notification layer: a class can be muted, can carry its own
/// lead times or inherit the global ones, and can have its recurring
/// non-assignment work (readings, check-ins) silenced without losing assignment
/// reminders.
///
/// Everything here drives `NotificationScheduler.plannedRequests`, which is pure
/// — it returns the requests instead of adding them — so none of this needs a
/// notification permission prompt or a `UNUserNotificationCenter`. Keeping it
/// that way is the reason the interesting logic (the budget allocation, in
/// particular) is testable at all.
///
/// **Every test runs on its own `UserDefaults` suite.** Both halves of the state
/// under test — the scheduler's global settings and the `coursePreferences` blob
/// — live in `UserDefaults.lhf`, which resolves to the process-wide standard
/// domain whenever the App Group is unavailable, i.e. in every `swift test` run.
/// A test that wrote there would be configuring reminders for whichever suite
/// happened to run next, and the failure would surface there rather than here.
@MainActor
@Suite("Per-course notifications")
struct PerCourseNotificationTests {

    // MARK: Muting

    /// The mute has to be total. Not quieter, not fewer lead times — nothing,
    /// including the daily digest, which is the door a mute most easily leaks
    /// back in through.
    @Test("A muted course produces no requests, and no digest line either")
    func mutedCourseIsSilent() {
        withFixture(global: [.h24, .h1], digest: true) { scheduler, prefs, now in
            let items = [
                assignment("CIS 1200", "a", due: now + 2 * .day),
                assignment("MATH 1400", "b", due: now + 2 * .day),
                // Due inside 24h so it would otherwise be counted by the digest.
                assignment("CIS 1200", "c", due: now + 20 * .hour),
            ]

            prefs.setNotificationsEnabled("CIS 1200", false)
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            #expect(courses(of: requests, in: items) == ["MATH 1400"])
            // MATH 1400 keeps both of its lead times; CIS 1200 contributes zero.
            #expect(dueRequests(requests).count == 2)

            // And the digest counts nothing from the muted class: the only item
            // inside the next 24 hours belongs to it.
            #expect(digestBody(scheduler, items, now, prefs)?.contains("nothing due") == true)
        }
    }

    /// Muting one class must not disturb the others' settings — the store prunes
    /// records back to nothing when they return to default, and a mute that
    /// accidentally wrote a record for every course would defeat that.
    @Test("Muting one class leaves every other class exactly as it was")
    func muteIsScopedToOneCourse() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            prefs.setNotificationsEnabled("CIS 1200", false)
            #expect(prefs.configuredCourseKeys == ["CIS 1200"])
            #expect(prefs.notificationsEnabled("MATH 1400"))
            #expect(prefs.leadOffsets(for: "MATH 1400") == nil)

            let items = [assignment("MATH 1400", "b", due: now + 2 * .day)]
            #expect(dueRequests(scheduler.plannedRequests(from: items, now: now, preferences: prefs)).count == 2)
        }
    }

    // MARK: Inherit vs override

    /// The global control in Settings stays load-bearing: a course nobody has
    /// configured follows it, and keeps following it when it changes. This is
    /// the property that makes `leadOffsets` optional rather than a plain `Set`
    /// — see `CoursePreferences.leadOffsets`.
    @Test("A course with nil offsets uses the global set, and tracks it when it changes")
    func nilOffsetsInheritTheGlobal() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            let items = [assignment("CIS 1200", "a", due: now + 10 * .day)]

            #expect(prefs.leadOffsets(for: "CIS 1200") == nil)
            #expect(offsets(of: scheduler.plannedRequests(from: items, now: now, preferences: prefs))
                    == [.h1, .h24])

            // The student widens the global setting. An inheriting class follows
            // it — nothing about the class was touched.
            scheduler.setOffset(.d7, on: true)
            #expect(offsets(of: scheduler.plannedRequests(from: items, now: now, preferences: prefs))
                    == [.h1, .h24, .d7])
            #expect(prefs.leadOffsets(for: "CIS 1200") == nil)
        }
    }

    @Test("An explicit per-course set overrides the global one for that course only")
    func explicitOffsetsOverrideTheGlobal() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            let items = [
                assignment("CIS 1200", "a", due: now + 10 * .day),
                assignment("MATH 1400", "b", due: now + 10 * .day),
            ]
            prefs.setLeadOffsets("CIS 1200", [.d7])

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(offsets(of: requests, forCourse: "CIS 1200", in: items) == [.d7])
            #expect(offsets(of: requests, forCourse: "MATH 1400", in: items) == [.h1, .h24])
        }
    }

    /// The distinction the whole optional exists for. `[]` is a student saying
    /// "no lead-time reminders for this class"; it must not read as "I haven't
    /// set this up" and fall back to the global set.
    @Test("An explicitly empty set produces nothing for that course and nothing for anyone else")
    func explicitlyEmptyIsARealAnswer() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            let items = [
                assignment("CIS 1200", "a", due: now + 10 * .day),
                assignment("MATH 1400", "b", due: now + 10 * .day),
            ]
            prefs.setLeadOffsets("CIS 1200", [])

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(courses(of: requests, in: items) == ["MATH 1400"])
            #expect(dueRequests(requests).count == 2)

            // And it is distinct from nil at the storage level, not merely in
            // this one code path.
            #expect(prefs.leadOffsets(for: "CIS 1200") == [])
            prefs.setLeadOffsets("CIS 1200", nil)
            #expect(dueRequests(scheduler.plannedRequests(from: items, now: now, preferences: prefs)).count == 4)
        }
    }

    // MARK: The 60-request budget

    /// The regression this whole allocation exists to prevent.
    ///
    /// One heavily-configured class (five lead times, twelve assignments) is on
    /// its own enough to fill the budget. Under the old flat "sort every
    /// candidate by fire date and take the first sixty" it would have taken a
    /// large share of the slots and the four classes the student never touched
    /// would have gone quiet — silently, with nothing to notice until something
    /// was missed. Round-robin gives each course a turn, so the four untouched
    /// classes get *every* reminder they asked for and the greedy one takes only
    /// what is left.
    @Test("A five-lead-time course cannot crowd out the courses nobody configured")
    func budgetIsFairUnderContention() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            var items: [DashItem] = []

            // The configured class: all five lead times, twelve assignments, all
            // due beyond a week out so every one of the five actually fires.
            // 12 × 5 = 60 candidates — the entire budget by itself.
            prefs.setLeadOffsets("CIS 1200", Set(LeadOffset.allCases))
            for i in 0..<12 {
                items.append(assignment("CIS 1200", "cis\(i)", due: now + 8 * .day + Double(i) * .hour))
            }

            // Four untouched classes on the global two lead times, four
            // assignments each: 8 candidates apiece, 32 in total.
            let quiet = ["MATH 1400", "PHYS 0150", "ECON 0100", "ENGL 0050"]
            for course in quiet {
                for i in 0..<4 {
                    items.append(assignment(course, "\(course)-\(i)", due: now + 2 * .day + Double(i) * .hour))
                }
            }

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let counts = requestCountsByCourse(requests, in: items)

            // 92 candidates chasing 60 slots. Every quiet class drains
            // completely — 8 each is well under its 60/5 = 12 guaranteed share.
            for course in quiet {
                #expect(counts[course] == 8, "\(course) should keep every reminder it asked for")
            }
            // …and the configured class takes the remaining 28 rather than all 60.
            #expect(counts["CIS 1200"] == 28)
            #expect(dueRequests(requests).count == NotificationScheduler.maxPending)
        }
    }

    /// The other half of the fairness rule: a guarantee is not a quota. A course
    /// that runs out of candidates hands its unused share back rather than
    /// leaving slots empty while another course goes unscheduled.
    @Test("A course that runs out releases its share instead of wasting it")
    func drainedCoursesReleaseTheirShare() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            var items: [DashItem] = []
            prefs.setLeadOffsets("CIS 1200", Set(LeadOffset.allCases))
            for i in 0..<40 {
                items.append(assignment("CIS 1200", "cis\(i)", due: now + 8 * .day + Double(i) * .minute))
            }
            // One quiet class with a single assignment: 2 candidates.
            items.append(assignment("MATH 1400", "m0", due: now + 2 * .day))

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let counts = requestCountsByCourse(requests, in: items)

            #expect(counts["MATH 1400"] == 2, "the quiet class keeps both of its reminders")
            #expect(counts["CIS 1200"] == NotificationScheduler.maxPending - 2)
            #expect(dueRequests(requests).count == NotificationScheduler.maxPending)
        }
    }

    /// The digest costs one slot, and it comes out of the same sixty rather than
    /// being added on top — iOS's real ceiling is 64 and the headroom is there on
    /// purpose.
    @Test("The daily digest is paid for out of the budget, not added to it")
    func digestComesOutOfTheBudget() {
        withFixture(global: [.h24, .h1], digest: true) { scheduler, prefs, now in
            let items = (0..<50).map {
                assignment("CIS 1200", "a\($0)", due: now + 3 * .day + Double($0) * .minute)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            #expect(requests.count == NotificationScheduler.maxPending)
            #expect(dueRequests(requests).count == NotificationScheduler.maxPending - 1)
            #expect(requests.contains { $0.identifier == "digest:daily" })
        }
    }

    /// Within a course the cut falls on the far-out tail, because the planner
    /// re-runs on every sync — a reminder scheduled for day thirteen is nearly
    /// certain to be re-planned before it ever fires, whereas one scheduled for
    /// tomorrow is the one the student is actually relying on.
    @Test("Within a course, the soonest-firing reminders are the ones that survive")
    func soonestFiringWinsWithinACourse() {
        withFixture(global: [.h1]) { scheduler, prefs, now in
            // 70 assignments, one lead time, one course → 70 candidates for 60
            // slots, in a known order.
            let items = (0..<70).map {
                assignment("CIS 1200", "a\($0)", due: now + 2 * .day + Double($0) * .minute)
            }
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            #expect(requests.count == NotificationScheduler.maxPending)
            let kept = Set(requests.map(\.identifier))
            let expected = Set((0..<NotificationScheduler.maxPending)
                .map { "due:canvas:a\($0):\(LeadOffset.h1.rawValue)" })
            #expect(kept == expected)
        }
    }

    /// `Set<LeadOffset>` and `Dictionary` both iterate in an order that is not
    /// stable across runs. A plan that depended on either would cut the budget
    /// differently on identical data — untestable, and impossible to explain to
    /// a student whose reminders changed when nothing did.
    @Test("The same items and settings always produce the same plan")
    func planIsDeterministic() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            prefs.setLeadOffsets("CIS 1200", Set(LeadOffset.allCases))
            var items: [DashItem] = []
            for course in ["CIS 1200", "MATH 1400", "PHYS 0150"] {
                for i in 0..<15 {
                    items.append(assignment(course, "\(course)-\(i)",
                                            due: now + 8 * .day + Double(i) * .minute))
                }
            }
            let first = scheduler.plannedRequests(from: items, now: now, preferences: prefs).map(\.identifier)
            let second = scheduler.plannedRequests(from: items, now: now, preferences: prefs).map(\.identifier)
            #expect(first == second)
            #expect(Set(first).count == first.count, "identifiers stay unique per assignment and lead time")
        }
    }

    // MARK: Nothing-to-submit work (2026-08-27 merged toggle)
    //
    // `recurringEnabled` and `noSubmissionRemindersEnabled` merged into one
    // `nothingToSubmitEnabled` field (docs/decisions.md, same date) after a
    // device pass found two half-working switches for one idea. At the
    // scheduler level only one gate survives — `RecurringTask` occurrences —
    // because a no-submission Canvas assignment or an `.event` item is now
    // HIDDEN from `vm.items` entirely by `AppState.rebuildDashboardItems`
    // when the toggle is off, so it never reaches `plannedRequests` to be
    // gated here at all. These two tests used to be titled around
    // "readings"; renamed to match what they actually prove now.

    /// The request the toggle exists for, stated as a test: occurrences a
    /// student didn't ask to be reminded about go quiet; the assignment they
    /// still care about doesn't. Getting this right — the assignment
    /// untouched, the occurrence gone — is the whole feature at the
    /// scheduler layer (the hiding half is `AppState`'s, covered in
    /// `NoSubmissionCaveatTests`).
    @Test("Turning the nothing-to-submit toggle off silences occurrences and leaves assignments alone")
    func nothingToSubmitToggleRespectsItsOwnOccurrenceGate() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            let taskID = UUID()
            let reading = now + 3 * .day
            let items = [
                assignment("CIS 1200", "hw1", due: now + 3 * .day),
                occurrence("CIS 1200", taskID: taskID, due: reading),
                occurrence("MATH 1400", taskID: UUID(), due: reading),
            ]

            // Both on by default: assignment + both readings, two lead times each.
            #expect(dueRequests(scheduler.plannedRequests(from: items, now: now, preferences: prefs)).count == 6)

            prefs.setNothingToSubmitEnabled("CIS 1200", false)
            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)

            // CIS 1200's assignment survives; its reading does not; MATH 1400 is
            // untouched.
            #expect(dueRequests(requests).count == 4)
            #expect(requests.contains { $0.identifier.hasPrefix("due:canvas:hw1:") })
            #expect(!requests.contains { $0.identifier.contains(taskID.uuidString) })
        }
    }

    /// The toggle is not the mute in disguise. Silencing occurrences while
    /// the class stays on has to leave the class on.
    @Test("Silencing the nothing-to-submit toggle does not mute the class")
    func nothingToSubmitToggleIsNotAMute() {
        withFixture(global: [.h24, .h1]) { scheduler, prefs, now in
            prefs.setNothingToSubmitEnabled("CIS 1200", false)
            #expect(prefs.notificationsEnabled("CIS 1200"))

            let items = [assignment("CIS 1200", "hw1", due: now + 3 * .day)]
            #expect(dueRequests(scheduler.plannedRequests(from: items, now: now, preferences: prefs)).count == 2)
        }
    }

    @Test("The digest counts the same items the reminders do")
    func digestHonoursTheSameGates() {
        withFixture(global: [.h24, .h1], digest: true) { scheduler, prefs, now in
            let soon = now + 20 * .hour
            let items = [
                assignment("CIS 1200", "hw1", due: soon),
                assignment("MATH 1400", "hw2", due: soon),
                occurrence("MATH 1400", taskID: UUID(), due: soon),
            ]

            #expect(digestBody(scheduler, items, now, prefs)?.contains("3 assignments") == true)

            prefs.setNotificationsEnabled("CIS 1200", false)
            #expect(digestBody(scheduler, items, now, prefs)?.contains("2 assignments") == true)

            prefs.setNothingToSubmitEnabled("MATH 1400", false)
            #expect(digestBody(scheduler, items, now, prefs)?.contains("1 assignment ") == true)
        }
    }

    // MARK: Recognising an occurrence

    /// The recurring switch can only work if a generated occurrence is
    /// recognisable from the `Assignment` alone. It is recognised structurally
    /// rather than by a prefix because the `sourceID` is half of
    /// `Assignment.id`, which is the key completion is filed under — changing
    /// the format would resurrect readings the student had already ticked off.
    /// So: the real generator's output has to be recognised, and nothing else
    /// may be.
    @Test("A real recurring task's occurrences are recognised; other manual work is not")
    func occurrenceRecognition() {
        let task = RecurringTask(
            title: "Weekly reading", course: "CIS 1200",
            weekday: 2, hour: 21, minute: 0,
            startDate: Date(), endDate: nil, origin: .canvasSyllabus
        )
        let generated = task.upcomingAssignments(from: Date(), weeksAhead: 3)
        #expect(!generated.isEmpty)
        for occurrence in generated {
            #expect(RecurringTask.isOccurrence(occurrence))
            #expect(RecurringTask.occurrenceTaskID(fromSourceID: occurrence.sourceID) == task.id)
        }

        // A manually-created recurring task lands on `.manual`, the same source
        // one-off manual assignments use — which is exactly why the structural
        // check has to be exact in both directions.
        let manualTask = RecurringTask(
            title: "Check-in", course: "CIS 1200",
            weekday: 5, hour: 9, minute: 0,
            startDate: Date(), endDate: nil, origin: .manual
        )
        for occurrence in manualTask.upcomingAssignments(from: Date(), weeksAhead: 2) {
            #expect(occurrence.source == .manual)
            #expect(RecurringTask.isOccurrence(occurrence))
        }

        // A one-off manual assignment is not a recurring occurrence, and neither
        // is anything from a feed. Answering `true` for either would let the
        // readings switch silence real work.
        let oneOff = ManualAssignment(title: "Essay", course: "ENGL 0050", dueAt: Date()).asAssignment()
        #expect(!RecurringTask.isOccurrence(oneOff))
        #expect(!RecurringTask.isOccurrence(
            Assignment(source: .canvas, sourceID: "abc", kind: .assignment,
                       course: "CIS 1200", title: "HW", dueAt: Date(), url: nil)))
        // A bare UUID with no epoch suffix — the shape a pre-prefix manual item
        // could have had — must not match either.
        #expect(RecurringTask.occurrenceTaskID(fromSourceID: UUID().uuidString) == nil)
        #expect(RecurringTask.occurrenceTaskID(fromSourceID: "\(UUID().uuidString)-notanumber") == nil)
    }

    @Test("Minting and parsing an occurrence id are inverses")
    func occurrenceIDRoundTrips() {
        let taskID = UUID()
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let sourceID = RecurringTask.occurrenceSourceID(taskID: taskID, due: due)
        #expect(sourceID == "\(taskID.uuidString)-1800000000")
        #expect(RecurringTask.occurrenceTaskID(fromSourceID: sourceID) == taskID)
    }

    // MARK: - Fixture

    /// A scheduler and a preferences store over one throwaway defaults suite,
    /// torn down afterwards. `now` is fixed so lead times and the fourteen-day
    /// horizon are arithmetic rather than a race with the clock.
    private func withFixture(
        global: Set<LeadOffset>,
        digest: Bool = false,
        _ body: (NotificationScheduler, CoursePreferencesStore, Date) -> Void
    ) {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a scratch defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let scheduler = NotificationScheduler(defaults: defaults)
        for offset in LeadOffset.allCases {
            scheduler.setOffset(offset, on: global.contains(offset))
        }
        scheduler.setDigestEnabled(digest)

        body(scheduler, CoursePreferencesStore(defaults: defaults), Date())
    }

    // MARK: Item builders

    private func assignment(_ course: String, _ id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    /// One occurrence of a recurring task, built through the same minting
    /// function the generator uses so the test cannot drift from the format.
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

    // MARK: Reading a plan back

    private func dueRequests(_ requests: [UNNotificationRequest]) -> [UNNotificationRequest] {
        requests.filter { $0.identifier.hasPrefix("due:") }
    }

    /// Maps each request back to the item that produced it, by identifier.
    private func course(of request: UNNotificationRequest, in items: [DashItem]) -> String? {
        items.first { request.identifier.hasPrefix("due:\($0.assignment.id):") }?.assignment.course
    }

    private func courses(of requests: [UNNotificationRequest], in items: [DashItem]) -> [String] {
        Set(dueRequests(requests).compactMap { course(of: $0, in: items) }).sorted()
    }

    private func requestCountsByCourse(_ requests: [UNNotificationRequest],
                                       in items: [DashItem]) -> [String: Int] {
        dueRequests(requests).reduce(into: [:]) { counts, request in
            guard let course = course(of: request, in: items) else { return }
            counts[course, default: 0] += 1
        }
    }

    /// The lead times a plan used, sorted shortest-first for a stable
    /// comparison.
    private func offsets(of requests: [UNNotificationRequest]) -> [LeadOffset] {
        Set(dueRequests(requests).compactMap { request -> LeadOffset? in
            guard let raw = Int(request.identifier.split(separator: ":").last ?? "") else { return nil }
            return LeadOffset(rawValue: raw)
        }).sorted { $0.rawValue < $1.rawValue }
    }

    private func offsets(of requests: [UNNotificationRequest],
                         forCourse course: String,
                         in items: [DashItem]) -> [LeadOffset] {
        offsets(of: dueRequests(requests).filter { self.course(of: $0, in: items) == course })
    }

    private func digestBody(_ scheduler: NotificationScheduler,
                            _ items: [DashItem],
                            _ now: Date,
                            _ prefs: CoursePreferencesStore) -> String? {
        scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            .first { $0.identifier == "digest:daily" }?
            .content.body
    }
}

// MARK: - Readable time arithmetic

/// `now + 8 * .day` rather than `now.addingTimeInterval(8 * 86_400)`. The lead
/// times under test are hours and days apart and the assertions depend on which
/// side of a boundary a due date falls on, so the arithmetic being legible is
/// the difference between a test that documents the rule and one that merely
/// passes.
private extension TimeInterval {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400
}
