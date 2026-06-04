import SwiftUI

/// Header row shared by every timeline/done section: an uppercase label, a thin
/// rule filling the remaining width, and the item count on the far right.
struct SectionHeader: View {
    let label: String
    let labelColor: Color
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.lhfSans(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(labelColor)

            Rectangle()
                .fill(Color.v2Divider)
                .frame(height: 0.5)

            Text("\(count)")
                .font(.lhfSans(10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.v2SectionCount)
        }
    }
}

/// One active-timeline section: header + its assignment cards.
struct TimelineSectionView: View {
    let section: DashSection
    let onComplete: (DashItem) -> Void
    let onEdit: (DashItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(label: section.label,
                          labelColor: section.labelColor,
                          count: section.items.count)

            ForEach(section.items) { item in
                AssignmentCardView(
                    item: item,
                    onComplete: { onComplete(item) },
                    onEdit: { onEdit(item) }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
            }
        }
    }
}
