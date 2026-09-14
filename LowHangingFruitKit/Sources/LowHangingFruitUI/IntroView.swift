import SwiftUI

/// Smooth's one-time opening story. A first-time student meets the problem
/// before the product: assignments, announcements, grades, and deadlines
/// crowd the screen around a stressed figure. The cards then physically
/// collapse into Smooth's rainbow line, the figure relaxes onto it, and the
/// connect flow gets one calm, unambiguous entrance.
struct IntroView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: IntroPhase = .overloaded
    @State private var notificationsVisible = false
    @State private var runID = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Color.v2Bg.ignoresSafeArea()
                notificationStorm(in: size)
                smoothLine(in: size)

                StudentFigure(isCalm: phase == .calm)
                    .frame(width: phase == .calm ? 178 : 126, height: phase == .calm ? 132 : 154)
                    .position(
                        x: size.width * 0.5,
                        y: size.height * (phase == .calm ? 0.49 : 0.51)
                    )
                    .shadow(color: Color.v2CardShadow.opacity(phase == .calm ? 0 : 0.12), radius: 12, y: 7)
                    .zIndex(3)

                calmIdentity(in: size)
                    .zIndex(4)

                controls
                    .zIndex(5)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(maxWidth: 480)
        .task(id: runID) {
            await playIntro()
        }
        .accessibilityElement(children: .contain)
    }

    private func notificationStorm(in size: CGSize) -> some View {
        ZStack {
            ForEach(Array(IntroNotification.samples.enumerated()), id: \.element.id) { index, item in
                let destination = linePoint(for: index, count: IntroNotification.samples.count, in: size)
                NotificationCard(item: item)
                    .frame(width: item.width)
                    .rotationEffect(.degrees(phase == .overloaded ? item.rotation : 0))
                    .scaleEffect(
                        phase == .overloaded
                            ? (notificationsVisible ? 1 : 0.72)
                            : (phase == .gathering ? 0.055 : 0.02)
                    )
                    .opacity(notificationOpacity)
                    .position(
                        x: phase == .overloaded ? item.x * size.width : destination.x,
                        y: phase == .overloaded ? item.y * size.height : destination.y
                    )
                    .animation(
                        reduceMotion
                            ? nil
                            : .spring(response: 0.44, dampingFraction: 0.72)
                                .delay(Double(index) * 0.045),
                        value: notificationsVisible
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(1)
    }

    private var notificationOpacity: Double {
        switch phase {
        case .overloaded: notificationsVisible ? 1 : 0
        case .gathering: 0.72
        case .calm: 0
        }
    }

    private func linePoint(for index: Int, count: Int, in size: CGSize) -> CGPoint {
        let progress = CGFloat(index) / CGFloat(max(count - 1, 1))
        let x = 22 + progress * (size.width - 44)
        let baseline = size.height * 0.535
        let wave = sin(progress * .pi * 4) * 7
        return CGPoint(x: x, y: baseline + wave)
    }

    private func smoothLine(in size: CGSize) -> some View {
        SmoothIntroLine()
            .trim(from: 0, to: phase == .overloaded ? 0 : 1)
            .stroke(
                LinearGradient(
                    colors: [
                        .smoothTomato,
                        .smoothMarigold,
                        .smoothLemon,
                        .smoothTeal,
                        .smoothCobalt,
                        .smoothGrape,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
            )
            .frame(width: size.width - 44, height: 34)
            .position(x: size.width * 0.5, y: size.height * 0.535)
            .opacity(phase == .overloaded ? 0 : 1)
            .shadow(color: Color.smoothGrape.opacity(phase == .calm ? 0.12 : 0), radius: 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(2)
    }

    private func calmIdentity(in size: CGSize) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SmoothAppMark(size: 58)
                Text("Smooth")
                    .font(.lhfWordmark(52))
                    .foregroundStyle(Color.smoothInk)
                    .minimumScaleFactor(0.8)
            }

            Text("Make your life smooth.")
                .font(.lhfSans(22, weight: .medium))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)

            Text("There’s more to life than school.\nMake it all smooth.")
                .font(.lhfSans(16, weight: .regular))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .padding(.horizontal, 24)
        .position(x: size.width * 0.5, y: size.height * 0.275)
        .opacity(phase == .calm ? 1 : 0)
        .scaleEffect(phase == .calm ? 1 : 0.92)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Smooth. Make your life smooth. There’s more to life than school. Make it all smooth."
        )
    }

    private var controls: some View {
        VStack {
            HStack {
                if phase == .calm {
                    Button {
                        replay()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.v2DateText)
                    .accessibilityLabel("Replay intro")
                    .transition(.opacity)
                }

                Spacer()

                Button("Skip") {
                    finishIntro()
                }
                .font(.lhfSans(14, weight: .medium))
                .foregroundStyle(Color.v2DateText)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Goes straight to setup")
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            Spacer()

            Button {
                lhfHapticLight()
                finishIntro()
            } label: {
                Text("Get started")
                    .font(.lhfSans(16, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .opacity(phase == .calm ? 1 : 0)
            .offset(y: phase == .calm ? 0 : 16)
            .disabled(phase != .calm)
            .accessibilityHint("Opens Canvas setup")
        }
    }

    @MainActor
    private func playIntro() async {
        phase = reduceMotion ? .calm : .overloaded
        notificationsVisible = false

        guard !reduceMotion else { return }

        withAnimation {
            notificationsVisible = true
        }

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LHFIntroHoldChaos") {
            return
        }
#endif

        try? await Task.sleep(nanoseconds: 1_900_000_000)
        guard !Task.isCancelled else { return }

        lhfHapticLight()
        withAnimation(.easeInOut(duration: 1.15)) {
            phase = .gathering
        }

        try? await Task.sleep(nanoseconds: 1_100_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.spring(response: 0.62, dampingFraction: 0.82)) {
            phase = .calm
        }
    }

    private func replay() {
        lhfHapticLight()
        phase = .overloaded
        notificationsVisible = false
        runID += 1
    }

    private func finishIntro() {
        if reduceMotion {
            state.completeIntro()
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                state.completeIntro()
            }
        }
    }
}

private enum IntroPhase {
    case overloaded
    case gathering
    case calm
}

private struct IntroNotification: Identifiable {
    let id: Int
    let app: String
    let icon: String
    let headline: String
    let detail: String
    let accent: Color
    let x: CGFloat
    let y: CGFloat
    let rotation: Double
    let width: CGFloat

    static let samples: [IntroNotification] = [
        .init(id: 0, app: "CANVAS", icon: "bell.badge.fill", headline: "CIS 1210 · Quiz 7", detail: "Due in 10 minutes", accent: .smoothTomato, x: 0.24, y: 0.12, rotation: -7, width: 174),
        .init(id: 1, app: "GRADESCOPE", icon: "checkmark.circle.fill", headline: "Homework 6 graded", detail: "71% · View feedback", accent: .smoothGrape, x: 0.73, y: 0.16, rotation: 6, width: 184),
        .init(id: 2, app: "CALENDAR", icon: "calendar", headline: "Midterm tomorrow", detail: "9:00 AM · DRLB 2N36", accent: .smoothCobalt, x: 0.18, y: 0.28, rotation: 5, width: 176),
        .init(id: 3, app: "CANVAS", icon: "bubble.left.and.bubble.right.fill", headline: "3 new announcements", detail: "ECON 0100", accent: .smoothMarigold, x: 0.78, y: 0.31, rotation: -8, width: 178),
        .init(id: 4, app: "REMINDERS", icon: "exclamationmark.circle.fill", headline: "Reading response", detail: "Overdue", accent: .smoothTomato, x: 0.25, y: 0.42, rotation: -4, width: 158),
        .init(id: 5, app: "MAIL", icon: "envelope.badge.fill", headline: "Office hours moved", detail: "Plus 18 unread messages", accent: .smoothTeal, x: 0.78, y: 0.45, rotation: 7, width: 174),
        .init(id: 6, app: "CANVAS", icon: "doc.text.fill", headline: "Lab report 4", detail: "Due tonight at 11:59", accent: .smoothLemon, x: 0.17, y: 0.60, rotation: 8, width: 175),
        .init(id: 7, app: "GRADESCOPE", icon: "chart.line.downtrend.xyaxis", headline: "Exam 1 posted", detail: "Below class median", accent: .smoothTomato, x: 0.80, y: 0.61, rotation: -5, width: 170),
        .init(id: 8, app: "CANVAS", icon: "person.2.fill", headline: "Discussion reply", detail: "2 classmates mentioned you", accent: .smoothTeal, x: 0.22, y: 0.74, rotation: -7, width: 182),
        .init(id: 9, app: "CALENDAR", icon: "clock.badge.exclamationmark.fill", headline: "Problem set 3", detail: "Due in 5 hours", accent: .smoothMarigold, x: 0.77, y: 0.77, rotation: 5, width: 166),
        .init(id: 10, app: "CANVAS", icon: "arrow.triangle.2.circlepath", headline: "Course updated", detail: "Syllabus · Modules · Files", accent: .smoothCobalt, x: 0.23, y: 0.88, rotation: 4, width: 180),
        .init(id: 11, app: "MAIL", icon: "tray.full.fill", headline: "47 unread", detail: "Penn · Canvas · Classes", accent: .smoothGrape, x: 0.76, y: 0.91, rotation: -6, width: 166),
    ]
}

private struct NotificationCard: View {
    let item: IntroNotification

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(item.accent)
                .frame(width: 29, height: 29)
                .background(item.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.app)
                    .font(.lhfMono(8.5, weight: .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Color.v2DateText)
                Text(item.headline)
                    .font(.lhfSans(12.5, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.lhfSecondary(10.5))
                    .foregroundStyle(Color.v2DateText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.v2Card.opacity(0.97), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .strokeBorder(Color.white.opacity(0.76), lineWidth: 0.8)
        }
        .shadow(color: Color.v2CardShadow.opacity(0.15), radius: 9, y: 4)
    }
}

/// The destination every notification contracts into. Its two gentle waves
/// echo the small underline already used throughout Smooth without copying a
/// generic loading curve or progress bar.
private struct SmoothIntroLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        let segment = rect.width / 4
        for index in 0..<4 {
            let start = CGFloat(index) * segment
            let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            path.addCurve(
                to: CGPoint(x: start + segment, y: rect.midY),
                control1: CGPoint(x: start + segment * 0.28, y: rect.midY + 13 * direction),
                control2: CGPoint(x: start + segment * 0.72, y: rect.midY - 13 * direction)
            )
        }
        return path
    }
}

private struct StudentFigure: View {
    let isCalm: Bool

    var body: some View {
        ZStack {
            StressedStudent()
                .opacity(isCalm ? 0 : 1)
                .scaleEffect(isCalm ? 0.82 : 1)
                .rotationEffect(.degrees(isCalm ? -5 : 0))

            RelaxedStudent()
                .opacity(isCalm ? 1 : 0)
                .scaleEffect(isCalm ? 1 : 0.82)
                .offset(y: isCalm ? 0 : 10)
        }
        .animation(.spring(response: 0.62, dampingFraction: 0.78), value: isCalm)
        .accessibilityHidden(true)
    }
}

private struct StressedStudent: View {
    var body: some View {
        Canvas { context, size in
            let ink = Color.smoothInk
            let stroke = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

            let head = Path(ellipseIn: CGRect(x: size.width * 0.35, y: 5, width: size.width * 0.30, height: size.width * 0.30))
            context.fill(head, with: .color(Color.v2Bg))
            context.stroke(head, with: .color(ink), style: stroke)

            var body = Path()
            body.move(to: CGPoint(x: size.width * 0.52, y: size.height * 0.29))
            body.addCurve(to: CGPoint(x: size.width * 0.46, y: size.height * 0.68), control1: CGPoint(x: size.width * 0.43, y: size.height * 0.39), control2: CGPoint(x: size.width * 0.42, y: size.height * 0.54))
            body.move(to: CGPoint(x: size.width * 0.47, y: size.height * 0.39))
            body.addLine(to: CGPoint(x: size.width * 0.20, y: size.height * 0.27))
            body.addLine(to: CGPoint(x: size.width * 0.31, y: size.height * 0.14))
            body.move(to: CGPoint(x: size.width * 0.48, y: size.height * 0.40))
            body.addLine(to: CGPoint(x: size.width * 0.79, y: size.height * 0.28))
            body.addLine(to: CGPoint(x: size.width * 0.68, y: size.height * 0.14))
            body.move(to: CGPoint(x: size.width * 0.46, y: size.height * 0.68))
            body.addLine(to: CGPoint(x: size.width * 0.24, y: size.height * 0.86))
            body.addLine(to: CGPoint(x: size.width * 0.16, y: size.height * 0.98))
            body.move(to: CGPoint(x: size.width * 0.46, y: size.height * 0.68))
            body.addLine(to: CGPoint(x: size.width * 0.68, y: size.height * 0.85))
            body.addLine(to: CGPoint(x: size.width * 0.82, y: size.height * 0.96))
            context.stroke(body, with: .color(ink), style: stroke)

            var stress = Path()
            stress.move(to: CGPoint(x: size.width * 0.18, y: size.height * 0.07))
            stress.addLine(to: CGPoint(x: size.width * 0.10, y: 0))
            stress.move(to: CGPoint(x: size.width * 0.80, y: size.height * 0.08))
            stress.addLine(to: CGPoint(x: size.width * 0.90, y: 0))
            stress.move(to: CGPoint(x: size.width * 0.92, y: size.height * 0.19))
            stress.addLine(to: CGPoint(x: size.width, y: size.height * 0.17))
            context.stroke(stress, with: .color(Color.smoothTomato), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

private struct RelaxedStudent: View {
    var body: some View {
        Canvas { context, size in
            let ink = Color.smoothInk
            let stroke = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

            let head = Path(ellipseIn: CGRect(x: size.width * 0.18, y: size.height * 0.18, width: size.height * 0.25, height: size.height * 0.25))
            context.fill(head, with: .color(Color.v2Bg))
            context.stroke(head, with: .color(ink), style: stroke)

            var body = Path()
            body.move(to: CGPoint(x: size.width * 0.39, y: size.height * 0.43))
            body.addCurve(to: CGPoint(x: size.width * 0.67, y: size.height * 0.60), control1: CGPoint(x: size.width * 0.48, y: size.height * 0.44), control2: CGPoint(x: size.width * 0.58, y: size.height * 0.54))
            body.move(to: CGPoint(x: size.width * 0.39, y: size.height * 0.44))
            body.addLine(to: CGPoint(x: size.width * 0.20, y: size.height * 0.35))
            body.addLine(to: CGPoint(x: size.width * 0.28, y: size.height * 0.24))
            body.move(to: CGPoint(x: size.width * 0.42, y: size.height * 0.45))
            body.addLine(to: CGPoint(x: size.width * 0.29, y: size.height * 0.32))
            body.addLine(to: CGPoint(x: size.width * 0.35, y: size.height * 0.24))
            body.move(to: CGPoint(x: size.width * 0.67, y: size.height * 0.60))
            body.addLine(to: CGPoint(x: size.width * 0.86, y: size.height * 0.72))
            body.addLine(to: CGPoint(x: size.width * 0.98, y: size.height * 0.69))
            body.move(to: CGPoint(x: size.width * 0.66, y: size.height * 0.60))
            body.addLine(to: CGPoint(x: size.width * 0.83, y: size.height * 0.51))
            body.addLine(to: CGPoint(x: size.width * 0.94, y: size.height * 0.55))
            context.stroke(body, with: .color(ink), style: stroke)

            var breeze = Path()
            breeze.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.13))
            breeze.addCurve(to: CGPoint(x: size.width * 0.20, y: size.height * 0.06), control1: CGPoint(x: size.width * 0.11, y: size.height * 0.04), control2: CGPoint(x: size.width * 0.17, y: size.height * 0.15))
            context.stroke(breeze, with: .color(Color.smoothTeal), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .overlay(alignment: .topTrailing) {
            Text("z z")
                .font(.lhfMono(11, weight: .semibold))
                .foregroundStyle(Color.smoothGrape)
                .offset(x: -10, y: 8)
        }
    }
}

#if DEBUG
#Preview("chaos to smooth") {
    IntroView()
        .environmentObject(AppState())
        .frame(width: 393, height: 852)
}
#endif
