import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Module-imported readings (docs/READINGS_COURSES_PLAN.md Phase 2/3 wiring):
/// `AssignmentStore.reconcile(_:source: .canvasModules)` and `AppState
/// .moduleReadingItems`/`rebuildDashboardItems`'s `canvasPool`.
///
/// `refreshCourseIntel(cookies:)`'s probe swap (JSON-first, HTML fallback)
/// itself is NOT exercised here — same reasoning `ReadingsAutoImportTests`
/// documents: it requires a non-empty cookie jar and talks to
/// `CanvasDiscoveryClient`/`CanvasModulesClient` over a real `URLSession`
/// with no injection seam from `AppState`. Instead, these tests seed the
/// ledger directly with `.canvasModules` rows — exactly the shape
/// `refreshCourseIntel` would have written — and exercise everything
/// downstream of that: launch-time hydration into `moduleReadingItems`,
/// the content-decision gate, and dashboard bucket placement.
///
/// `AppState` persists into the process-wide `UserDefaults.lhf`, and
/// `courseContentDecisions` is one JSON blob under "courseContentDecisionsV1"
/// (see `CourseContentDecisionStoreTests`) — every test here backs that key
/// up and restores it, and the suite is `.serialized` for the same
/// whole-blob-race reason documented there. Course codes are synthetic and
/// unique to this file ("LGST 9999") so they can't collide with any other
/// suite's course-selection state.
@MainActor
@Suite("Module reading import — ledger + dashboard wiring", .serialized)
struct ModuleReadingImportTests {
    private static let decisionsKey = "courseContentDecisionsV1"
    private static let course = "LGST 9999"

    /// Same backup/restore discipline as `CourseContentDashboardTests` /
    /// `ReadingsAutoImportTests` — see those files' doc comments.
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

    /// A module-imported reading, shaped exactly the way `refreshCourseIntel`
    /// builds one from a `CanvasModulesClient.ModuleItem`.
    private func reading(id: String, title: String, dueAt: Date?) -> Assignment {
        Assignment(
            source: .canvasModules,
            sourceID: "module-item-\(id)",
            kind: .event,
            course: Self.course,
            title: title,
            dueAt: dueAt,
            url: nil
        )
    }

    private func setIncluded(_ state: AppState) {
        state.setCourseContentIncluded(Self.course, true)
    }

    private func allDashboardItems(_ state: AppState) -> [Assignment] {
        state.assignments + state.laterAssignments + state.assessments
    }

    // MARK: - Item 1: included decision + moduleReadingItems -> shows in coursework

    @Test("an imported reading for an opted-in course shows in the coursework buckets")
    func includedReadingSurfacesInCoursework() {
        withCleanDecision {
            let store = try! AssignmentStore(inMemory: true)
            let imported = reading(id: "1", title: "Week 3 reading", dueAt: Date())
            _ = store.reconcile([imported], source: .canvasModules)

            let state = AppState(assignmentStore: store)
            // Hydration happens in `init` before any decision exists; opting
            // in afterward is what should surface it (mirrors
            // `CourseContentDashboardTests.optInThenOptOut`).
            setIncluded(state)

            #expect(allDashboardItems(state).contains { $0.title == "Week 3 reading" })
            #expect(!state.assessments.contains { $0.title == "Week 3 reading" })
        }
    }

    // MARK: - Item 2: only an explicit exclude hides

    /// Under the 2026-08-26 include-by-default flip (see `AppState.
    /// includesAsOptedInContent`), a ledger row with no decision on file
    /// shows. In practice `.canvasModules` rows only exist after an opt-in
    /// import wrote an `.include` decision — this covers the decision-less
    /// edge (e.g. the decision store cleared on disconnect while rows
    /// survived a partial purge) landing on the visible side, matching the
    /// calendar-event default.
    @Test("an imported reading with no decision on file shows on the dashboard")
    func defaultIncludeShowsImportedReading() {
        withCleanDecision {
            let store = try! AssignmentStore(inMemory: true)
            let imported = reading(id: "2", title: "Week 4 reading", dueAt: Date())
            _ = store.reconcile([imported], source: .canvasModules)

            let state = AppState(assignmentStore: store)

            #expect(state.courseContentIncluded(Self.course))
            #expect(allDashboardItems(state).contains { $0.title == "Week 4 reading" })
        }
    }

    @Test("an imported reading for an explicitly excluded course stays off the dashboard")
    func explicitExcludeHidesImportedReading() {
        withCleanDecision {
            let store = try! AssignmentStore(inMemory: true)
            let imported = reading(id: "3", title: "Week 5 reading", dueAt: Date())
            _ = store.reconcile([imported], source: .canvasModules)

            let state = AppState(assignmentStore: store)
            state.setCourseContentIncluded(Self.course, false)

            #expect(!allDashboardItems(state).contains { $0.title == "Week 5 reading" })
        }
    }

    // MARK: - Item 3: imported items never land in Assessments, even exam-like titles

    @Test("an opted-in imported reading titled like an exam still lands in coursework, never Assessments")
    func importedReadingWithExamLikeTitleNeverAnAssessment() {
        withCleanDecision {
            let store = try! AssignmentStore(inMemory: true)
            let imported = reading(id: "4", title: "Midterm review reading", dueAt: Date())
            _ = store.reconcile([imported], source: .canvasModules)

            let state = AppState(assignmentStore: store)
            setIncluded(state)

            #expect(!state.assessments.contains { $0.title == "Midterm review reading" })
            #expect((state.assignments + state.laterAssignments).contains { $0.title == "Midterm review reading" })
        }
    }

    // MARK: - Item 4: reconcile round-trip, other sources untouched

    @Test("reconcile round-trip: canvasModules rows read back distinctly, .canvas rows untouched")
    func reconcileRoundTripIsolatedFromCanvasSource() {
        let store = try! AssignmentStore(inMemory: true)

        // Seed one .canvas row first, per the brief — reconciling a
        // .canvasModules batch afterward must not disturb it.
        let canvasRow = Assignment(
            source: .canvas, sourceID: "hw-1", kind: .assignment,
            course: Self.course, title: "Problem set 1", dueAt: Date(), url: nil
        )
        let canvasResult = store.reconcile([canvasRow], source: .canvas)
        #expect(canvasResult.items.map(\.title) == ["Problem set 1"])

        let imported = [
            reading(id: "10", title: "Week 1 reading", dueAt: Date()),
            reading(id: "11", title: "Week 2 reading", dueAt: Date()),
        ]
        let moduleResult = store.reconcile(imported, source: .canvasModules)

        #expect(Set(moduleResult.items.map(\.title)) == ["Week 1 reading", "Week 2 reading"])
        #expect(!moduleResult.wasSuspectedPartial)

        // Read back distinctly from each other.
        let canvasRows = store.assignments(source: .canvas)
        let moduleRows = store.assignments(source: .canvasModules)
        #expect(canvasRows.map(\.title) == ["Problem set 1"])
        #expect(Set(moduleRows.map(\.title)) == ["Week 1 reading", "Week 2 reading"])
        // The .canvas row must still be present and not flagged gone by the
        // .canvasModules reconcile — `reconcile` partitions by source before
        // deciding what's missing, so a same-course, different-source batch
        // can never mark it gone.
        #expect(canvasRows.contains { $0.sourceID == "hw-1" })
    }

    // MARK: - Item 5: undated imported reading — documents the actual bucket

    @Test("an undated imported reading lands in laterAssignments, per isNearOrOverdue/withinTermCap's nil handling")
    func undatedImportedReadingLandsInLater() {
        withCleanDecision {
            let store = try! AssignmentStore(inMemory: true)
            let imported = reading(id: "5", title: "No-date reading", dueAt: nil)
            _ = store.reconcile([imported], source: .canvasModules)

            let state = AppState(assignmentStore: store)
            setIncluded(state)

            // `AppState.isNearOrOverdue` requires a due date (nil -> false),
            // so an undated `.event` item never qualifies as "near or
            // overdue" and instead falls into `laterAssignments` —
            // `isTooOld`/`withinTermCap` both pass an undated item through
            // unconditionally, so nothing else filters it out first.
            #expect(state.laterAssignments.contains { $0.title == "No-date reading" })
            #expect(!state.assignments.contains { $0.title == "No-date reading" })
            #expect(!state.assessments.contains { $0.title == "No-date reading" })
        }
    }
}
