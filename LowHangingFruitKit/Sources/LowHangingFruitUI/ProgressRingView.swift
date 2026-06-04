import SwiftUI

/// Circular weekly-completion ring: green filled arc over a greige track, with
/// "done / total" and a caption in the center. The fill animates when the
/// ratio changes (e.g. an item is completed).
struct ProgressRingView: View {
    let done: Int
    let total: Int

    var diameter: CGFloat = 58
    var lineWidth: CGFloat = 6

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(done) / CGFloat(total)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.v2RingTrack, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.v2SpineGreen,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction)

            VStack(spacing: 0) {
                Text("\(done)/\(total)")
                    .font(.lhfSerif(16))
                    .foregroundStyle(Color.v2Ink)
                    .monospacedDigit()
                Text("done")
                    .font(.lhfSans(7))
                    .foregroundStyle(Color.v2RingSub)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(done) of \(total) done this week")
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 24) {
        ProgressRingView(done: 4, total: 10)
        ProgressRingView(done: 0, total: 8)
        ProgressRingView(done: 7, total: 7)
    }
    .padding(40)
    .background(Color.v2Bg)
}
#endif
