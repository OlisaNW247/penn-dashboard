import SwiftUI

/// Smooth's assistant mark: a vivid color wheel carrying a friendly rounded
/// eight-point star. Built in SwiftUI so it stays crisp from composer size to
/// the dashboard's floating action button without a raster outline.
struct SmoothStarMark: View {
    var size: CGFloat = 58

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            .smoothTomato,
                            .smoothMarigold,
                            .smoothTeal,
                            .smoothCobalt,
                            .smoothGrape,
                            .smoothTomato,
                        ],
                        center: .center
                    )
                )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.smoothPaper.opacity(0.24), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: size * 0.58
                    )
                )

            ForEach(0..<8, id: \.self) { spoke in
                Capsule(style: .continuous)
                    .fill(Color.smoothPaper.opacity(0.94))
                    .frame(width: size * 0.105, height: size * 0.32)
                    .offset(y: -size * 0.13)
                    .rotationEffect(.degrees(Double(spoke) * 45))
            }

            Circle()
                .fill(Color.smoothPaper)
                .frame(width: size * 0.18, height: size * 0.18)
        }
        .frame(width: size, height: size)
        .shadow(color: Color.smoothGrapeInk.opacity(0.20), radius: size * 0.10, y: size * 0.04)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    SmoothStarMark()
        .padding(24)
        .background(Color.smoothPaper)
}
#endif
