import SwiftUI
import LowHangingFruitKit

/// The ambassador's one stat on the dashboard, the one line under the title
/// (Marco, 2026-11-22: "we'll just start with that", then "one line, nicer, no
/// card", then "remove the date entirely ... end that line with so far"). The
/// date line's face and ink, in the date line's place. Shown only to a signed-in
/// ambassador once the server sends the count.
struct AmbassadorStatsLine: View {
    let schoolLabel: String
    let users: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "medal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.smoothMarigold)
            Text("\(users) users at \(schoolLabel) so far")
                .font(.lhfMono(14, weight: .medium))
                .foregroundStyle(Color.smoothMuted)
        }
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
