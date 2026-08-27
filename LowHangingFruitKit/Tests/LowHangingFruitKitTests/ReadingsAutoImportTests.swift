import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `AppState`'s readings auto-import gate (`shouldAutoImportReadings`),
/// replacing the one-ask "include this class's readings?" popup
/// (`CourseNudgeSheet`, `pendingCourseNudge`, `resolveCourseNudge`,
/// `dismissCourseNudge`) removed 2026-08-27 (docs/decisions.md). The owner's
/// call: the data is the student's own, so a silent course's Modules
/// readings import automatically the moment a probe finds them, and the
/// ONLY thing that still blocks that import is an explicit `.exclude`
/// recorded via Settings' "Courses & content" toggle
/// (`AppState.setCourseContentIncluded`).
///
/// This file used to be `CourseContentNudgeTests` and exercised the
/// resolve/dismiss lifecycle of `pendingCourseNudge`, which no longer
/// exists. `shouldAutoImportReadings` is a pure, synchronous, directly
/// testable predicate over `courseContentDecisions` — no cookie jar or
/// network seam needed — so unlike the old suite's "at most one nudge per
/// launch" gating (which required `refreshCourseIntel`'s live network path
/// and was left untested, per that file's own SCOPE NOTE), the new
/// auto-import gate is fully reachable from a test.
@MainActor
@Suite("Readings auto-include", .serialized)
struct ReadingsAutoImportTests {
    private static let decisionsKey = "courseContentDecisionsV1"
    private static let course = "LGST 9999"

    /// Same backup/restore discipline as `CourseContentDashboardTests` /
    /// `ModuleReadingImportTests` — see those files' doc comments.
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

    private func item(kind: Assignment.Kind, title: String, dueAt: Date = Date()) -> Assignment {
        Assignment(source: .canvas, sourceID: "\(Self.course)-\(title)", kind: kind,
                   course: Self.course, title: title, dueAt: dueAt, url: nil)
    }

    @Test("a course with no decision on file auto-imports (default is include)")
    func noDecisionAutoImports() {
        withCleanDecision {
            let state = makeState()
            #expect(state.shouldAutoImportReadings(for: Self.course))
        }
    }

    @Test("an explicit exclude blocks auto-import")
    func explicitExcludeBlocksAutoImport() {
        withCleanDecision {
            let state = makeState()
            state.setCourseContentIncluded(Self.course, false)

            #expect(!state.shouldAutoImportReadings(for: Self.course))
        }
    }

    @Test("flipping the Settings toggle back on allows auto-import again")
    func reIncludingAllowsAutoImportAgain() {
        withCleanDecision {
            let state = makeState()
            state.setCourseContentIncluded(Self.course, false)
            #expect(!state.shouldAutoImportReadings(for: Self.course))

            state.setCourseContentIncluded(Self.course, true)
            #expect(state.shouldAutoImportReadings(for: Self.course))
        }
    }

    /// Same regression `CourseContentDashboardTests.excludeThenReInclude`
    /// covers for feed-sourced `.event` items, kept here too because this
    /// suite is specifically about the consequences of removing the popup:
    /// an explicit exclude must still be honoured for what's already on the
    /// dashboard, not just for future imports.
    @Test("setCourseContentIncluded(false) hides the course's .event items from the dashboard")
    func excludeHidesEventItemsFromDashboard() {
        withCleanDecision {
            let state = makeState()
            state.canvasItems = [item(kind: .event, title: "Weekly reading")]
            state.setCourse(Self.course, selected: true) // force a dashboard rebuild

            #expect((state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })

            state.setCourseContentIncluded(Self.course, false)
            #expect(!(state.assignments + state.laterAssignments).contains { $0.title == "Weekly reading" })
        }
    }
}
