import SwiftUI
import LowHangingFruitKit

/// The class field on the add sheets: a pick from the student's own class
/// list rather than free text. The free-text field was marked optional, so
/// it was easy to skip and put the class in the title instead, which left
/// the work filed under no class at all (see
/// `RecurringTask.adoptingCourse`). Picking also guarantees the key matches
/// what selection, reminders and the class filter use — a typed "cis 3990"
/// is a different key from the feed's `CIS 3990`.
///
/// A bare system `Picker` buried the whole class list behind one tap and
/// gave every class the same look, so scanning six classes meant opening
/// the wheel and reading names with no other cue. This is a wrapping grid
/// of chips instead — every class visible at once, each tinted with its own
/// stable accent (`courseAccent(for:)`) so the same class reads the same
/// color here as it will once it has cards on the dashboard.
struct CoursePicker: View {
    @Binding var course: String
    /// One-off assignments may belong to no class; a recurring task may not.
    let allowsNone: Bool

    @EnvironmentObject private var state: AppState

    private var codes: [String] { state.visibleCourseCodes() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("class")
                .font(.lhfMono(11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.smoothMuted)

            if codes.isEmpty {
                Text(allowsNone ? "no classes yet" : "add a class first")
                    .font(.lhfSecondary(13))
                    .foregroundStyle(Color.smoothMuted)
            } else {
                CoursePickerFlowLayout(spacing: 8) {
                    if allowsNone {
                        chip(code: "", label: "none", accent: Color.smoothMuted, ink: Color.smoothMuted)
                    }
                    ForEach(codes, id: \.self) { code in
                        chip(code: code, label: state.courseDisplayName(code), accent: courseAccent(for: code), ink: courseAccentInk(for: code))
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: course)
        .padding(.vertical, 4)
    }

    private func chip(code: String, label: String, accent: Color, ink: Color) -> some View {
        let isSelected = course == code
        return Button {
            course = code
        } label: {
            Text(label.uppercased())
                .font(.lhfMono(12, weight: .semibold))
                .tracking(0.4)
                .lineLimit(1)
                // A selected chip is a solid pastel, so its label is the fixed dark
                // ink in both modes (the pastels don't change after sunset);
                // an unselected chip sits on the page, so it takes the accent's ink.
                .foregroundStyle(isSelected ? Color(hex: 0x1B1714) : ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(isSelected ? accent : accent.opacity(0.14))
                )
                .overlay(
                    Capsule().stroke(accent.opacity(isSelected ? 0 : 0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(label)
    }
}

/// A left-to-right, top-to-bottom wrap of chips: each row fills with as many
/// chips as fit the available width, then starts a new row, so the class
/// list reads like text rather than truncating or scrolling sideways.
/// `HStack`/`ForEach` can't do this (it never wraps); `Layout` can (iOS
/// 16+/macOS 13+, both below this package's iOS 17/macOS 14 floor).
struct CoursePickerFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x - bounds.minX + size.width > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
