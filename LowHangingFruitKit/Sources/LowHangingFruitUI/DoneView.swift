import SwiftUI
import LowHangingFruitKit

/// "Done" tab — completed assignments styled as archived: greige surface, muted
/// grey spine, green check, strikethrough title. Tapping un-completes an item.
///
/// Leads with the week's count ("4 down this week") rather than ending on it:
/// with a whole semester of finished work below, the one number worth seeing
/// sat at the bottom of a long scroll. Only this week's cards show by
/// default; the rest of the semester waits behind a single "earlier this
/// semester" row that opens in place, so the tab reads as "this week's
/// progress" first and an archive second.
struct DoneView: View {
    let sections: [DashSection]
    let weeklyDone: Int
    let onUncomplete: (DashItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEarlier = false

    private var thisWeek: DashSection? { sections.first { $0.id == "doneWeek" } }
    private var earlier: DashSection? { sections.first { $0.id == "doneSemester" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)

            if let thisWeek {
                cards(for: thisWeek)
            }

            if let earlier {
                earlierToggle(count: earlier.items.count)

                if showsEarlier {
                    VStack(alignment: .leading, spacing: 10) {
                        cards(for: earlier)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if weeklyDone > 0 {
                Text("\(weeklyDone) down this week.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
                Text("nice pace.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            } else if !sections.isEmpty {
                // Completed work exists, it just wasn't finished this week —
                // don't claim "nothing done yet.".
                Text("nothing new this week.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
            } else {
                Text("nothing done yet.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
                Text("let's fix that.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            }
        }
        .padding(.top, sections.isEmpty ? 60 : 0)
    }

    private func cards(for section: DashSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(section.items) { item in
                DoneCardView(
                    item: item,
                    dayLabel: section.dayLabel?(item),
                    onTap: { onUncomplete(item) }
                )
                .transition(.opacity)
            }
        }
    }

    private func earlierToggle(count: Int) -> some View {
        Button {
            lhfHapticLight()
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                showsEarlier.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text("earlier this semester")
                    .font(.lhfMono(11, weight: .semibold))
                    .tracking(0.4)
                Text("\(count)")
                    .font(.lhfMono(11, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(showsEarlier ? 180 : 0))
            }
            .foregroundStyle(Color.smoothInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Capsule().fill(Color.smoothInk.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("earlier this semester, \(count) done")
        .accessibilityHint(showsEarlier ? "hides earlier work" : "shows earlier work")
    }
}

/// A completed card keeps its original deadline fill at reduced opacity.
struct DoneCardView: View {
    let item: DashItem
    let dayLabel: String?
    let onTap: () -> Void

    @Environment(\.courseNameOverrides) private var courseNameOverrides

    private let corner: CGFloat = 18

    var body: some View {
        Button {
            lhfHapticLight()
            onTap()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.assignment.displayCourse(overrides: courseNameOverrides).uppercased())
                        .font(.lhfMono(9.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(smoothTaskTextAccent(item.due))
                    Text(item.assignment.title)
                        .font(.lhfAssignmentTitle(20))
                        .foregroundStyle(Color.smoothInk)
                        .strikethrough(true, color: Color.smoothInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                if let dayLabel {
                    Text(dayLabel)
                        .font(.lhfMono(15, weight: .medium))
                        .foregroundStyle(Color.smoothInk)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(smoothTaskFill(item.due))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .opacity(0.55)
        }
        .buttonStyle(.plain)
    }
}
