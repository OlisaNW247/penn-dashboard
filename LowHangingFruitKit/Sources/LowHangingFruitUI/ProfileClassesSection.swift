import SwiftUI
import LowHangingFruitKit

/// The class list: every course the app knows about, each with an on/off
/// toggle, a rename, and a delete that can be undone.
///
/// **This moved verbatim out of `SettingsPage` in v4** (it was that file's
/// `classesSection`, `classRow`, `beginRename` and `deletedClassesRow`, plus
/// the rename alert that used to hang off the page's `Form`). Nothing about
/// the behaviour changed in the move; the reason for the move is that a class
/// list is not a preference. "Which classes am I taking" is the first question
/// a student has about this app, and it was living three taps down behind a
/// gear icon next to the appearance picker.
///
/// The semantics that matter, unchanged from Settings and worth restating
/// because they are easy to break:
///
/// - **Off is not deleted.** Off (`setCourse(_:selected:)`) hides a class from
///   the dashboard and from reminders but leaves it in this list with its
///   toggle down. Deleted (`deleteCourse`) takes it out of the list too. Both
///   are purely local filters — there is no course on Canvas's end to delete —
///   so both are fully reversible.
/// - **Renaming is cosmetic only.** `renameCourse` writes a display name and
///   nothing else. Selection, reminders, grades, Canvas course-id resolution
///   and deduplication all still key on `course` — the code Canvas gave us —
///   which is why every action below is passed `course` and never
///   `state.courseDisplayName(course)`. Get that backwards and a rename
///   silently detaches a class from its own assignments. Clearing the field
///   restores the code.
///
/// ## For whoever fills in the rest of v4
///
/// This is the one Profile section that ships with real content rather than a
/// stub. Add-a-class (a course that hasn't posted anything to Canvas yet, so it
/// contributes no feed items and therefore doesn't appear here) belongs in this
/// section, next to the empty state below, which currently just explains the
/// gap. Per-course *preferences* do not belong here — they're
/// `ProfileNotificationsSection`'s.
struct ProfileClassesSection: View {
    @EnvironmentObject var state: AppState

    /// Non-nil while the rename prompt is up; holds the course *code* being
    /// renamed (never the display name, which is what's being edited).
    @State private var renamingCourse: String?
    @State private var renameDraft = ""

    var body: some View {
        Section {
            let courses = state.visibleCourseCodes()
            let deletedCourses = state.deletedCourseCodes()

            if courses.isEmpty && deletedCourses.isEmpty {
                emptyState
            } else {
                ForEach(courses, id: \.self) { course in
                    classRow(course)
                }

                if !deletedCourses.isEmpty {
                    deletedClassesRow(deletedCourses)
                }
            }
        } header: {
            Text("classes")
        } footer: {
            Text("turning a class off hides its assignments and reminders. swipe to rename or delete. renaming only changes the label.")
        }
        // The alert used to live on `SettingsPage`'s whole `Form`, because the
        // state driving it lived on the page. It follows the state here. It is
        // attached to the `Section` rather than to any one row on purpose: a
        // row-attached alert dies with its row, and the rename prompt has to
        // outlive a list that re-sorts underneath it.
        .alert("Rename class", isPresented: Binding(
            get: { renamingCourse != nil },
            set: { if !$0 { renamingCourse = nil } }
        )) {
            TextField("class name", text: $renameDraft)
            Button("save") {
                if let course = renamingCourse {
                    state.renameCourse(course, to: renameDraft)
                }
                renamingCourse = nil
            }
            Button("cancel", role: .cancel) { renamingCourse = nil }
        } message: {
            Text("shown instead of \(renamingCourse ?? "the class code"). leave it empty to reset.")
        }
    }

    /// In Settings this section simply vanished when there were no classes,
    /// which was fine for a section buried in a list of other sections. It is
    /// not fine for the headline content of a whole tab: an empty Profile reads
    /// as a broken Profile. And "no classes" is the *expected* state in week
    /// one, when courses exist on Canvas but haven't posted an assignment yet —
    /// the class list is derived from feed items, so a quiet course is an
    /// invisible course. Saying that out loud is the difference between a bug
    /// report and a shrug.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("no classes yet")
                .font(.lhfSans(15, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
            Text("classes appear once canvas posts something with a due date. add one below if yours hasn\u{2019}t yet.")
                .font(.lhfSans(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// One class: the on/off toggle, plus rename and delete. The row shows the
    /// user's own name when they've set one, but every action still keys on
    /// `course` (the code Canvas gave us) so a rename can't detach the class
    /// from its assignments or its grades.
    private func classRow(_ course: String) -> some View {
        Toggle(state.courseDisplayName(course), isOn: Binding(
            get: { state.isCourseSelected(course) },
            set: { state.setCourse(course, selected: $0) }
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                state.deleteCourse(course)
            } label: {
                Label("delete", systemImage: "trash")
            }
            Button {
                beginRename(course)
            } label: {
                Label("rename", systemImage: "pencil")
            }
            .tint(Color.v2DateText)
        }
        .contextMenu {
            Button {
                beginRename(course)
            } label: {
                Label("rename class", systemImage: "pencil")
            }
            if state.hasCustomName(course) {
                Button {
                    state.renameCourse(course, to: "")
                } label: {
                    Label("reset to \(course)", systemImage: "arrow.uturn.backward")
                }
            }
            Button(role: .destructive) {
                state.deleteCourse(course)
            } label: {
                Label("delete class", systemImage: "trash")
            }
        }
    }

    private func beginRename(_ course: String) {
        renameDraft = state.courseDisplayName(course)
        renamingCourse = course
    }

    private func deletedClassesRow(_ deletedCourses: [String]) -> some View {
        DisclosureGroup {
            ForEach(deletedCourses, id: \.self) { course in
                HStack {
                    Text(state.courseDisplayName(course))
                        .font(.lhfSans(14))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("restore") {
                        state.restoreCourse(course)
                    }
                    .font(.lhfSans(13))
                }
            }
        } label: {
            Label("deleted (\(deletedCourses.count))", systemImage: "trash")
                .font(.lhfSans(13))
                .foregroundStyle(.secondary)
        }
    }
}
