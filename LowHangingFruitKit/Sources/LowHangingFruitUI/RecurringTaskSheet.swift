import SwiftUI

/// Profile → "add recurring task". Built as the same grouped `Form` as
/// `AddAssignmentSheet` so the two ways of adding work look like one
/// family; it used to be a fixed 420pt-wide `VStack` of bare pickers that
/// read as a Mac dialog on a phone. The weekday is a row of chips rather
/// than a menu picker because it is the one choice that defines the task,
/// and seeing all seven at once makes it a single tap.
struct RecurringTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState

    // No prefilled title: a stock "Weekly discussion post" had to be
    // deleted before typing, and was added verbatim when it wasn't.
    @State private var title = ""
    @State private var course = ""
    @State private var weekday = Calendar.current.component(.weekday, from: Date())
    @State private var dueTime = Calendar.current.date(from: DateComponents(hour: 23, minute: 59)) ?? Date()
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Calendar.current.date(byAdding: .month, value: 4, to: Date()) ?? Date()

    private var canAdd: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !course.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("title", text: $title)
                    CoursePicker(course: $course, allowsNone: false)
                }
                .smoothSectionBackground(.smoothLemon)

                Section {
                    weekdayChips
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    DatePicker("due", selection: $dueTime, displayedComponents: .hourAndMinute)
                } header: {
                    SmoothSectionHeader("every", accent: .smoothCobalt)
                }
                .smoothSectionBackground(.smoothTeal)

                Section {
                    DatePicker("starts", selection: $startDate, displayedComponents: .date)
                    Toggle("ends", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("on", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }
                .smoothSectionBackground(.smoothGrape)
            }
            .formStyle(.grouped)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothTeal)
            .navigationTitle("weekly task")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("add") { addTask() }.disabled(!canAdd)
                }
            }
        }
        .lhfSheetTheme()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .frame(minWidth: 360, minHeight: 420)
    }

    /// `veryShortWeekdaySymbols` is Sunday-first in every locale, which is
    /// exactly `Calendar`'s weekday numbering (1 = Sunday), so index + 1 is
    /// the stored value regardless of the locale's first day of the week.
    private var weekdayChips: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        let names = Calendar.current.weekdaySymbols
        return HStack(spacing: 6) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                let day = index + 1
                let selected = day == weekday
                Button {
                    weekday = day
                } label: {
                    Text(symbol.lowercased())
                        .font(.lhfMono(13, weight: .semibold))
                        .foregroundStyle(selected ? Color.smoothPaper : Color.smoothInk)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            Circle().fill(selected ? Color.smoothTeal : Color.smoothInk.opacity(0.06))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[index])
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
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
            // Keep the persisted schedule valid even if the start date was
            // moved past an end date that had already been selected.
            endDate: hasEndDate ? max(endDate, startDate) : nil,
            origin: .manual
        ))
        dismiss()
    }
}
