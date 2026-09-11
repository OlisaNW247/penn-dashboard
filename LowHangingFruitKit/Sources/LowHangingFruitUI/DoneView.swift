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
                        SectionHeader(label: section.label)
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
            } else if !sections.isEmpty {
                // Completed work exists (shown above), it just wasn't
                // finished this week — don't claim "nothing done yet.".
                Text("nothing new this week.")
                    .font(.lhfSerif(15))
                    .foregroundStyle(Color.v2DateText)
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
                        .foregroundStyle(Color.smoothInk.opacity(0.68))
                    Text(item.assignment.title)
                        .font(.lhfSerif(20))
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
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.smoothInk, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .opacity(0.55)
        }
        .buttonStyle(.plain)
    }
}
