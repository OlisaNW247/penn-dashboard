import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for the two features built on top of `GradeItem
/// .requiresNoSubmission` added 2026-08-27 (see `docs/decisions.md`):
///
/// 1. The **caveat**: a persisted cache of no-submission Canvas assignment
///    ids (`AppState.noSubmissionCanvasAssignmentIDs`) that survives a
///    relaunch, so the dashboard card's "nothing to submit" tag is correct
///    on the very first frame — before any grade refresh has run — and not
///    just while `GradeWatcherStore.snapshots` happens to be populated.
/// 2. The **per-class toggle**: `CoursePreferences
///    .noSubmissionRemindersEnabled` (default on, so existing behavior is
///    unchanged until a student opts out), which silences lead-time
///    reminders and the daily digest for no-submission items in one class
///    without touching the caveat itself or any other class.
///
/// Also covers `DashItem.showsNothingToSubmit` — the display predicate added
/// after the owner's device pass found the caveat and the pre-existing
/// readings book icon (`AssignmentCardView`, the Mac menu-bar `LHFScenes
/// .row(for:)`) stating the same fact two different ways. The icon is gone;
/// the caveat now covers `.event` items (readings/events) too, while
/// `requiresNoSubmission` itself keeps its narrower Canvas-only meaning
/// because the reminder toggle above gates on that field specifically, not
/// the display predicate.
///
/// Also covers `AppState.isAutoFiledNoSubmission` / `isCompleted` — added
/// 2026-08-27 so a past-due no-submission Canvas assignment auto-files to
/// Done from the persisted cache immediately, offline, rather than sitting
/// in OVERDUE until the next live grade refresh runs
/// `autoSubmittedNoSubmissionIDs` and writes the durable ledger state.
///
/// The cache-update rule and the scheduler gate are both pure functions
/// (`AppState.updatedNoSubmissionIDs`, `NotificationScheduler
/// .plannedRequests`/`digestRequest`), so most of this needs no network, no
/// `GradeWatcherStore`, and no notification permission — the same shape
/// `NoSubmissionAutoCompleteTests` and `PerCourseNotificationTests` already
/// use for their siblings.
///
/// `.serialized`, and every test that touches `UserDefaults.lhf` backs up
/// and restores exactly the key it wrote — `noSubmissionCanvasAssignmentIDsV1`
/// — the same discipline `UnknownCourseAttributionTests` documents: that
/// suite resolves to the process-wide standard domain in every `swift test`
/// run (no App Group in this environment), so an unguarded write configures
/// whichever suite happens to run next, not just this one. Tests that only
/// need `NotificationScheduler`/`CoursePreferencesStore` use their own
/// throwaway `UserDefaults(suiteName:)` instead, following
/// `PerCourseNotificationTests.withFixture`, and never touch `.lhf` at all.
@MainActor
@Suite("No-submission caveat: cache, gate, toggle", .serialized)
struct NoSubmissionCaveatTests {

    // MARK: - Shared fixtures

    private func gradeItem(_ id: String, submissionTypes: [String]?, dueAt: Date? = nil) -> GradeItem {
        GradeItem(id: id, name: "Item \(id)", pointsPossible: 10, dueAt: dueAt, submissionTypes: submissionTypes)
    }

    private func snapshot(courseID: String, items: [GradeItem]) -> CourseGradeSnapshot {
        CourseGradeSnapshot(
            courseID: courseID,
            courseUsesWeights: false,
            categories: [GradeCategory(id: "cat-1", name: "Everything", items: items)],
            canvasComputedCurrentScore: nil,
            submissions: [],
            fetchedAt: Date()
        )
    }

    // MARK: - 1. Cache update rule (pure)

    @Test("An id observed as no-submission enters the cache")
    func observedNoSubmissionEntersCache() {
        let snap = snapshot(courseID: "1", items: [gradeItem("a", submissionTypes: ["none"])])
        let next = AppState.updatedNoSubmissionIDs(cached: [], snapshots: [snap])
        #expect(next == ["a"])
    }

    @Test("The same id later observed as submittable leaves the cache")
    func laterSubmittableLeavesCache() {
        // "a" was cached from an earlier refresh (the professor has since
        // switched it to an online upload); this refresh observes the new
        // truth and the cache has to follow it in the other direction too.
        let snap = snapshot(courseID: "1", items: [gradeItem("a", submissionTypes: ["online_upload"])])
        let next = AppState.updatedNoSubmissionIDs(cached: ["a"], snapshots: [snap])
        #expect(next.isEmpty)
    }

    @Test("An id from a course this refresh never touched survives untouched")
    func idFromUnrefreshedCourseSurvives() {
        // "b" belongs to a course with no snapshot in this refresh at all
        // (deselected, or a fetch that failed mid-loop) — it must neither be
        // dropped nor re-checked, only left exactly as it was.
        let snap = snapshot(courseID: "1", items: [gradeItem("a", submissionTypes: ["none"])])
        let next = AppState.updatedNoSubmissionIDs(cached: ["b"], snapshots: [snap])
        #expect(next == ["a", "b"])
    }

    @Test("A mixed refresh updates every observed id independently")
    func mixedRefreshUpdatesEachIndependently() {
        let items = [
            gradeItem("keep-in", submissionTypes: ["none"]),
            gradeItem("newly-out", submissionTypes: ["online_upload"]),
            gradeItem("newly-in", submissionTypes: ["on_paper"]),
        ]
        let snap = snapshot(courseID: "1", items: items)
        // "keep-in" and "newly-out" were already cached (from a previous
        // refresh); "untouched" belongs to a course not in this refresh.
        let next = AppState.updatedNoSubmissionIDs(
            cached: ["keep-in", "newly-out", "untouched"],
            snapshots: [snap]
        )
        #expect(next == ["keep-in", "newly-in", "untouched"])
    }

    // MARK: - 2. DashItem.showsNothingToSubmit (the display predicate)
    //
    // Added after the owner's device pass found the caveat and the
    // pre-existing readings book icon saying the same thing two different
    // ways. `showsNothingToSubmit` is the single display predicate the card
    // now reads; `requiresNoSubmission` (tested above and in
    // `NoSubmissionAutoCompleteTests`) keeps its narrower, Canvas-only
    // meaning because it's what the per-class reminder toggle gates on.
    // Pure — no `AppState`, no defaults.

    private func eventItem(requiresNoSubmission: Bool = false) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: "reading-1", kind: .event,
                                   course: "TEST 1000", title: "Weekly reading", dueAt: nil, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil,
            requiresNoSubmission: requiresNoSubmission
        )
    }

    private func assignmentItem(requiresNoSubmission: Bool) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: "hw-1", kind: .assignment,
                                   course: "TEST 1000", title: "PSet", dueAt: nil, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil,
            requiresNoSubmission: requiresNoSubmission
        )
    }

    @Test("An .event item shows the caveat even when requiresNoSubmission is false — it's never submittable by definition")
    func eventItemAlwaysShowsCaveat() {
        #expect(eventItem(requiresNoSubmission: false).showsNothingToSubmit)
    }

    @Test("An .assignment item with requiresNoSubmission true shows the caveat")
    func noSubmissionAssignmentShowsCaveat() {
        #expect(assignmentItem(requiresNoSubmission: true).showsNothingToSubmit)
    }

    @Test("An ordinary .assignment item shows no caveat")
    func ordinaryAssignmentShowsNoCaveat() {
        #expect(!assignmentItem(requiresNoSubmission: false).showsNothingToSubmit)
    }

    // MARK: - 3. AppState.requiresNoSubmission(_:)

    private func canvasAssignment(id: String, dueAt: Date? = nil) -> Assignment {
        Assignment(
            source: .canvas,
            sourceID: "event-assignment-\(id)@canvas.upenn.edu",
            kind: .assignment,
            course: "TEST 1000",
            title: "Test item",
            dueAt: dueAt,
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)")
        )
    }

    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    @Test("True for a Canvas assignment whose numeric id is in the cache")
    func trueForCachedID() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            #expect(state.requiresNoSubmission(canvasAssignment(id: "12345")))
        }
    }

    @Test("False for a Canvas assignment whose id is not in the cache")
    func falseForUncachedID() {
        withCachedIDs(["99999"]) {
            let state = makeState()
            #expect(!state.requiresNoSubmission(canvasAssignment(id: "12345")))
        }
    }

    @Test("False for a manual item — it carries no canvasAssignmentID to look up")
    func falseForManualItem() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            let manual = ManualAssignment(title: "My own task", course: "TEST 1000", dueAt: Date()).asAssignment()
            #expect(manual.canvasAssignmentID == nil)
            #expect(!state.requiresNoSubmission(manual))
        }
    }

    // MARK: - 4. Persistence across relaunch, and the disconnect clear

    @Test("The cache is seeded from UserDefaults.lhf at construction, and disconnectCanvas() clears it")
    func seedsFromDefaultsAndDisconnectClears() {
        withCachedIDs(["111", "222"]) {
            let state = makeState()
            #expect(state.noSubmissionCanvasAssignmentIDs == ["111", "222"])

            // `disconnectCanvas()` is exercised elsewhere against a real
            // in-memory `AppState` (`SessionCookieStoreTests`), which is what
            // makes calling it here safe rather than a guess: it wipes every
            // other piece of Canvas-session-derived state the same way, and
            // the no-submission cache belongs with them for the same reason
            // (a reconnect, possibly to a different account, must not inherit
            // stale caveats).
            state.disconnectCanvas()
            #expect(state.noSubmissionCanvasAssignmentIDs.isEmpty)
            #expect(UserDefaults.lhf.array(forKey: Self.cacheKey) == nil)
        }
    }

    // MARK: - 5. Scheduler gate

    @Test("Toggling the class off silences its no-submission items but not its normal ones")
    func toggleOffSilencesOnlyNoSubmissionItems() {
        withSchedulerFixture { scheduler, prefs, now in
            let items = [
                noSubmissionItem("CIS 1200", "attend", due: now + 2 * .day),
                normalItem("CIS 1200", "pset", due: now + 2 * .day),
            ]
            prefs.setNoSubmissionRemindersEnabled("CIS 1200", false)

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let due = requests.filter { $0.identifier.hasPrefix("due:") }

            #expect(!due.contains { $0.identifier.hasPrefix("due:canvas:attend:") })
            #expect(due.contains { $0.identifier.hasPrefix("due:canvas:pset:") })
        }
    }

    @Test("A course whose toggle was never touched still schedules its no-submission items (default on)")
    func untouchedCourseKeepsNoSubmissionReminders() {
        withSchedulerFixture { scheduler, prefs, now in
            // Course A's toggle is off; course B's is left at its default.
            let items = [
                noSubmissionItem("CIS 1200", "attend-a", due: now + 2 * .day),
                noSubmissionItem("MATH 1400", "attend-b", due: now + 2 * .day),
            ]
            prefs.setNoSubmissionRemindersEnabled("CIS 1200", false)

            let requests = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
            let due = requests.filter { $0.identifier.hasPrefix("due:") }

            #expect(!due.contains { $0.identifier.hasPrefix("due:canvas:attend-a:") })
            #expect(due.contains { $0.identifier.hasPrefix("due:canvas:attend-b:") })
        }
    }

    @Test("The digest excludes a silenced class's no-submission items while still counting its normal ones")
    func digestExcludesSilencedNoSubmissionItems() {
        withSchedulerFixture(digest: true) { scheduler, prefs, now in
            let soon = now + 20 * .hour
            let items = [
                noSubmissionItem("CIS 1200", "attend", due: soon),
                normalItem("CIS 1200", "pset", due: soon),
            ]

            // Both count while the toggle is on (the default).
            let bodyBefore = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
                .first { $0.identifier == "digest:daily" }?.content.body
            #expect(bodyBefore?.contains("2 assignments") == true)

            prefs.setNoSubmissionRemindersEnabled("CIS 1200", false)
            let bodyAfter = scheduler.plannedRequests(from: items, now: now, preferences: prefs)
                .first { $0.identifier == "digest:daily" }?.content.body
            #expect(bodyAfter?.contains("1 assignment ") == true)
        }
    }

    // MARK: - 6. isAutoFiledNoSubmission / isCompleted — offline auto-file at due time
    //
    // Added 2026-08-27 (follow-up): the snapshot-driven auto-file
    // (`autoSubmittedNoSubmissionIDs`, applied in `updateSubmissionState`)
    // only ever runs alongside a live grade refresh, which left a window
    // between refreshes where a past-due no-submission assignment sat in
    // OVERDUE — the owner's device pass caught exactly this ("Class 2:
    // Litigation... nothing to submit — 1h late"). `isAutoFiledNoSubmission`
    // is the cache-backed, works-offline twin; `isCompleted` calls it
    // directly so the dashboard never renders that state at all.

    @Test("isAutoFiledNoSubmission is true for a cached-id Canvas assignment due in the past")
    func autoFiledTrueForCachedPastDue() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            let pastDue = canvasAssignment(id: "12345", dueAt: Date().addingTimeInterval(-3600))
            #expect(state.isAutoFiledNoSubmission(pastDue))
        }
    }

    @Test("isAutoFiledNoSubmission is false for a cached-id Canvas assignment due in the future")
    func autoFiledFalseForCachedFutureDue() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            let futureDue = canvasAssignment(id: "12345", dueAt: Date().addingTimeInterval(3600))
            #expect(!state.isAutoFiledNoSubmission(futureDue))
        }
    }

    @Test("isAutoFiledNoSubmission is false for an undated cached-id assignment — nothing has passed")
    func autoFiledFalseForUndated() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            let undated = canvasAssignment(id: "12345", dueAt: nil)
            #expect(!state.isAutoFiledNoSubmission(undated))
        }
    }

    @Test("isAutoFiledNoSubmission is false for a past-due assignment whose id isn't cached")
    func autoFiledFalseForUncachedID() {
        withCachedIDs(["99999"]) {
            let state = makeState()
            let pastDue = canvasAssignment(id: "12345", dueAt: Date().addingTimeInterval(-3600))
            #expect(!state.isAutoFiledNoSubmission(pastDue))
        }
    }

    @Test("isAutoFiledNoSubmission is false for a manual item — it carries no canvasAssignmentID")
    func autoFiledFalseForManualItem() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            let manual = ManualAssignment(
                title: "My own task", course: "TEST 1000",
                dueAt: Date().addingTimeInterval(-3600)
            ).asAssignment()
            #expect(!state.isAutoFiledNoSubmission(manual))
        }
    }

    @Test("isCompleted is true for a cached-id no-submission assignment past its due time")
    func isCompletedTrueForPastDueNoSubmission() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            let pastDue = canvasAssignment(id: "12345", dueAt: Date().addingTimeInterval(-3600))
            #expect(state.isCompleted(pastDue))
        }
    }

    @Test("isCompleted is false for a cached-id no-submission assignment not yet due — reminders still fire beforehand")
    func isCompletedFalseForFutureDueNoSubmission() {
        withCachedIDs(["12345"]) {
            let state = makeState()
            let futureDue = canvasAssignment(id: "12345", dueAt: Date().addingTimeInterval(3600))
            #expect(!state.isCompleted(futureDue))
        }
    }

    // MARK: - Fixtures / helpers

    private static let cacheKey = "noSubmissionCanvasAssignmentIDsV1"

    /// Backs up whatever is on disk for the cache key, seeds it with `ids`,
    /// runs `body`, then restores exactly what was there before — the same
    /// pattern `UnknownCourseAttributionTests.withEnrolledCourses` uses for
    /// `enrolledCanvasCoursesV1`.
    private func withCachedIDs(_ ids: [String], _ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let saved = defaults.array(forKey: Self.cacheKey)
        defer {
            if let saved {
                defaults.set(saved, forKey: Self.cacheKey)
            } else {
                defaults.removeObject(forKey: Self.cacheKey)
            }
        }
        defaults.set(ids, forKey: Self.cacheKey)
        body()
    }

    /// A scheduler and preferences store over one throwaway defaults suite —
    /// never `UserDefaults.lhf` — so these tests can't contend with the
    /// cache tests above or leak into any other suite. Mirrors
    /// `PerCourseNotificationTests.withFixture`.
    private func withSchedulerFixture(
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
        scheduler.setOffset(.h24, on: true)
        scheduler.setOffset(.h1, on: true)
        scheduler.setDigestEnabled(digest)

        body(scheduler, CoursePreferencesStore(defaults: defaults), Date())
    }

    private func noSubmissionItem(_ course: String, _ id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "No-sub \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil,
            requiresNoSubmission: true
        )
    }

    private func normalItem(_ course: String, _ id: String, due: Date) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: .assignment,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }
}

private extension TimeInterval {
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400
}
