import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for the two class-list sources added by the CIS 2620 fix (see
/// HANDOFF.md "readings/Modules-only classes missing from Profile's class
/// list"): `allCourseCodes()` now unions in (1) `.canvasModules` ledger rows,
/// so a silent course whose imported readings are on the ledger lists like any
/// other class, and (2) the cached enrolled-course list, so an enrolled class
/// appears in Profile before it posts anything anywhere.
///
/// `AppState` seeds `enrolledCanvasCourses` from `UserDefaults.lhf` under
/// "enrolledCanvasCoursesV1" at construction time, so every test here backs
/// that key up and restores it (the `UnknownCourseAttributionTests` pattern);
/// the suite is `.serialized` for the same whole-key-race reason. Course
/// codes/ids are synthetic and unique to this file.
@MainActor
@Suite("Class-list sources beyond the feeds", .serialized)
struct CourseListSourcesTests {
    private static let enrolledKey = "enrolledCanvasCoursesV1"

    /// Backs up the enrolled-courses key, seeds it with `courses` (Canvas
    /// id -> raw display name, the shape `persistEnrolledCanvasCourses`
    /// writes), constructs an `AppState` against that seed and the given
    /// (default: empty in-memory) ledger, then restores the key exactly.
    private func withEnrolledCourses(_ courses: [String: String],
                                     store: AssignmentStore? = nil,
                                     _ body: (AppState) -> Void) {
        let defaults = UserDefaults.lhf
        let saved = defaults.dictionary(forKey: Self.enrolledKey)
        defer {
            if let saved {
                defaults.set(saved, forKey: Self.enrolledKey)
            } else {
                defaults.removeObject(forKey: Self.enrolledKey)
            }
        }
        defaults.set(courses, forKey: Self.enrolledKey)
        let state = AppState(assignmentStore: store ?? (try? AssignmentStore(inMemory: true)))
        body(state)
    }

    // MARK: - Modules-only course lists

    @Test("a course with only .canvasModules ledger rows appears in the class list")
    func modulesOnlyCourseLists() {
        let store = try! AssignmentStore(inMemory: true)
        let reading = Assignment(
            source: .canvasModules,
            sourceID: "module-item-cls-1",
            kind: .event,
            course: "PHIL 7770",
            title: "Week 1 reading",
            dueAt: Date(),
            url: nil
        )
        _ = store.reconcile([reading], source: .canvasModules)

        withEnrolledCourses([:], store: store) { state in
            #expect(state.allCourseCodes().contains("PHIL 7770"))
            #expect(state.visibleCourseCodes().contains("PHIL 7770"))
        }
    }

    // MARK: - Cached enrolled course with zero items lists

    @Test("a cached enrolled course with zero items appears in the class list")
    func enrolledCourseWithNoItemsLists() {
        withEnrolledCourses(["424242": "SPAN 8880 Conversation Lab"]) { state in
            #expect(!state.canvasItems.contains { $0.course == "SPAN 8880" })
            #expect(state.allCourseCodes().contains("SPAN 8880"))
            #expect(state.visibleCourseCodes().contains("SPAN 8880"))
        }
    }

    /// `isEnrolledCourseCurrent` is re-applied at read time, so a cache
    /// persisted last term can't resurrect a finished class. (202010 is a
    /// long-past `YYYYTT` term code.)
    @Test("a cached enrolled course from a past term does not resurface")
    func pastTermEnrolledCourseFiltered() {
        withEnrolledCourses(["424243": "SPAN 8880-001 202010 Conversation Lab"]) { state in
            #expect(!state.allCourseCodes().contains("SPAN 8880"))
        }
    }

    /// The `containsExplicitCode` junk filter is re-applied at read time too,
    /// protecting caches written before ingestion filtered (Canvas resource
    /// sites like exam archives carry no DEPT+number code).
    @Test("a cached enrollment entry without a real course code does not list")
    func junkEnrollmentEntryFiltered() {
        withEnrolledCourses(["424244": "Physics Exam Archive"]) { state in
            #expect(!state.allCourseCodes().contains("Physics Exam Archive"))
        }
    }

    // MARK: - Listing is not importing

    /// The class being listed and its readings being fetched are separate
    /// questions: unioning the cached enrollment into the class list must not
    /// put anything on the dashboard, whose pools still come from feed items
    /// and opted-in imports alone.
    @Test("listing a cached enrolled course adds nothing to the dashboard")
    func listingDoesNotFeedDashboard() {
        withEnrolledCourses(["424245": "SPAN 8880 Conversation Lab"]) { state in
            let dashboard = state.assignments + state.laterAssignments + state.assessments
            #expect(!dashboard.contains { $0.course == "SPAN 8880" })
        }
    }
}
