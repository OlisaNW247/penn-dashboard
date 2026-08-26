import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `AppState`'s content-decision filtering (docs/READINGS_COURSES_PLAN.md
/// Phase 2): `.event`-kind Canvas calendar items only reach the dashboard for
/// a course the user has opted in via `setCourseContentIncluded`/
/// `resolveCourseNudge`; the default (no decision on file) is exclude, and an
/// opted-in event is never reclassified as an assessment even when its title
/// matches the exam/quiz regex.
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

    private func item(kind: Assignment.Kind, title: String, dueAt: Date = Date(), url: URL? = nil) -> Assignment {
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

    @Test("default exclude: an .event item stays off the dashboard with no decision on file")
    func defaultExcludeHidesEvents() {
        withCleanDecision {
            let state = makeState()
            state.canvasItems = [
                item(kind: .assignment, title: "Problem set 1"),
                item(kind: .event, title: "Weekly reading"),
            ]
            triggerRebuild(state)

            #expect(!state.courseContentIncluded(Self.course))
            let shown = allDashboardItems(state)
            #expect(shown.contains { $0.title == "Problem set 1" })
            #expect(!shown.contains { $0.title == "Weekly reading" })
        }
    }

    // MARK: - Opt-in / opt-out (item 3)

    @Test("opting in surfaces the event; opting back out hides it again")
    func optInThenOptOut() {
        withCleanDecision {
            let state = makeState()
            state.canvasItems = [item(kind: .event, title: "Weekly reading")]
            triggerRebuild(state)
            #expect(!(state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })

            state.setCourseContentIncluded(Self.course, true)
            #expect(state.courseContentIncluded(Self.course))
            #expect((state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })

            state.setCourseContentIncluded(Self.course, false)
            #expect(!state.courseContentIncluded(Self.course))
            #expect(!(state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })
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

    @Test("an opted-in event drops off the dashboard once its calendar day has passed")
    func optedInEventExpiresAfterItsDay() {
        withCleanDecision {
            let state = makeState()
            let now = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            state.canvasItems = [
                item(kind: .event, title: "Yesterday's reading", dueAt: yesterday),
                item(kind: .event, title: "Today's reading", dueAt: now),
            ]
            state.setCourseContentIncluded(Self.course, true)

            let shown = state.assignments + state.laterAssignments
            #expect(!shown.contains { $0.title == "Yesterday's reading" })
            #expect(shown.contains { $0.title == "Today's reading" })
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
