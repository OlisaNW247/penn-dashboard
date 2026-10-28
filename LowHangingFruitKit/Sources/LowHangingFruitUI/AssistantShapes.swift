import SwiftUI

/// A compact decorative cluster in the empty chat's upper-right corner.
struct AssistantShapes: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.smoothTomato.opacity(0.4))
                .frame(width: 42, height: 52)
                .rotationEffect(.degrees(-20))
                .offset(x: -35, y: 12)

            Ellipse()
                .stroke(Color.smoothTeal.opacity(0.65), lineWidth: 6)
                .frame(width: 65, height: 40)
                .rotationEffect(.degrees(-35))
                .offset(x: 20, y: -18)

            Circle()
                .trim(from: 0.05, to: 0.68)
                .stroke(Color.smoothMarigold.opacity(0.75), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .frame(width: 38, height: 38)
                .rotationEffect(.degrees(-38))
                .offset(x: 34, y: 27)
        }
        .frame(width: 132, height: 94)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
