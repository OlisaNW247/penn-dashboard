import SwiftUI
import LowHangingFruitKit

/// An active (incomplete) assignment card: white surface, 13pt corners, soft
/// shadow, and a 6pt urgency-colored spine on the left edge. Tapping the body
/// completes the assignment (with a deferred exit animation); the calendar
/// button adjusts the due date. Both are real Buttons so the enclosing
/// ScrollView still scrolls on touch.
struct AssignmentCardView: View {
    let item: DashItem
    /// Called once the exit animation has finished.
    let onComplete: () -> Void
    let onEdit: () -> Void

    @State private var exitOpacity: Double = 1
    @State private var exitOffset: CGFloat = 0

    private let corner: CGFloat = 13

    var body: some View {
        let now = Date()
        let state = item.state(now: now)

        return HStack(spacing: 0) {
                Rectangle()
                    .fill(state.spineColor)
                    .frame(width: 6)

                Button { triggerComplete(state: state) } label: {
                    content(state: state, now: now)
                        .padding(.leading, 14)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { onEdit() } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.v2CourseCode)
                        .frame(width: 30, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help("Adjust due date")
            }
            .background(Color.v2Card)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
            .opacity(exitOpacity)
            .offset(y: exitOffset)
    }

    private func content(state: DueState, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.assignment.displayCourse.uppercased())
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
