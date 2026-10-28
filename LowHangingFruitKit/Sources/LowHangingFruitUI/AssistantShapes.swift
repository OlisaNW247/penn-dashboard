import SwiftUI

/// Quiet, noninteractive artwork for the empty chat. It yields to the keyboard
/// and conversation, so it never sits behind an answer or competes with input.
struct AssistantShapes: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scale = min(width / 390, height / 500, 1.2)
            ZStack {
                wave
                    .stroke(Color.smoothCobalt.opacity(0.65), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 110 * scale, height: 45 * scale)
                    .rotationEffect(.degrees(-16))
                    .position(x: width * 0.22, y: height * 0.13)

                Ellipse()
                    .stroke(Color.smoothTeal.opacity(0.5), lineWidth: 9 * scale)
                    .frame(width: 122 * scale, height: 75 * scale)
                    .rotationEffect(.degrees(-35))
                    .position(x: width * 0.76, y: height * 0.3)

                RoundedRectangle(cornerRadius: 25 * scale)
                    .fill(Color.smoothTomato.opacity(0.3))
                    .frame(width: 90 * scale, height: 105 * scale)
                    .rotationEffect(.degrees(24))
                    .position(x: width * 0.23, y: height * 0.51)

                Circle()
                    .trim(from: 0.05, to: 0.68)
                    .stroke(Color.smoothMarigold.opacity(0.65), style: StrokeStyle(lineWidth: 12 * scale, lineCap: .round))
                    .frame(width: 84 * scale, height: 84 * scale)
                    .rotationEffect(.degrees(-38))
                    .position(x: width * 0.73, y: height * 0.7)

                HStack(spacing: 8 * scale) {
                    ForEach(0..<3) { _ in
                        Capsule().fill(Color.smoothGrape.opacity(0.4))
                            .frame(width: 12 * scale, height: 40 * scale)
                    }
                }
                .rotationEffect(.degrees(30))
                .position(x: width * 0.28, y: height * 0.88)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var wave: Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 23))
            path.addCurve(to: CGPoint(x: 55, y: 23), control1: CGPoint(x: 18, y: -5), control2: CGPoint(x: 37, y: 51))
            path.addCurve(to: CGPoint(x: 110, y: 23), control1: CGPoint(x: 73, y: -5), control2: CGPoint(x: 92, y: 51))
        }
    }
}
