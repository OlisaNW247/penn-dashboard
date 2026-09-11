import SwiftUI

/// Neutral section chip. Deadline color belongs to assignment cards only.
struct SectionHeader: View {
    let label: String

    var body: some View {
        Text(label.uppercased())
            .font(.lhfSans(11, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(Color.smoothInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.smoothPaper, in: Capsule())
    }
}

/// One active-timeline section: header + its assignment cards.
struct TimelineSectionView: View {
    let section: DashSection
    let onComplete: (DashItem) -> Void
    let onEdit: (DashItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(label: section.label)

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
