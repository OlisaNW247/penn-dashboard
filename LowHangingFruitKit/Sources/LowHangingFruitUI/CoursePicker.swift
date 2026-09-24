import SwiftUI
import LowHangingFruitKit

/// The class field on the add sheets: a pick from the student's own class
/// list rather than free text. The free-text field was marked optional, so
/// it was easy to skip and put the class in the title instead, which left
/// the work filed under no class at all (see
/// `RecurringTask.adoptingCourse`). Picking also guarantees the key matches
/// what selection, reminders and the class filter use — a typed "cis 3990"
/// is a different key from the feed's `CIS 3990`.
struct CoursePicker: View {
    @Binding var course: String
    /// One-off assignments may belong to no class; a recurring task may not.
    let allowsNone: Bool

    @EnvironmentObject private var state: AppState

    var body: some View {
        Picker("class", selection: $course) {
            if allowsNone || course.isEmpty {
                Text(allowsNone ? "none" : "choose").tag("")
            }
            ForEach(state.visibleCourseCodes(), id: \.self) { code in
                Text(state.courseDisplayName(code)).tag(code)
            }
        }
    }
}
