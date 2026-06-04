import SwiftUI
import LowHangingFruitKit

/// An active (incomplete) assignment card: white surface, 13pt corners, soft
/// shadow, and a 6pt urgency-colored spine on the left edge whose corners are
/// clipped to match the card. Single tap completes (with a deferred exit
/// animation so the data mutation doesn't cause mid-animation jank); double
/// tap opens the due-date editor.
struct AssignmentCardView: View {
    let item: DashItem
    /// Called once the exit animation has finished.
    let onComplete: () -> Void
    let onEdit: () -> Void

    @State private var exitOpacity: Double = 1
    @State private var exitOffset: CGFloat = 0

    private let corner: CGFloat = 13

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { tl in
            let now = tl.date
            let state = item.state(now: now)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(state.spineColor)
                    .frame(width: 6)

                content(state: state, now: now)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
            .background(Color.v2Card)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
            .opacity(exitOpacity)
            .offset(y: exitOffset)
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // Plain tap (no drag gesture) so the ScrollView can scroll on touch.
            .onTapGesture { triggerComplete(state: state) }
        }
    }

    private func content(state: DueState, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.assignment.course.uppercased())
                    .font(.lhfSans(9, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.v2CourseCode)

                Text(item.assignment.title)
                    .font(.lhfSans(14, weight: .medium))
                    .foregroundStyle(Color.v2Ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(dueText(item.due, now: now))
                    .font(.lhfSans(11, weight: .medium))
                    .foregroundStyle(state.dueTextColor)
                if item.dueOverride != nil {
                    Text("manually adjusted")
                        .font(.lhfSans(8.5))
                        .foregroundStyle(Color.v2CourseCode)
                }
            }

            // Manual due-date adjust. Its own tap target so it doesn't trigger
            // the card's tap-to-complete.
            Button { onEdit() } label: {
                Image(systemName: "calendar")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.v2CourseCode)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Adjust due date")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func triggerComplete(state: DueState) {
        lhfHaptic(for: state)
        withAnimation(.easeIn(duration: 0.28)) {
            exitOpacity = 0
            exitOffset = -16
        }
        // Defer the data mutation until the exit animation finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            onComplete()
        }
    }
}

#if DEBUG
#Preview("Active cards") {
    ScrollView {
        VStack(spacing: 12) {
            ForEach(SampleData.items().filter { !$0.isCompleted }) { item in
                AssignmentCardView(item: item, onComplete: {}, onEdit: {})
            }
        }
        .padding(16)
    }
    .background(Color.v2Bg)
}
#endif
