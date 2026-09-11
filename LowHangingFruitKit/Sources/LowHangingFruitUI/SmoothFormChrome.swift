import SwiftUI

/// A compact identity block for the two utility pages. It uses the same hard
/// ink line and vivid color family as assignment cards, but stays flatter and
/// quieter so controls remain the focus.
struct SmoothFormHeader: View {
    let title: String
    let accent: Color
    let spark: Color

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.lhfSerif(32))
                .foregroundStyle(Color.smoothInk)

            Spacer(minLength: 12)

            ZStack {
                Circle()
                    .fill(spark)
                    .frame(width: 22, height: 22)
                    .offset(x: -24, y: 20)
                Circle()
                    .fill(Color.smoothLemon)
                    .frame(width: 12, height: 12)
                    .offset(x: 26, y: -21)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent.opacity(0.22))
                    .frame(width: 58, height: 42)
                    .rotationEffect(.degrees(-8))
                Capsule()
                    .fill(accent)
                    .frame(width: 42, height: 13)
                    .rotationEffect(.degrees(18))
            }
            .frame(width: 78, height: 72)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SmoothSectionHeader: View {
    let title: String
    let accent: Color

    init(_ title: String, accent: Color) {
        self.title = title
        self.accent = accent
    }

    var body: some View {
        Text(title)
            .font(.lhfSans(12, weight: .semibold))
            .tracking(0.65)
            .foregroundStyle(accent)
            .textCase(nil)
    }
}

private struct SmoothFormChrome: ViewModifier {
    let accent: Color

    func body(content: Content) -> some View {
        content
            .tint(accent)
            .environment(\.defaultMinListRowHeight, 48)
            .listRowSeparatorTint(Color.smoothRule.opacity(0.65))
#if os(iOS)
            .listSectionSpacing(.custom(18))
#endif
    }
}

extension View {
    func smoothFormChrome(accent: Color) -> some View {
        modifier(SmoothFormChrome(accent: accent))
    }

    func smoothSectionBackground(_ color: Color) -> some View {
        listRowBackground(color.opacity(0.13))
    }
}
