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
            // Due an hour from now, not literally `Date()` — see
            // `CourseContentDashboardTests.item`'s doc comment: since
            // 2026-08-27's `isExpiredEvent` fix (`due < now`, no day
            // rounding), a fixture due at the instant of construction is
            // measurably in the past by the time `AppState.init`'s own
            // later `rebuildDashboardItems` captures `now`, and this test
            // exists specifically to prove the item still shows.
            let imported = reading(id: "1", title: "Week 3 reading", dueAt: Date().addingTimeInterval(3600))
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
            // Same reasoning as `includedReadingSurfacesInCoursework` above.
            let imported = reading(id: "2", title: "Week 4 reading", dueAt: Date().addingTimeInterval(3600))
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
            // Same reasoning as `includedReadingSurfacesInCoursework` above.
            let imported = reading(id: "4", title: "Midterm review reading", dueAt: Date().addingTimeInterval(3600))
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

    // MARK: - Item 6: same assignment on both the ICS feed and Modules import shows once

    /// Field evidence this covers: a lab session Canvas describes both on the
    /// ICS calendar feed (`.canvas`) and on the Modules JSON page
    /// (`.canvasModules`, imported for a readings-opted-in course) used to
    /// show as two separate dashboard cards for the same assignment.
    /// `AssignmentDeduplicator.collapseCanvasDuplicates` (wired into
    /// `rebuildDashboardItems`'s `canvasPool`) hides the module-side copy —
    /// exercised here through the identical-title/identical-due-date tier of
    /// `isLikelyDuplicate` since this seeded module row, like the others in
    /// this file, carries no url for the id-match tier to use.
    @Test("a .canvas row and a .canvasModules row for the same assignment appear once on the dashboard")
    func canvasAndModuleDuplicateCollapseToOneDashboardRow() {
        withCleanDecision {
            let store = try! AssignmentStore(inMemory: true)
            let sharedDueDate = Date().addingTimeInterval(3600)

            let canvasRow = Assignment(
                source: .canvas, sourceID: "assignment-777", kind: .assignment,
                course: Self.course, title: "Week 6 lab", dueAt: sharedDueDate, url: nil
            )
            _ = store.reconcile([canvasRow], source: .canvas)

            let moduleRow = reading(id: "20", title: "Week 6 lab", dueAt: sharedDueDate)
            _ = store.reconcile([moduleRow], source: .canvasModules)

            let state = AppState(assignmentStore: store)
            setIncluded(state)

            #expect(allDashboardItems(state).filter { $0.title == "Week 6 lab" }.count == 1)
        }
    }

    // MARK: - Item 7: moduleReadingAssignment's url derivation

    /// `AppState.moduleReadingAssignment` is the pure helper `importModuleReadings`
    /// builds each row through. These three cover the type/contentID
    /// combinations that decide whether it sets a `/assignments/<id>` url —
    /// see the helper's own doc comment for why only this exact combination
    /// is trusted.
    @Test("moduleReadingAssignment sets an /assignments/<contentID> url for an Assignment-type item")
    func moduleReadingAssignmentSetsURLForAssignmentType() {
        let item = CanvasModulesClient.ModuleItem(
            id: "9001",
            title: "HW 3",
            dueAt: Date(),
            typeRaw: "Assignment",
            contentID: "12345"
        )
        let assignment = AppState.moduleReadingAssignment(item: item, courseKey: Self.course, courseID: "555")

        #expect(assignment.url == URL(string: "https://canvas.upenn.edu/courses/555/assignments/12345"))
        // The same URL is what `Assignment.canvasAssignmentID` parses back
        // out — this is the whole point of setting it: the join key to
        // Grade Watcher's submission side-channel.
        #expect(assignment.canvasAssignmentID == "12345")
    }

    @Test("moduleReadingAssignment leaves url nil for a Page-type item")
    func moduleReadingAssignmentLeavesURLNilForPageType() {
        let item = CanvasModulesClient.ModuleItem(
            id: "9002",
            title: "Week 3 reading",
            dueAt: Date(),
            typeRaw: "Page",
            contentID: "12346"
        )
        let assignment = AppState.moduleReadingAssignment(item: item, courseKey: Self.course, courseID: "555")

        #expect(assignment.url == nil)
    }

    @Test("moduleReadingAssignment leaves url nil for an Assignment-type item with no contentID")
    func moduleReadingAssignmentLeavesURLNilWithoutContentID() {
        let item = CanvasModulesClient.ModuleItem(
            id: "9003",
            title: "Untitled assignment link",
            dueAt: nil,
            typeRaw: "Assignment",
            contentID: nil
        )
        let assignment = AppState.moduleReadingAssignment(item: item, courseKey: Self.course, courseID: "555")

        #expect(assignment.url == nil)
    }
}
