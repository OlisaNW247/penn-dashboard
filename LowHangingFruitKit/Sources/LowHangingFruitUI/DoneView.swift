import SwiftUI
import LowHangingFruitKit

/// "Done" tab — completed assignments styled as archived: greige surface, muted
/// grey spine, green check, strikethrough title. Tapping un-completes an item.
struct DoneView: View {
    let sections: [DashSection]
    let weeklyDone: Int
    let onUncomplete: (DashItem) -> Void

    var body: some View {
        if sections.isEmpty {
            footer
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(label: section.label,
                                      labelColor: section.labelColor,
                                      count: section.items.count)
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

                footer
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 3) {
            if weeklyDone > 0 {
                Text("\(weeklyDone) down this week.")
                    .font(.lhfSerif(15))
                    .foregroundStyle(Color.v2DateText)
                Text("nice pace.")
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.v2RingSub)
            } else {
                Text("nothing done yet.")
                    .font(.lhfSerif(15))
                    .foregroundStyle(Color.v2DateText)
                Text("let's fix that.")
                    .font(.lhfSans(10))
                    .foregroundStyle(Color.v2RingSub)
            }
        }
    }
}

/// A single completed (archived) card.
struct DoneCardView: View {
    let item: DashItem
    let dayLabel: String?
    let onTap: () -> Void

    private let corner: CGFloat = 13

    var body: some View {
        Button {
            lhfHapticLight()
            onTap()
        } label: {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.v2DoneSpine)
                .frame(width: 6)

            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.v2SpineGreen)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.assignment.course.uppercased())
                        .font(.lhfSans(9, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(Color.v2DoneCourse)
                    Text(item.assignment.title)
                        .font(.lhfSans(14, weight: .medium))
                        .foregroundStyle(Color.v2DoneTitle)
                        .strikethrough(true, color: Color.v2DoneTitle.opacity(0.7))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if let dayLabel {
                    Text(dayLabel)
                        .font(.lhfSans(11, weight: .medium))
                        .foregroundStyle(Color.v2DoneCourse)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.v2DoneCard)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
