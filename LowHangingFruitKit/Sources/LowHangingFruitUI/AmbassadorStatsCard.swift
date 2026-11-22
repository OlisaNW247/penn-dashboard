import SwiftUI
import LowHangingFruitKit

/// The ambassador's one stat on the dashboard: how many people at their
/// school have the app (Marco, 2026-11-22: "we'll just start with that").
/// Shown only to a signed-in ambassador once the server sends the count.
struct AmbassadorStatsCard: View {
    let schoolLabel: String
    let users: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("stats")
                .font(.lhfSecondary(12))
                .foregroundStyle(Color.v2DateText)
            HStack(alignment: .firstTextBaseline) {
                Text("users at \(schoolLabel)")
                    .font(.lhfSecondary(15))
                    .foregroundStyle(Color.smoothInk)
                Spacer()
                Text("\(users)")
                    .font(.lhfMono(17, weight: .semibold))
                    .foregroundStyle(Color.smoothInk)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.smoothSurface))
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

/// A label and "n of target" on one line with a thin bar under it. The page's
/// downloads goal and the posters sheet's goal share it.
struct AmbassadorGoalLine: View {
    let label: String
    let count: Int
    let target: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer()
                Text(AmbassadorGoals.caption(count: count, target: target))
                    .font(.lhfMono(15, weight: .semibold))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.smoothSurface)
                    Capsule()
                        .fill(Color.smoothTeal)
                        .frame(width: proxy.size.width * AmbassadorGoals.progress(count: count, target: target))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
    }
}
