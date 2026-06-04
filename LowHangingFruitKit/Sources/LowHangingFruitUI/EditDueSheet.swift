import SwiftUI
import LowHangingFruitKit

struct EditDueSheet: View {
    let assignment: Assignment
    @Binding var overrideDate: Date?
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Date

    init(assignment: Assignment, overrideDate: Binding<Date?>) {
        self.assignment = assignment
        self._overrideDate = overrideDate
        self._draft = State(initialValue: overrideDate.wrappedValue ?? assignment.dueAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assignment.title)
                            .font(.geist(18, weight: .semibold))
                        Text(assignment.course)
                            .font(.geist(13))
                            .foregroundStyle(.secondary)
                    }

                    if overrideDate != nil, let original = assignment.dueAt {
                        Text("Originally due \(Self.format(original))")
                            .font(.geist(12))
                            .foregroundStyle(.secondary)
                    }

                    DatePicker("Due", selection: $draft, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)

                    if overrideDate != nil {
                        Button(role: .destructive) {
                            overrideDate = nil
                            dismiss()
                        } label: {
                            Label("Reset to original due date", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Edit Due Date")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        overrideDate = draft
                        dismiss()
                    }
                    .font(.geist(14, weight: .semibold))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return f.string(from: date)
    }
}
