import SwiftUI
import PennDashboardKit

struct AssignmentCardView: View {
    let assignment: Assignment
    let isCompleted: Bool
    let dueDateOverride: Date?
    let onToggleCompleted: () -> Void
    let onEditDue: () -> Void

    @State private var isPressed = false
    @State private var checkVisible = false
    @State private var checkProgress: CGFloat = 0
    @State private var exitOpacity: Double = 1
    @State private var exitOffset: CGFloat = 0
    @State private var exitScale: CGFloat = 1

    private var effectiveDue: Date? { dueDateOverride ?? assignment.dueAt }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { tl in
            let urgency = Urgency(dueAt: effectiveDue, now: tl.date)
            let color = isCompleted ? Color.lhfGraphite.opacity(0.35) : urgency.cardColor

            ZStack(alignment: .trailing) {
                cardContent(urgency: urgency, color: color, now: tl.date)
                checkmarkOverlay(color: color)
            }
            .opacity(exitOpacity)
            .offset(y: exitOffset)
            .scaleEffect(exitScale)
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
            .contentShape(Rectangle())
            .onTapGesture { onEditDue() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded   { _ in isPressed = false }
            )
        }
    }

    private func cardContent(urgency: Urgency, color: Color, now: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(assignment.title)
                    .font(.geist(15, weight: .semibold))
                    .foregroundStyle(isCompleted ? Color.lhfGraphite.opacity(0.45) : .white)
                    .strikethrough(isCompleted)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(assignment.course)
                        .font(.geist(12))
                        .foregroundStyle(.white.opacity(0.7))

                    if assignment.source != .canvas || assignment.kind != .assignment {
                        kindBadge(urgency: urgency)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if urgency.shouldPulse(dueAt: effectiveDue) {
                    Text(formatDue(effectiveDue))
                        .font(.geist(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .modifier(PulseModifier())
                } else {
                    Text(formatDue(effectiveDue))
                        .font(.geist(13, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(fullDueText)
                    .font(.geist(11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            completionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func kindBadge(urgency: Urgency) -> some View {
        let label: String
        switch assignment.kind {
        case .quiz:       label = "Quiz"
        case .discussion: label = "Discussion"
        case .event:      label = "Event"
        default:
            switch assignment.source {
            case .gradescope:      label = "Gradescope"
            case .ed:              label = "Ed"
            case .canvasSuggestion: label = "Recurring"
            case .manual:          label = "Manual"
            default:               label = ""
            }
        }
        if label.isEmpty { return AnyView(EmptyView()) }
        return AnyView(
            Text(label)
                .font(.geist(10, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.18), in: Capsule())
        )
    }

    private var completionButton: some View {
        Button {
            animateCompletion()
        } label: {
            Image(systemName: isCompleted ? "arrow.uturn.backward.circle.fill" : "circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(isCompleted ? 0.7 : 0.55))
        }
        .buttonStyle(.plain)
        .help(isCompleted ? "Move back to active" : "Mark completed")
    }

    private var checkmarkOverlay: some View { (Color.clear) }

    private func checkmarkOverlay(color: Color) -> some View {
        ZStack {
            if checkVisible {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color)
                CheckmarkShape()
                    .trim(from: 0, to: checkProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .padding(20)
                    .animation(.easeOut(duration: 0.22), value: checkProgress)
            }
        }
    }

    private var fullDueText: String {
        guard let due = effectiveDue else { return "No due date" }
        return due.formatted(date: .abbreviated, time: .shortened)
    }

    private func animateCompletion() {
        if isCompleted {
            onToggleCompleted()
            return
        }
        checkVisible = true
        checkProgress = 0
        withAnimation(.easeOut(duration: 0.22)) {
            checkProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.easeIn(duration: 0.18)) {
                exitOpacity = 0
                exitOffset = -12
                exitScale = 0.95
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
            onToggleCompleted()
        }
    }
}

private struct PulseModifier: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.55 : 1.0)
            .animation(
                .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: on
            )
            .onAppear { on = true }
    }
}
