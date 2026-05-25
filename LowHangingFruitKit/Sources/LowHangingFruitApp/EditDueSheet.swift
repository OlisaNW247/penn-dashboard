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
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(assignment.title)
                        .font(.geist(18, weight: .semibold))
                    Text(assignment.course)
                        .font(.geist(13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                DatePicker("Due", selection: $draft, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .padding(.horizontal)

                if overrideDate != nil {
                    Button(role: .destructive) {
                        overrideDate = nil
                        dismiss()
                    } label: {
                        Label("Reset to original", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.top, 20)
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
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
