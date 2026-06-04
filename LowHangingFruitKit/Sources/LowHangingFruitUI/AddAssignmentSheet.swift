import SwiftUI

/// Lets the user add their own assignment — a one-off, or a weekly-recurring
/// item. User-created items are stored separately from scraped data, so a
/// Canvas/Gradescope sync never overwrites or removes them.
struct AddAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState

    @State private var title = ""
    @State private var course = ""
    @State private var dueDate = AddAssignmentSheet.defaultDue()
    @State private var repeatsWeekly = false

    private static func defaultDue() -> Date {
        Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date()
    }

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Course (optional)", text: $course)
                }

                Section {
                    DatePicker(repeatsWeekly ? "First due" : "Due",
                               selection: $dueDate,
                               displayedComponents: [.date, .hourAndMinute])
                    Toggle("Repeats weekly", isOn: $repeatsWeekly)
                } footer: {
                    if repeatsWeekly {
                        Text("Repeats every \(weekdayName(dueDate)) at \(timeString(dueDate)).")
                    } else {
                        Text("A one-time assignment. The sync never touches items you add.")
                    }
                }
            }
            .navigationTitle("New assignment")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func add() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = course.trimmingCharacters(in: .whitespacesAndNewlines)
        if repeatsWeekly {
            let comps = Calendar.current.dateComponents([.weekday, .hour, .minute], from: dueDate)
            state.addRecurringTask(RecurringTask(
                title: t,
                course: c,
                weekday: comps.weekday ?? 1,
                hour: comps.hour ?? 23,
                minute: comps.minute ?? 59,
                startDate: dueDate,
                endDate: nil,
                origin: .manual
            ))
        } else {
            state.addManualAssignment(ManualAssignment(title: t, course: c, dueAt: dueDate))
        }
        dismiss()
    }

    private func weekdayName(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
