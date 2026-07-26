import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Grade Watcher needs a Canvas *numeric course id* per selected class, and the
/// only place one appears is an ICS item's URL. When that lookup came up empty
/// the screen claimed "No classes selected yet" even with classes switched on —
/// the bug these tests pin down.
@MainActor
@Suite("Grade Watcher course resolution")
struct GradeWatcherCourseResolutionTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("direct course links resolve, as they always did")
    func directCourseLink() {
        #expect(AppState.courseID(from: url("https://canvas.upenn.edu/courses/1925208/assignments/12345")) == "1925208")
        #expect(AppState.courseID(from: url("https://canvas.upenn.edu/courses/42/quizzes/7")) == "42")
    }

    /// The regression: Canvas serves calendar-sourced items with a
    /// `/calendar?include_contexts=course_<id>` URL, which has no `/courses/`
    /// path segment at all. Every such item resolved to nil, so a student whose
    /// feed was entirely calendar-shaped saw an empty Grade Watcher.
    @Test("calendar-style links resolve via include_contexts")
    func calendarStyleLink() {
        #expect(AppState.courseID(from: url("https://canvas.upenn.edu/calendar?include_contexts=course_1925208&month=07")) == "1925208")
        #expect(AppState.courseID(from: url("https://canvas.upenn.edu/calendar?include_contexts=course_99,course_100")) == "99")
    }

    @Test("non-course URLs stay unresolved rather than guessing")
    func unresolvableLinks() {
        #expect(AppState.courseID(from: url("https://canvas.upenn.edu/calendar_events/11223")) == nil)
        #expect(AppState.courseID(from: url("https://canvas.upenn.edu/calendar?include_contexts=user_5")) == nil)
        // A non-numeric segment after /courses/ is a route, not an id.
        #expect(AppState.courseID(from: url("https://canvas.upenn.edu/courses/new")) == nil)
    }

    /// A rename must not change how a class is identified: selection, deletion,
    /// grades and reminders all key on the code, so only the label may move.
    ///
    /// `AppState` persists to the process-wide `UserDefaults`, so this restores
    /// what it touched — otherwise a hidden course leaks into suites that assume
    /// the default "everything selected".
    @Test("renaming a class changes its label but not its identity")
    func renameIsCosmetic() {
        let state = AppState()
        // Normalize on the way in as well as out: these defaults are
        // process-wide and survive between runs, so an interrupted earlier run
        // would otherwise leave the course hidden and fail this on entry.
        state.setCourse("CIS 3200", selected: true)
        defer {
            state.renameCourse("CIS 3200", to: "")
            state.setCourse("CIS 3200", selected: true)
        }

        state.renameCourse("CIS 3200", to: "Algorithms")
        #expect(state.courseDisplayName("CIS 3200") == "Algorithms")
        #expect(state.hasCustomName("CIS 3200"))
        #expect(state.isCourseSelected("CIS 3200"))

        state.setCourse("CIS 3200", selected: false)
        #expect(!state.isCourseSelected("CIS 3200"))
        #expect(state.courseDisplayName("CIS 3200") == "Algorithms")
    }

    @Test("clearing a rename falls back to the course code")
    func renameCanBeCleared() {
        let state = AppState()
        defer { state.renameCourse("MATH 1400", to: "") }

        state.renameCourse("MATH 1400", to: "Calc")
        #expect(state.courseDisplayName("MATH 1400") == "Calc")

        state.renameCourse("MATH 1400", to: "   ")
        #expect(state.courseDisplayName("MATH 1400") == "MATH 1400")
        #expect(!state.hasCustomName("MATH 1400"))
    }
}
