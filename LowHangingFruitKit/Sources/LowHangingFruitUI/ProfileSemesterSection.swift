import SwiftUI
import LowHangingFruitKit

/// The semester card and the add-a-class entry point.
///
/// Two features share this file because they are two halves of one complaint:
/// *"I'm seeing notifications for last semester, and only one class shows up."*
/// Both symptoms come from the same place — the app's idea of "my classes" was
/// derived entirely from whatever the Canvas feed happened to be carrying at
/// that moment, with no lower bound on how old that could be and no way to say
/// "this class exists" before the feed agreed. Archiving fixes the first half.
/// Adding a class by hand fixes the second.
///
/// ## The signature is the contract
///
/// `ProfileView` composes this as `ProfileSemesterSection()` and is never
/// edited again: no init parameters, everything from the environment, `Section`s
/// rather than a `Form`. `AppState` and `NotificationScheduler` are the only two
/// environment objects guaranteed to be there.
///
/// ## What renders when
///
/// The rollover card renders **nothing at all** when there is no term boundary
/// to offer, which is the state for eleven months of the year — that is the
/// bargain that earns this section the top slot in Profile. The add-a-class row
/// renders always: a course the student is taking but Canvas hasn't posted for
/// is not a seasonal problem, and it is most acute in exactly the week the
/// rollover card is also up.
///
/// Add-a-class living here rather than in `ProfileClassesSection` is worth a
/// note, since that file's own comments propose the opposite. It is here
/// because both halves of the fix shipped together and this section owns the
/// term-boundary story; the class list next door stays untouched.
///
/// ## The one thing this must never do
///
/// Archive without being asked. Every path below that hides work goes through a
/// button, with the count of what will be hidden rendered next to it, and every
/// one of them is reversible from the "Archived" disclosure underneath. See
/// `AppState.archiveTerms`.
struct ProfileSemesterSection: View {
    @EnvironmentObject var state: AppState

    /// The class the student is typing. Held as raw text and normalised only on
    /// submit, so the field doesn't rewrite itself under the cursor.
    @State private var newCourse = ""
    /// Set when a submitted class name couldn't be parsed, so the student gets
    /// told rather than watching the field silently clear.
    @State private var addError: String?
    /// The hand-added class an assignment is being attached to.
    @State private var addingAssignmentTo: String?

    var body: some View {
        rolloverSection
        archivedSection
        addClassSection
    }

    // MARK: Rollover

    /// The offer. `EmptyView` when there's no boundary — see the type comment.
    @ViewBuilder
    private var rolloverSection: some View {
        if let offer = state.rolloverOffer {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("new semester?", systemImage: "calendar.badge.clock")
                        .font(.lhfSans(15, weight: .semibold))
                        .foregroundStyle(Color.v2Ink)

                    // The concrete count is the whole point of showing a card
                    // instead of just doing it. "Archive 47 items from Spring
                    // 2026" is a decision a student can actually make; "tidy up
                    // your old work" is a shrug with consequences.
                    Text("\(offer.currentTerm.displayName) has started, and " +
                         "\(offer.summary) \(offer.totalItemCount == 1 ? "is" : "are") still " +
                         "on your dashboard.")
                        .font(.lhfSans(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !offer.courseKeys.isEmpty {
                        Text(offer.courseKeys.map { state.courseDisplayName($0) }
                            .joined(separator: " \u{00B7} "))
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.v2SectionMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("nothing is deleted. it stays in done, just off the " +
                         "dashboard and out of reminders. you can undo it below.")
                        .font(.lhfSans(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)

                Button {
                    state.archiveTerms(Set(offer.terms))
                } label: {
                    Label("archive \(offer.summary)", systemImage: "archivebox")
                        .font(.lhfSans(14, weight: .semibold))
                }

                Button("not now") {
                    state.dismissRolloverOffer()
                }
                .font(.lhfSans(14))
                .foregroundStyle(.secondary)
            } header: {
                Text("semester")
            }
        }
    }

    // MARK: Archived — the way back

    /// Only rendered once something has actually been archived. This is the
    /// half that makes the card above safe to tap: nothing was deleted, so
    /// everything can come back.
    @ViewBuilder
    private var archivedSection: some View {
        if !state.archivedTerms.isEmpty {
            Section {
                ForEach(state.archivedTerms, id: \.code) { term in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(term.displayName)
                                .font(.lhfSans(14))
                                .foregroundStyle(Color.v2Ink)
                            Text("saved, still in done")
                                .font(.lhfSans(11))
                                .foregroundStyle(Color.v2SectionMuted)
                        }
                        Spacer()
                        Button("restore") {
                            state.unarchiveTerms([term])
                        }
                        .font(.lhfSans(13))
                    }
                }
            } header: {
                Text("prev semesters")
            } footer: {
                Text("restoring puts that work back on the dashboard and in reminders.")
            }
        }
    }

    // MARK: Add a class

    private var addClassSection: some View {
        Section {
            HStack {
                TextField("e.g. cis 1200", text: $newCourse)
                    .font(.lhfSans(14))
#if os(iOS)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
#endif
                    .onSubmit(submitCourse)
                Button("add", action: submitCourse)
                    .font(.lhfSans(14, weight: .semibold))
                    .disabled(AppState.normalizedCourseKey(newCourse) == nil)
            }

            if let addError {
                Text(addError)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2SpineRed)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(state.manuallyAddedCourseCodes(), id: \.self) { course in
                addedClassRow(course)
            }
        } header: {
            Text("add a class")
        } footer: {
            // Says the quiet part out loud, because "where are my other
            // classes" is the question this whole section exists to answer and
            // the honest answer is not obvious.
            Text("canvas only shows a class once it posts something. add it here and it appears now; the two merge when canvas catches up.")
        }
        // A sheet of its own rather than `AddAssignmentSheet`, for one reason:
        // that sheet asks for the course as free text, and the entire point of
        // this button is that the course is already known. Sending the student
        // to re-type the class they just tapped would also let them re-type it
        // *differently*, which is precisely how work ends up filed under a
        // course key nothing else in the app recognises.
        .sheet(item: Binding(
            get: { addingAssignmentTo.map(AddToCourse.init(course:)) },
            set: { addingAssignmentTo = $0?.course }
        )) { target in
            AddToAddedClassSheet(course: target.course) { title, due in
                state.addManualAssignment(
                    ManualAssignment(title: title, course: target.course, dueAt: due)
                )
            }
        }
    }

    /// `sheet(item:)` needs an `Identifiable`; the course key is the identity.
    private struct AddToCourse: Identifiable {
        let course: String
        var id: String { course }
    }

    private func addedClassRow(_ course: String) -> some View {
        HStack {
            Text(state.courseDisplayName(course))
                .font(.lhfSans(14))
                .foregroundStyle(Color.v2Ink)
            Spacer()
            Button {
                addingAssignmentTo = course
            } label: {
                Label("add assignment", systemImage: "plus.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("add an assignment to \(state.courseDisplayName(course))")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                state.removeAddedCourse(course)
            } label: {
                Label("remove", systemImage: "trash")
            }
        }
    }

    /// Normalises and files the typed class. Clears the field on success so the
    /// next one can be typed straight away; leaves it alone on failure so the
    /// student can see and fix what they wrote.
    private func submitCourse() {
        guard state.addCourse(newCourse) != nil else {
            addError = "\u{201C}\(newCourse.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D} " +
                       "doesn\u{2019}t look like a course code. Try a department and a number, like CIS 1200."
            return
        }
        newCourse = ""
        addError = nil
    }
}

/// Adds one manual assignment to a class whose course key is already settled.
///
/// Deliberately smaller than `AddAssignmentSheet`: no course field (the caller
/// knows it), and no weekly-repeat toggle (a recurring obligation is a
/// `RecurringTask`, which has its own sheet). What's left is the two things a
/// student actually has in mind when they tap "+" next to a class they just
/// added — what it is, and when it's due.
private struct AddToAddedClassSheet: View {
    @Environment(\.dismiss) private var dismiss

    let course: String
    let onAdd: (String, Date?) -> Void

    @State private var title = ""
    @State private var hasDueDate = true
    @State private var dueDate = Calendar.current
        .date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date()

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("title", text: $title)
                } header: {
                    Text(course)
                }

                Section {
                    Toggle("has a due date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("due", selection: $dueDate,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                } footer: {
                    Text(hasDueDate
                         ? "The sync never touches items you add yourself."
                         : "Undated items sit under \u{201C}Later\u{201D} until you give them a date.")
                }
            }
            .navigationTitle("new assignment")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("add") {
                        onAdd(trimmedTitle, hasDueDate ? dueDate : nil)
                        dismiss()
                    }
                    .disabled(trimmedTitle.isEmpty)
                }
            }
            .lhfSheetTheme()
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        Form { ProfileSemesterSection() }
            .environmentObject(AppState())
            .environmentObject(NotificationScheduler())
    }
}
#endif
