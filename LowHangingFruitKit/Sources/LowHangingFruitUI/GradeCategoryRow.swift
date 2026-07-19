import SwiftUI
import LowHangingFruitKit

/// One category row inside an expanded `GradeCourseCardView`: name, effective
/// weight (or "\u{2014}" in points mode), earned/possible on scored work, the
/// weight's source badge, and the always-available manual-weight edit
/// affordance (docs/grades.md §6 — manual editing is the only fallback when
/// Canvas has no weights, so it's never gated behind a mode check).
struct GradeCategoryRow: View {
    @ObservedObject var store: GradeWatcherStore
    let courseID: String
    let category: GradeBreakdown.CategoryResult

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.name)
                        .font(.lhfSans(13, weight: .medium))
                        .foregroundStyle(Color.v2Ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(formatPoints(category.earned))/\(formatPoints(category.possibleScored)) pts scored \u{00b7} \(category.scoredCount)/\(category.totalCount) items")
                        .font(.lhfSans(10.5))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(weightText)
                        .font(.lhfSans(13, weight: .semibold))
                        .foregroundStyle(Color.v2Ink)
                    if let source = category.weightSource {
                        GradeSourceBadge(source: source)
                    }
                }
            }

            editingControls
        }
        .accessibilityElement(children: .combine)
    }

    private var weightText: String {
        category.effectiveWeight.map { "\(formatPoints($0))%" } ?? "\u{2014}"
    }

    @ViewBuilder
    private var editingControls: some View {
        if isEditing {
            HStack(spacing: 8) {
                TextField("Weight %", text: $editText)
#if os(iOS)
                    .keyboardType(.decimalPad)
#endif
                    .font(.lhfSans(12))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                    .focused($isFieldFocused)
                    .accessibilityLabel("Manual weight percent for \(category.name)")

                Button(action: save) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.v2SpineGreen)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save weight")

                Button {
                    isEditing = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.v2RingSub)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel editing weight")
            }
        } else {
            HStack(spacing: 14) {
                Button {
                    editText = category.effectiveWeight.map(formatPoints) ?? ""
                    isEditing = true
                    isFieldFocused = true
                } label: {
                    Label("Edit weight", systemImage: "pencil")
                        .font(.lhfSans(10.5, weight: .medium))
                        .foregroundStyle(Color.v2SpineBlue)
                }
                .buttonStyle(.plain)

                if category.weightSource == .manual {
                    Button {
                        store.setManualWeight(courseID: courseID, categoryID: category.id, weight: nil)
                    } label: {
                        Label("Reset to Canvas", systemImage: "arrow.uturn.backward")
                            .font(.lhfSans(10.5, weight: .medium))
                            .foregroundStyle(Color.v2RingSub)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func save() {
        defer { isEditing = false }
        guard let value = Double(editText), value >= 0 else { return }
        store.setManualWeight(courseID: courseID, categoryID: category.id, weight: value)
    }
}
