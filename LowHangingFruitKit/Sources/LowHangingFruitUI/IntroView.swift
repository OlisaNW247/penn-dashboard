import SwiftUI

/// Smooth's one-time opening story in three beats: a student begins at ease,
/// school demands crowd in until they are visibly overwhelmed, and the noise
/// resolves into one straight line with a calmer perspective on life.
struct IntroView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: IntroPhase = .standing
    @State private var visibleNotificationCount = 0
    @State private var stressProgress: CGFloat = 0
    @State private var finalCopyVisible = false
    @State private var ctaVisible = false
    @State private var runID = 0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Color.v2Bg.ignoresSafeArea()
                notificationStorm(in: size)
                smoothLine(in: size)

                StudentFigure(stress: stressProgress, isRelaxed: phase == .calm)
                    .frame(width: phase == .calm ? 190 : 126, height: phase == .calm ? 140 : 154)
                    .position(
                        x: size.width * 0.5,
                        y: size.height * (phase == .calm ? 0.53 : 0.51)
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
                let isVisible = index < visibleNotificationCount
                NotificationCard(item: item)
                    .frame(width: item.width)
                    .rotationEffect(.degrees(phase == .overloaded ? item.rotation : 0))
                    .scaleEffect(
                        phase == .overloaded
                            ? (isVisible ? 1 : 0.72)
                            : (phase == .gathering ? 0.055 : 0.02)
                    )
                    .opacity(notificationOpacity(isVisible: isVisible))
                    .position(
                        x: phase == .overloaded ? item.x * size.width : destination.x,
                        y: phase == .overloaded ? item.y * size.height : destination.y
                    )
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.72),
                        value: isVisible
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(1)
    }

    private func notificationOpacity(isVisible: Bool) -> Double {
        switch phase {
        case .standing: 0
        case .overloaded: isVisible ? 1 : 0
        case .gathering: 0.72
        case .calm: 0
        }
    }

    private func linePoint(for index: Int, count: Int, in size: CGSize) -> CGPoint {
        let progress = CGFloat(index) / CGFloat(max(count - 1, 1))
        let x = 22 + progress * (size.width - 44)
        let baseline = size.height * 0.56
        let wave = sin(progress * .pi * 6) * 9.6
        return CGPoint(x: x, y: baseline + wave)
    }

    private func smoothLine(in size: CGSize) -> some View {
        SmoothIntroLine()
            .trim(from: 0, to: phase == .gathering || phase == .calm ? 1 : 0)
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
            .frame(width: size.width - 44, height: 30)
            .position(x: size.width * 0.5, y: size.height * 0.56)
            .opacity(phase == .gathering || phase == .calm ? 1 : 0)
            .shadow(color: Color.smoothGrape.opacity(phase == .calm ? 0.12 : 0), radius: 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(2)
    }

    private func calmIdentity(in size: CGSize) -> some View {
        ZStack {
            Text("There’s more to life\nthan school.")
                .font(.lhfSans(34, weight: .semibold))
                .position(x: size.width * 0.5, y: size.height * 0.25)

            (
                Text("Make it all ")
                    + Text("smooth").italic()
                    + Text(".")
            )
            .font(.lhfSans(34, weight: .semibold))
            .position(x: size.width * 0.5, y: size.height * 0.69)
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(Color.v2Ink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .opacity(finalCopyVisible ? 1 : 0)
        .scaleEffect(finalCopyVisible ? 1 : 0.94)
        .offset(y: finalCopyVisible ? 0 : 10)
        .accessibilityLabel("There’s more to life than school. Make it all smooth.")
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
            .opacity(ctaVisible ? 1 : 0)
            .offset(y: ctaVisible ? 0 : 18)
            .disabled(!ctaVisible)
            .accessibilityHint("Opens Canvas setup")
        }
    }

    @MainActor
    private func playIntro() async {
        phase = reduceMotion ? .calm : .standing
        visibleNotificationCount = 0
        stressProgress = 0
        finalCopyVisible = reduceMotion
        ctaVisible = reduceMotion

        guard !reduceMotion else { return }

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LHFIntroHoldStanding") {
            return
        }
#endif

        try? await Task.sleep(nanoseconds: 1_600_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.24)) {
            phase = .overloaded
        }

        for index in IntroNotification.samples.indices {
            guard !Task.isCancelled else { return }

            let progress = CGFloat(index + 1) / CGFloat(IntroNotification.samples.count)
            withAnimation(.spring(response: 0.46 - Double(progress) * 0.16, dampingFraction: 0.74)) {
                visibleNotificationCount = index + 1
                stressProgress = progress
            }

            if index == 3 || index == 7 || index == IntroNotification.samples.count - 1 {
                lhfHapticLight()
            }

            guard index < IntroNotification.samples.count - 1 else { continue }
            let interval = max(45_000_000.0, 520_000_000.0 * pow(0.76, Double(index)))
            try? await Task.sleep(nanoseconds: UInt64(interval))
        }

#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-LHFIntroHoldChaos") {
            return
        }
#endif

        try? await Task.sleep(nanoseconds: 650_000_000)
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

        try? await Task.sleep(nanoseconds: 420_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.spring(response: 0.58, dampingFraction: 0.86)) {
            finalCopyVisible = true
        }

        try? await Task.sleep(nanoseconds: 850_000_000)
        guard !Task.isCancelled else { return }

        lhfHapticLight()
        withAnimation(.spring(response: 0.54, dampingFraction: 0.82)) {
            ctaVisible = true
        }
    }

    private func replay() {
        lhfHapticLight()
        phase = .standing
        visibleNotificationCount = 0
        stressProgress = 0
        finalCopyVisible = false
        ctaVisible = false
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
    case standing
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

/// The destination every notification contracts into. It deliberately matches
/// the compact three-wave underline used beneath the Smooth wordmark in-app.
private struct SmoothIntroLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let amplitude = rect.height * 0.32
        path.move(to: CGPoint(x: 0, y: rect.midY))

        for step in 1...64 {
            let progress = CGFloat(step) / 64
            let x = rect.minX + rect.width * progress
            let y = rect.midY + sin(progress * .pi * 6) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

private struct StudentFigure: View {
    let stress: CGFloat
    let isRelaxed: Bool

    var body: some View {
        ZStack {
            EscalatingStudent(stress: stress)
                .opacity(isRelaxed ? 0 : 1)
                .scaleEffect(isRelaxed ? 0.86 : 1)

            RelaxedStudent()
                .opacity(isRelaxed ? 1 : 0)
                .scaleEffect(isRelaxed ? 1 : 0.82)
                .offset(y: isRelaxed ? 0 : 10)
        }
        .animation(.spring(response: 0.62, dampingFraction: 0.78), value: isRelaxed)
        .accessibilityHidden(true)
    }
}

private struct EscalatingStudent: View, @preconcurrency Animatable {
    var stress: CGFloat

    var animatableData: CGFloat {
        get { stress }
        set { stress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let ink = Color.smoothInk
            let stroke = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

            func point(_ calmX: CGFloat, _ calmY: CGFloat, _ stressedX: CGFloat, _ stressedY: CGFloat) -> CGPoint {
                CGPoint(
                    x: size.width * (calmX + (stressedX - calmX) * stress),
                    y: size.height * (calmY + (stressedY - calmY) * stress)
                )
            }

            let head = Path(ellipseIn: CGRect(x: size.width * 0.35, y: 5, width: size.width * 0.30, height: size.width * 0.30))
            context.fill(head, with: .color(Color.v2Bg))
            context.stroke(head, with: .color(ink), style: stroke)

            var body = Path()
            let neck = point(0.50, 0.29, 0.52, 0.29)
            let hip = point(0.50, 0.68, 0.46, 0.68)
            body.move(to: neck)
            body.addCurve(
                to: hip,
                control1: point(0.50, 0.41, 0.43, 0.39),
                control2: point(0.50, 0.55, 0.42, 0.54)
            )

            body.move(to: point(0.50, 0.40, 0.47, 0.39))
            body.addLine(to: point(0.39, 0.50, 0.20, 0.27))
            body.addLine(to: point(0.28, 0.60, 0.31, 0.14))

            body.move(to: point(0.50, 0.40, 0.48, 0.40))
            body.addLine(to: point(0.61, 0.50, 0.79, 0.28))
            body.addLine(to: point(0.72, 0.60, 0.68, 0.14))

            body.move(to: hip)
            body.addLine(to: point(0.36, 0.84, 0.24, 0.86))
            body.addLine(to: point(0.30, 0.98, 0.16, 0.98))
            body.move(to: hip)
            body.addLine(to: point(0.64, 0.84, 0.68, 0.85))
            body.addLine(to: point(0.70, 0.98, 0.82, 0.96))
            context.stroke(body, with: .color(ink), style: stroke)

            guard stress > 0.30 else { return }

            var marks = Path()
            marks.move(to: CGPoint(x: size.width * 0.18, y: size.height * 0.07))
            marks.addLine(to: CGPoint(x: size.width * 0.10, y: 0))
            marks.move(to: CGPoint(x: size.width * 0.80, y: size.height * 0.08))
            marks.addLine(to: CGPoint(x: size.width * 0.90, y: 0))
            if stress > 0.68 {
                marks.move(to: CGPoint(x: size.width * 0.92, y: size.height * 0.19))
                marks.addLine(to: CGPoint(x: size.width, y: size.height * 0.17))
            }
            let markOpacity = min(1, (stress - 0.30) / 0.50)
            context.opacity = markOpacity
            context.stroke(marks, with: .color(Color.smoothTomato), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

private struct RelaxedStudent: View {
    var body: some View {
        Canvas { context, size in
            let ink = Color.smoothInk
            let stroke = StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)

            let head = Path(
                ellipseIn: CGRect(
                    x: size.width * 0.17,
                    y: size.height * 0.18,
                    width: size.height * 0.24,
                    height: size.height * 0.24
                )
            )
            context.fill(head, with: .color(Color.v2Bg))
            context.stroke(head, with: .color(ink), style: stroke)

            var body = Path()
            let shoulder = CGPoint(x: size.width * 0.36, y: size.height * 0.43)
            let hip = CGPoint(x: size.width * 0.63, y: size.height * 0.61)
            body.move(to: shoulder)
            body.addCurve(
                to: hip,
                control1: CGPoint(x: size.width * 0.46, y: size.height * 0.43),
                control2: CGPoint(x: size.width * 0.56, y: size.height * 0.55)
            )

            // One arm clearly props up the head; the other rests on the torso.
            let supportingHand = CGPoint(x: size.width * 0.31, y: size.height * 0.27)
            body.move(to: shoulder)
            body.addLine(to: CGPoint(x: size.width * 0.24, y: size.height * 0.36))
            body.addLine(to: supportingHand)

            let restingHand = CGPoint(x: size.width * 0.54, y: size.height * 0.52)
            body.move(to: CGPoint(x: size.width * 0.39, y: size.height * 0.45))
            body.addLine(to: CGPoint(x: size.width * 0.47, y: size.height * 0.49))
            body.addLine(to: restingHand)

            body.move(to: hip)
            body.addLine(to: CGPoint(x: size.width * 0.80, y: size.height * 0.70))
            body.addLine(to: CGPoint(x: size.width * 0.97, y: size.height * 0.68))
            body.move(to: hip)
            body.addLine(to: CGPoint(x: size.width * 0.80, y: size.height * 0.53))
            body.addLine(to: CGPoint(x: size.width * 0.94, y: size.height * 0.57))
            context.stroke(body, with: .color(ink), style: stroke)

            let handRadius: CGFloat = 3.4
            for hand in [supportingHand, restingHand] {
                let dot = Path(
                    ellipseIn: CGRect(
                        x: hand.x - handRadius,
                        y: hand.y - handRadius,
                        width: handRadius * 2,
                        height: handRadius * 2
                    )
                )
                context.fill(dot, with: .color(ink))
            }

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
