import SwiftUI
import PennDashboardKit

struct AssignmentCardView: View {
    let assignment: Assignment
    let isCompleted: Bool
    let dueDateOverride: Date?
    let onToggleCompleted: () -> Void
    let onEditDue: () -> Void

    @State private var isPressed = false
    @State private var checkProgress: CGFloat = 0
    @State private var checkVisible = false
    @State private var exitOpacity: Double = 1
    @State private var exitOffset: CGFloat = 0

    private var effectiveDue: Date? { dueDateOverride ?? assignment.dueAt }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { tl in
            let urgency = Urgency(dueAt: effectiveDue, now: tl.date)
            let color: Color = isCompleted ? Color.lhfGraphite.opacity(0.35) : urgency.cardColor

            ZStack {
                cardBody(urgency: urgency, color: color, now: tl.date)
                if checkVisible { checkOverlay(color: color) }
            }
            .opacity(exitOpacity)
            .offset(y: exitOffset)
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isPressed)
            .contentShape(Rectangle())
            .onTapGesture { onEditDue() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded   { _ in isPressed = false }
            )
        }
    }

    // MARK: – Card body

    private func cardBody(urgency: Urgency, color: Color, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: course + completion button
            HStack(alignment: .top) {
                Text(assignment.course.uppercased())
                    .font(.geist(11, weight: .semibold))
                    .kerning(0.7)
                    .foregroundStyle(.white.opacity(isCompleted ? 0.4 : 0.65))
                Spacer()
                completionButton
            }

            // Title
            Text(assignment.title)
                .font(.geist(16, weight: .semibold))
                .foregroundStyle(isCompleted ? .white.opacity(0.45) : .white)
                .strikethrough(isCompleted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            // Bottom row: due text + open link
            HStack(alignment: .bottom) {
                dueLabel(urgency: urgency)
                Spacer()
                if let url = assignment.url {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)
        }
        .padding(16)
        .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func dueLabel(urgency: Urgency) -> some View {
        let text = formatDue(effectiveDue)
        if urgency.shouldPulse(dueAt: effectiveDue) {
            Text(text)
                .font(.geist(13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .modifier(PulseModifier())
        } else {
            Text(text)
                .font(.geist(13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var completionButton: some View {
        Button { animateCompletion() } label: {
            Image(systemName: isCompleted ? "arrow.uturn.backward.circle.fill" : "circle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(isCompleted ? 0.6 : 0.5))
        }
        .buttonStyle(.plain)
        .help(isCompleted ? "Move back to active" : "Mark completed")
    }

    // MARK: – Checkmark overlay

    private func checkOverlay(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(color)
            .overlay {
                CheckmarkShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(24)
                    .animation(.easeOut(duration: 0.22), value: checkProgress)
            }
    }

    // MARK: – Completion animation

    private func animateCompletion() {
        if isCompleted { onToggleCompleted(); return }

        checkVisible = true
        checkProgress = 0
        withAnimation(.easeOut(duration: 0.22)) { checkProgress = 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.easeIn(duration: 0.2)) {
                exitOpacity = 0
                exitOffset = -10
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.54) {
            onToggleCompleted()
        }
    }
}

// MARK: – Pulse

private struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
