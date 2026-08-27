import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `AppState`'s course-content nudge lifecycle (docs/READINGS_COURSES_PLAN.md
/// Phase 2, item 13's "no nag storms" requirement).
///
/// SCOPE NOTE — what this file can and can't reach:
/// `pendingCourseNudge` is a plain `@Published var` (not `private(set)`), and
/// `CourseProfileReport` has a public memberwise initializer, so the
/// resolve/dismiss half of the lifecycle is directly testable by assigning a
/// synthetic report to `pendingCourseNudge` and calling the public methods.
///
/// The "at most one nudge queued per launch" gating itself
/// (`queueNudgeIfNeeded`/`nudgePresentedThisLaunch`/`recomputeCourseProfiles`)
/// is NOT reachable from a test: it's private, and the only caller that
/// invokes it is `refreshCourseIntel(cookies:)`, which requires a non-empty
/// cookie jar and talks to `CanvasDiscoveryClient` over a real `URLSession`
/// with no injection seam from `AppState` (the client takes a `session:`
/// parameter, but `refreshCourseIntel` always constructs its own default
/// one). Exercising that path would mean either live network access or
/// reflection into `private` state, both out of scope here. That half of
/// item 5 is left untested; a device pass (plan item 12) is the intended gate
/// for it.
@MainActor
@Suite("Course content nudge lifecycle", .serialized)
struct CourseContentNudgeTests {
    private static let decisionsKey = "courseContentDecisionsV1"
    private static let course = "LGST 9999"

    /// Same backup/restore discipline as `CourseContentDashboardTests` /
    /// `CourseContentDecisionStoreTests` — see those files' doc comments.
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

    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    @Test("resolving a nudge writes the decision, clears the pending nudge, and takes effect immediately")
    func resolveWritesDecisionAndClearsNudge() {
        withCleanDecision {
            let state = makeState()
            // A silent course with module readings — since the 2026-08-26
            // include-by-default flip, that's the only profile that still
            // nudges (calendar-readings courses show without asking).
            let report = CourseProfileReport(
                courseKey: Self.course,
                canvasCourseID: "1",
                displayName: "Legal Studies Seminar",
                profile: .silent(moduleReadingCount: 6),
                fingerprint: "silent:6"
            )
            state.pendingCourseNudge = report

            state.resolveCourseNudge(report, include: true)

            #expect(state.pendingCourseNudge == nil)
            #expect(state.courseContentIncluded(Self.course))
            let stored = CourseContentDecisionStore.load()[Self.course]
            #expect(stored?.choice == .include)
            #expect(stored?.fingerprint == "silent:6")
        }
    }

    @Test("resolving a nudge with 'not for this course' records exclude, not just a no-op")
    func resolveCanRecordExclude() {
        withCleanDecision {
            let state = makeState()
            let report = CourseProfileReport(
                courseKey: Self.course,
                canvasCourseID: nil,
                displayName: Self.course,
                profile: .silent(moduleReadingCount: 4),
                fingerprint: "silent:0"
            )
            state.pendingCourseNudge = report

            state.resolveCourseNudge(report, include: false)

            #expect(state.pendingCourseNudge == nil)
            #expect(!state.courseContentIncluded(Self.course))
            #expect(CourseContentDecisionStore.load()[Self.course]?.choice == .exclude)
        }
    }

    @Test("dismissing a nudge clears it without recording any decision")
    func dismissClearsWithoutDeciding() {
        withCleanDecision {
            let state = makeState()
            let report = CourseProfileReport(
                courseKey: Self.course,
                canvasCourseID: nil,
                displayName: Self.course,
                profile: .silent(moduleReadingCount: 4),
                fingerprint: "silent:0"
            )
            state.pendingCourseNudge = report

            state.dismissCourseNudge()

            #expect(state.pendingCourseNudge == nil)
            #expect(CourseContentDecisionStore.load()[Self.course] == nil)
        }
    }
}
