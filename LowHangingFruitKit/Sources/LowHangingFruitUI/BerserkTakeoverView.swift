import SwiftUI

/// The Berserk takeover: full-bleed tomato, the class, the assignment, a live
/// countdown to the due time, and the three choices.
///
/// Pure presentation. It is handed a `BerserkTakeover` and reports a
/// `BerserkTakeoverChoice`; what each choice does is
/// `BerserkTakeoverRules.effects`, run by the host. The labels are the
/// existing constants (`LoudAlertActions.turnedInTitle`, the link kind's
/// `label`), never restated, so a button here can never say something
/// different from the notification button or the alarm button it stands for.
///
/// **The countdown is a system timer** (`Text(timerInterval:)`), which counts
/// by itself without this view redrawing every second. A one-second timeline
/// only exists to turn it into "due now" when the time arrives, because the
/// timer text would otherwise sit at 0:00.
struct BerserkTakeoverView: View {
    let takeover: BerserkTakeover
    let now: Date
    let onChoice: (BerserkTakeoverChoice) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Smooth")
                .font(.lhfWordmark(26))
                .foregroundStyle(Color.white)

            Spacer(minLength: 24)

            countdown

            Text(takeover.title)
                .font(.lhfAssignmentTitle(30))
                .foregroundStyle(Color.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            Text(takeover.course)
                .font(.lhfSans(17))
                .foregroundStyle(Color.white.opacity(0.85))
                .padding(.top, 6)

            Spacer(minLength: 24)

            buttons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background {
            // The slow pulse: the tomato breathes toward a darker tomato.
            // Not drawn at all under Reduce Motion.
            ZStack {
                Color.smoothTomato
                Color.black.opacity(pulse && !reduceMotion ? 0.18 : 0)
            }
            .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // MARK: Countdown

    @ViewBuilder
    private var countdown: some View {
        TimelineView(.periodic(from: now, by: 1)) { context in
            let moment = max(context.date, now)
            VStack(alignment: .leading, spacing: 4) {
                if let due = takeover.due, due > moment {
                    Text("due in")
                        .font(.lhfSecondary(15, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.white.opacity(0.85))
                    Text(timerInterval: moment...due, countsDown: true)
                        .font(.lhfMono(64, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                } else {
                    Text("due now")
                        .font(.lhfMono(64, weight: .bold))
                        .foregroundStyle(Color.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BerserkTakeoverRules.countdownLabel(due: takeover.due, now: moment))
        }
    }

    // MARK: Choices

    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                onChoice(.turnedIn)
            } label: {
                Text(LoudAlertActions.turnedInTitle)
                    .font(.lhfSans(18, weight: .semibold))
                    .foregroundStyle(Color.smoothTomatoInk)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if let link = takeover.link {
                Button {
                    onChoice(.open)
                } label: {
                    Text(link.kind.label)
                        .font(.lhfSans(18, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                onChoice(.notYet)
            } label: {
                Text("not yet")
                    .font(.lhfSans(17))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview("berserk takeover") {
    BerserkTakeoverView(
        takeover: BerserkTakeover(
            assignmentID: "canvas:preview",
            course: "CIS 1200",
            title: "Problem Set 4",
            due: Date().addingTimeInterval(9 * 60),
            link: .init(kind: .canvas, url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/2")!),
            source: .buzz),
        now: Date(),
        onChoice: { _ in })
}
