import SwiftUI

/// Pill-shaped three-way segmented control. The active indicator slides
/// between positions via `matchedGeometryEffect`.
struct SegmentedToggle: View {
    @Binding var selection: DashFilter
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DashFilter.allCases) { filter in
                segment(filter)
            }
        }
        .padding(3)
        .background(Color.v2ToggleBg, in: Capsule())
    }

    private func segment(_ filter: DashFilter) -> some View {
        let isActive = selection == filter
        return Text(filter.rawValue)
            .font(.lhfSans(11, weight: .medium))
            .foregroundStyle(isActive ? Color.v2ToggleActiveTx : Color.v2ToggleInactive)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if isActive {
                    Capsule()
                        .fill(Color.v2ToggleActive)
                        .matchedGeometryEffect(id: "active", in: indicator)
                }
            }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selection = filter
                }
            }
            // This is the app's primary navigation control, and as a bare
            // `Text` + `onTapGesture` it announced as static text: VoiceOver
            // gave no hint it was tappable and no way to tell which tab was
            // selected. It is also the first control a reviewer running
            // VoiceOver reaches.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(filter.rawValue)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(isActive ? "" : "Shows \(filter.rawValue) assignments")
    }
}

#if DEBUG
private struct TogglePreview: View {
    @State private var sel: DashFilter = .thisWeek
    var body: some View {
        SegmentedToggle(selection: $sel)
            .padding(20)
            .background(Color.v2Bg)
    }
}
#Preview { TogglePreview() }
#endif
