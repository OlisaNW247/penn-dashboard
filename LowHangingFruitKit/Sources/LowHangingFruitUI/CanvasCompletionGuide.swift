import SwiftUI

/// A practice card with local-only state. It cannot complete a real assignment
/// or write to Canvas, even while the first real assignments arrive in sync.
struct CanvasCompletionGuide: View {
    let isReady: Bool
    let notice: String?
    let onContinue: () -> Void

    @State private var practiceDone = false
    @State private var dragX: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Keep your list up to date")
                        .font(.lhfSerif(34))
                        .foregroundStyle(Color.v2Ink)
                    instruction("arrow.right", title: "Swipe right to mark done.")
                    practiceCard
                    instruction("arrow.uturn.backward", title: "In “prev,” tap or swipe left to undo.")
                    Text("This only changes your Smooth list.")
                        .font(.lhfSans(13))
                        .foregroundStyle(Color.v2DateText)
                    if let notice {
                        Text(notice)
                            .font(.lhfSans(13))
                            .foregroundStyle(Color.v2DateText)
                    }
                }
                .padding(24)
            }
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    if isReady {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.v2SpineGreen)
                    } else {
                        ProgressView()
                    }
                    Text(isReady ? "Canvas connected" : "Syncing Canvas…")
                        .font(.lhfSans(14, weight: .medium))
                }
                .accessibilityElement(children: .combine)
                Button("Continue", action: onContinue)
                    .font(.lhfSans(16, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.v2Ink, in: Capsule())
                    .opacity(isReady ? 1 : 0.45)
                    .disabled(!isReady)
                    .buttonStyle(.plain)
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg.ignoresSafeArea())
    }

    private func instruction(_ symbol: String, title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.lhfSans(18, weight: .medium))
            .foregroundStyle(Color.v2Ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var practiceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(practiceDone ? "PREV · TRY UNDOING" : "TRY IT HERE")
                .font(.lhfMono(10, weight: .semibold))
                .foregroundStyle(Color.v2DateText)
            HStack {
                Text("Practice assignment")
                    .font(.lhfAssignmentTitle(22))
                    .strikethrough(practiceDone)
                Spacer()
                Image(systemName: practiceDone ? "checkmark.circle.fill" : "arrow.right")
            }
            .foregroundStyle(Color.v2Ink)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 86)
            .background(practiceDone ? Color.v2Card : Color.smoothTomato.opacity(0.22),
                        in: RoundedRectangle(cornerRadius: 18))
            .offset(x: dragX)
            .contentShape(Rectangle())
            .onTapGesture { if practiceDone { setDone(false) } }
            .gesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragX = practiceDone
                            ? max(-86, min(0, value.translation.width))
                            : min(86, max(0, value.translation.width))
                    }
                    .onEnded { value in
                        let accepted = CompletionSwipe.accepts(horizontal: value.translation.width,
                                                               vertical: value.translation.height,
                                                               predicted: value.predictedEndTranslation.width,
                                                               undo: practiceDone)
                        if accepted { setDone(!practiceDone) }
                        else { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { dragX = 0 } }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Practice assignment")
            .accessibilityValue(practiceDone ? "Done" : "Not done")
            .accessibilityAction(named: practiceDone ? "Mark incomplete" : "Mark complete") {
                setDone(!practiceDone)
            }
        }
    }

    private func setDone(_ value: Bool) {
        lhfHapticLight()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            practiceDone = value
            dragX = 0
        }
    }
}
