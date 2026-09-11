import SwiftUI

/// A compact identity block for the two utility pages. It uses the same hard
/// ink line and vivid color family as assignment cards, but stays flatter and
/// quieter so controls remain the focus.
struct SmoothFormHeader: View {
    let title: String
    let symbol: String
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
                    .frame(width: 18, height: 18)
                    .offset(x: -25, y: 22)
                Circle()
                    .fill(Color.smoothLemon)
                    .frame(width: 10, height: 10)
                    .offset(x: 27, y: -24)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent)
                    .frame(width: 58, height: 58)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(Color.smoothInk)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.smoothInk, lineWidth: 2)
                    }
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
}
