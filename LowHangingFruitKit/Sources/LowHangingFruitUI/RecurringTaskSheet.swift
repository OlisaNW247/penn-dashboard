import SwiftUI

struct RecurringTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState

    @State private var title = "Weekly discussion post"
    @State private var course = ""
    @State private var weekday = 1
    @State private var dueTime = Calendar.current.date(from: DateComponents(hour: 23, minute: 59)) ?? Date()
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 4, to: Date()) ?? Date()

    private let weekdays = [
        (1, "Sunday"),
        (2, "Monday"),
        (3, "Tuesday"),
        (4, "Wednesday"),
        (5, "Thursday"),
        (6, "Friday"),
        (7, "Saturday"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("recurring assignment")
                .font(.title3.weight(.semibold))

            TextField("title", text: $title)
                .textFieldStyle(.roundedBorder)

            TextField("course", text: $course)
                .textFieldStyle(.roundedBorder)

            Picker("due day", selection: $weekday) {
                ForEach(weekdays, id: \.0) { day in
                    Text(day.1).tag(day.0)
                }
            }

            DatePicker("due time", selection: $dueTime, displayedComponents: .hourAndMinute)
            DatePicker("start", selection: $startDate, displayedComponents: .date)
            Toggle("end date", isOn: $hasEndDate)
            if hasEndDate {
                DatePicker("ends", selection: $endDate, displayedComponents: .date)
            }

            HStack {
                Spacer()
                Button("cancel") { dismiss() }
                Button("add") {
                    addTask()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || course.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
        .lhfSheetTheme()
    }

    private func addTask() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: dueTime)
        state.addRecurringTask(RecurringTask(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            course: course.trimmingCharacters(in: .whitespacesAndNewlines),
            weekday: weekday,
            hour: components.hour ?? 23,
            minute: components.minute ?? 59,
            startDate: startDate,
            endDate: hasEndDate ? endDate : nil,
            origin: .manual
        ))
        dismiss()
    }
}
