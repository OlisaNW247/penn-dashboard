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
    /// The student confirmed removing their own task from an opened card.
    let onRemove: (DashItem) -> Void
    /// A swipe was accepted: write the completion down now, before the card
    /// animates away (`AssignmentCardView.onCommit`). Defaulted so a caller
    /// that does not pass one behaves as before.
    var onCommit: (DashItem) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(label: section.label)

            ForEach(section.items) { item in
                AssignmentCardView(
                    item: item,
                    onComplete: { onComplete(item) },
                    onCommit: { onCommit(item) },
                    onEdit: { onEdit(item) },
                    onRemove: { onRemove(item) },
                    isExamOverride: item.examStyleOverride
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
            }
        }
    }
}
