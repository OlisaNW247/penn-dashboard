import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for `AppState.attributingUnknownCourse`: Canvas sometimes omits
/// the "[Course Name]" suffix on a calendar-event SUMMARY, so
/// `CanvasICSClient.splitCourse` buckets the item under `unknownCourse` even
/// though the event's own URL still carries the Canvas course id. When that
/// id matches an enrolled course, the item should be re-keyed to it; when it
/// doesn't (an institution-wide event) or there's no URL at all, it should
/// stay `unknownCourse`; and an item that already has a real course must
/// never be touched.
///
/// `AppState` seeds `enrolledCanvasCourses` from `UserDefaults.lhf` under
/// "enrolledCanvasCoursesV1" at construction time (see `AppState.init`), so
/// every test here backs that key up and restores it, the same pattern
/// `CourseContentDashboardTests` uses for its own decisions blob. The suite
/// is `.serialized` for the same whole-key-race reason. Course codes/ids are
/// synthetic and unique to this file.
@MainActor
@Suite("Unknown-course attribution from a calendar event's URL", .serialized)
struct UnknownCourseAttributionTests {
    private static let enrolledKey = "enrolledCanvasCoursesV1"

    /// Backs up whatever's on disk for the enrolled-courses key, seeds it
    /// with `courses` (Canvas id -> raw display name, the same shape
    /// `AppState.persistEnrolledCanvasCourses` writes), runs `body` with a
    /// fresh `AppState` constructed against that seed, then restores exactly
    /// what was there before.
    private func withEnrolledCourses(_ courses: [String: String], _ body: (AppState) -> Void) {
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
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        body(state)
    }

    private func unknownItem(url: URL?, dueAt: Date = Date()) -> Assignment {
        Assignment(
            source: .canvas,
            sourceID: "event-unknown-1",
            kind: .event,
            course: AppState.unknownCourse,
            title: "No class today",
            dueAt: dueAt,
            url: url
        )
    }

    // MARK: - Enrolled id resolves

    @Test("an unknown-course event whose URL's course id is enrolled re-keys to that course")
    func reattributesToEnrolledCourse() {
        withEnrolledCourses(["777": "LGST 9999 Something 2026C"]) { state in
            let item = unknownItem(
                url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_777&month=8&year=2026")
            )
            let result = state.attributingUnknownCourse(item)
            #expect(result.course == "LGST 9999")
            // Everything else about the item is preserved unchanged.
            #expect(result.id == item.id)
            #expect(result.title == item.title)
            #expect(result.dueAt == item.dueAt)
            #expect(result.url == item.url)
            #expect(result.kind == item.kind)
        }
    }

    // MARK: - Not enrolled stays unknown

    @Test("an unknown-course event whose URL's course id is NOT enrolled stays unknown")
    func nonEnrolledCourseIDStaysUnknown() {
        withEnrolledCourses(["777": "LGST 9999 Something 2026C"]) { state in
            let item = unknownItem(
                url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_999&month=8&year=2026")
            )
            let result = state.attributingUnknownCourse(item)
            #expect(result.course == AppState.unknownCourse)
        }
    }

    // MARK: - Already-attributed items are never touched

    @Test("an item already keyed to a real course is never re-keyed, even with a URL")
    func alreadyKeyedItemUntouched() {
        withEnrolledCourses(["777": "LGST 9999 Something 2026C"]) { state in
            let item = Assignment(
                source: .canvas,
                sourceID: "assignment-1",
                kind: .assignment,
                course: "CIS 1200",
                title: "Homework 3",
                dueAt: Date(),
                url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_777")
            )
            let result = state.attributingUnknownCourse(item)
            #expect(result.course == "CIS 1200")
        }
    }

    // MARK: - No URL stays unknown

    @Test("an unknown-course event with no URL stays unknown")
    func nilURLStaysUnknown() {
        withEnrolledCourses(["777": "LGST 9999 Something 2026C"]) { state in
            let item = unknownItem(url: nil)
            let result = state.attributingUnknownCourse(item)
            #expect(result.course == AppState.unknownCourse)
        }
    }
}
