import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `AppState`'s content-decision filtering. Originally the opt-in design of
/// docs/READINGS_COURSES_PLAN.md Phase 2 — the default flipped to INCLUDE on
/// 2026-08-26 (owner's call, after a real readings-only class silently
/// vanished from the dashboard on device): `.event`-kind Canvas calendar
/// items now reach the dashboard by default, and only an explicit `.exclude`
/// decision (`setCourseContentIncluded(_, false)`) hides them — as of
/// 2026-08-27 (docs/decisions.md) this is the ONLY way to record `.exclude`;
/// the one-ask consent popup that used to also write it was removed. An
/// included event is never reclassified as an assessment even when its
/// title matches the exam/quiz regex.
///
/// `AppState` persists into the process-wide `UserDefaults.lhf`, and
/// `courseContentDecisions` is one JSON blob under "courseContentDecisionsV1"
/// (see `CourseContentDecisionStoreTests`) — every test here backs that key up
/// and restores it, and the suite is `.serialized` for the same
/// whole-blob-race reason documented there. Course codes are synthetic and
/// unique to this file ("LGST 9999") so they can't collide with any other
/// suite's course-selection state.
@MainActor
@Suite("Course content decisions — dashboard filtering", .serialized)
struct CourseContentDashboardTests {
    private static let decisionsKey = "courseContentDecisionsV1"
    private static let course = "LGST 9999"

    /// Backs up the whole decisions blob, clears any decision for `course` (so
    /// a previous interrupted run can't leak an answer in), runs `body`, then
    /// restores exactly what was on disk before this test touched it.
    private func withCleanDecision(_ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let saved = defaults.data(forKey: Self.decisionsKey)
        defer {
            if let saved {
                defaults.set(saved, forKey: Self.decisionsKey)
            } else {
                defaults.removeObject(forKey: Self.decisionsKey)
            }
        }
        var map = CourseContentDecisionStore.load()
        map.removeValue(forKey: Self.course)
        CourseContentDecisionStore.save(map)
        body()
    }

    /// Every `AppState` here gets its own hermetic in-memory ledger — the same
    /// reasoning `IntroFlowTests.makeState()` documents — so these tests can't
    /// contend on a real on-disk store or leak ledger rows between runs.
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    // `dueAt` defaults an hour into the future, not to `Date()` at the
    // instant of construction. `AppState.isExpiredEvent` compares against
    // `now: Date()` captured later — inside `rebuildDashboardItems`, itself
    // called after the item is built, the ledger is touched, and often an
    // `AppState` is constructed — and since 2026-08-27's fix (`due < now`,
    // no day rounding) a fixture literally due "now" is measurably in the
    // past by the time that later `now` is captured, making every `.event`
    // fixture here expire and vanish out from under tests that exist to
    // prove it's shown. An hour of headroom is nowhere close to being
    // consumed by test execution and keeps these fixtures meaning "due
    // later today," which is what they were always meant to express.
    private func item(kind: Assignment.Kind, title: String,
                      dueAt: Date = Date().addingTimeInterval(3600), url: URL? = nil) -> Assignment {
        Assignment(source: .canvas, sourceID: "\(Self.course)-\(title)", kind: kind,
                   course: Self.course, title: title, dueAt: dueAt, url: url)
    }

    /// `canvasItems` has no `didSet`, so setting it directly (as
    /// `DashboardFilterTests` also does) doesn't by itself rebuild the
    /// dashboard buckets. Re-selecting the course it's already selected in is
    /// a harmless, idempotent way to force `rebuildDashboardItems()` without
    /// touching any content decision.
    private func triggerRebuild(_ state: AppState) {
        state.setCourse(Self.course, selected: true)
    }

    private func allDashboardItems(_ state: AppState) -> [Assignment] {
        state.assignments + state.laterAssignments + state.assessments
    }

    // MARK: - Default exclude (item 2)

    @Test("default include: an .event item shows on the dashboard with no decision on file")
    func defaultIncludeShowsEvents() {
        withCleanDecision {
            let state = makeState()
            state.canvasItems = [
                item(kind: .assignment, title: "Problem set 1"),
                item(kind: .event, title: "Weekly reading"),
            ]
            triggerRebuild(state)

            // The regression this default fixes: a class posting only calendar
            // events vanished entirely until its one-ask consent popup was
            // answered.
            #expect(state.courseContentIncluded(Self.course))
            let shown = allDashboardItems(state)
            #expect(shown.contains { $0.title == "Problem set 1" })
            #expect(shown.contains { $0.title == "Weekly reading" })
        }
    }

    // MARK: - Explicit exclude / re-include (item 3)

    @Test("an explicit exclude hides the event; re-including surfaces it again")
    func excludeThenReInclude() {
        withCleanDecision {
            let state = makeState()
            state.canvasItems = [item(kind: .event, title: "Weekly reading")]
            triggerRebuild(state)
            #expect((state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })

            state.setCourseContentIncluded(Self.course, false)
            #expect(!state.courseContentIncluded(Self.course))
            #expect(!(state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })

            state.setCourseContentIncluded(Self.course, true)
            #expect(state.courseContentIncluded(Self.course))
            #expect((state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })
        }
    }

    // MARK: - Events never become assessments (item 4)

    @Test("an opted-in event titled like an exam still lands in coursework, never Assessments")
    func optedInEventsAreNeverAssessments() {
        withCleanDecision {
            let state = makeState()
            state.canvasItems = [item(kind: .event, title: "Midterm review reading")]
            state.setCourseContentIncluded(Self.course, true)

            #expect(!state.assessments.contains { $0.title == "Midterm review reading" })
            #expect((state.assignments + state.laterAssignments).contains { $0.title == "Midterm review reading" })
        }
    }

    @Test("the same title on a non-event kind still surfaces as an assessment (sanity check on the exclusion)")
    func nonEventExamTitleStillAnAssessment() {
        withCleanDecision {
            let state = makeState()
            state.canvasItems = [item(kind: .quiz, title: "Midterm review reading")]
            triggerRebuild(state)

            #expect(state.assessments.contains { $0.title == "Midterm review reading" })
        }
    }

    // MARK: - Expired events drop off (readings have nothing to submit)

    @Test("an opted-in event drops off the dashboard the moment its due time passes, not merely once its calendar day ends")
    func optedInEventExpiresAfterItsDueTime() {
        withCleanDecision {
            let state = makeState()
            let now = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            // Same calendar day as `now`, but its own moment has already
            // passed — this is the case day-granularity used to miss
            // entirely (it stayed "overdue" until midnight). Renamed from
            // "Today's reading" / `dueAt: now`, which only demonstrated the
            // day boundary and, on the new time-based rule, was really an
            // edge case (`due == now` is not `< now`) rather than a real
            // same-day-but-past example.
            let earlierToday = now.addingTimeInterval(-3600)
            let laterToday = now.addingTimeInterval(3600)
            state.canvasItems = [
                item(kind: .event, title: "Yesterday's reading", dueAt: yesterday),
                item(kind: .event, title: "Earlier today's reading", dueAt: earlierToday),
                item(kind: .event, title: "Later today's reading", dueAt: laterToday),
            ]
            state.setCourseContentIncluded(Self.course, true)

            let shown = state.assignments + state.laterAssignments
            #expect(!shown.contains { $0.title == "Yesterday's reading" })
            #expect(!shown.contains { $0.title == "Earlier today's reading" })
            #expect(shown.contains { $0.title == "Later today's reading" })
        }
    }

    // MARK: - Grade Watcher independence (item 6)

    @Test("flipping a content decision never changes canvasCourseIDsByCode or selectedCanvasCourseIDs()")
    func gradeWatcherIndependence() {
        // This test is the only one in the suite that populates
        // `canvasCourseIDsByCode` (via a URL-bearing item), so clean up the
        // one synthetic entry it adds rather than leaving it in the
        // process-wide store for good.
        defer {
            var byCode = UserDefaults.lhf.dictionary(forKey: "canvasCourseIDsByCode") as? [String: String] ?? [:]
            byCode.removeValue(forKey: Self.course)
            UserDefaults.lhf.set(byCode, forKey: "canvasCourseIDsByCode")
        }
        withCleanDecision {
            let state = makeState()
            // A submittable assignment (always shown regardless of any content
            // decision) whose URL is what actually populates
            // `canvasCourseIDsByCode` — see `AppState.updateCanvasCourseIDCache`.
            state.canvasItems = [
                item(kind: .assignment, title: "HW1",
                     url: URL(string: "https://canvas.upenn.edu/courses/424242/assignments/1")),
            ]
            triggerRebuild(state)

            let beforeMap = state.canvasCourseIDsByCode
            let beforeSelected = state.selectedCanvasCourseIDs()
            #expect(beforeMap[Self.course] == "424242")

            state.setCourseContentIncluded(Self.course, true)
            #expect(state.canvasCourseIDsByCode == beforeMap)
            #expect(state.selectedCanvasCourseIDs() == beforeSelected)

            state.setCourseContentIncluded(Self.course, false)
            #expect(state.canvasCourseIDsByCode == beforeMap)
            #expect(state.selectedCanvasCourseIDs() == beforeSelected)
        }
    }
}
