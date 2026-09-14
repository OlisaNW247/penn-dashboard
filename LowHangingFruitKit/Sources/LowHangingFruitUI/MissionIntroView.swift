import SwiftUI

/// The product explanation that follows the animated opening story and hands
/// directly into account connection. Kept separate from `IntroView` so the
/// cinematic first beat and the swipeable product tour can evolve independently.
struct MissionIntroView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinish: () -> Void

    @State private var page: Int = {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-LHFMissionPage"),
           arguments.indices.contains(flag + 1),
           let requested = Int(arguments[flag + 1]) {
            return max(0, min(2, requested))
        }
#endif
        return 0
    }()

    private static let pageCount = 3

    var body: some View {
        ZStack {
            Color.v2Bg.ignoresSafeArea()

            VStack(spacing: 0) {
                skipBar

                ZStack {
                    pageContent
                        .id(page)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                )
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                footer
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 28)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    setPage(page + (value.translation.width < 0 ? 1 : -1))
                }
        )
    }

    private var skipBar: some View {
        HStack {
            Spacer()
            Button("Skip") {
                lhfHapticLight()
                onFinish()
            }
            .font(.lhfSans(14, weight: .medium))
            .foregroundStyle(Color.v2DateText)
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Goes straight to Canvas setup")
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            purposePage
        case 1:
            methodPage
        default:
            featuresPage
        }
    }

    private var purposePage: some View {
        VStack(alignment: .leading, spacing: 28) {
            MissionScatter()
                .frame(height: 360)

            Text("We kept losing points on the easy stuff.")
                .font(.lhfSerif(36))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Assignments were everywhere. The small, reachable ones were the easiest to miss.")
                .font(.lhfSans(17))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var methodPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Go get the low hanging fruit.")
                .font(.lhfSerif(36))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Smooth turns scattered schoolwork into one clear, prioritized plan.")
                .font(.lhfSans(17))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                missionAssignment(course: "CIS 1200", title: "Lab check-in", due: "today", color: .smoothTomato)
                missionAssignment(course: "PSYC 1010", title: "Reading response", due: "tomorrow", color: .smoothMarigold)
                missionAssignment(course: "PHYS 151", title: "Problem set 3", due: "friday", color: .smoothTeal)
                missionAssignment(course: "ECON 0100", title: "Weekly quiz", due: "monday", color: .smoothCobalt)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var featuresPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("How Smooth keeps you ahead.")
                    .font(.lhfSerif(34))
                    .foregroundStyle(Color.v2Ink)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 11) {
                    featureRow(
                        icon: "rectangle.grid.1x2",
                        title: "Dashboard",
                        detail: "Everything due, ordered by what matters now.",
                        tint: .smoothTomato
                    )
                    featureRow(
                        icon: "bell.badge.fill",
                        title: "Reminders",
                        detail: "A useful nudge before work slips through.",
                        tint: .smoothMarigold
                    )
                    featureRow(
                        icon: "sparkles",
                        title: "Ask",
                        detail: "Answers grounded in your actual course material.",
                        tint: .smoothGrape
                    )
                    featureRow(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "Grade Watcher",
                        detail: "See where you stand while there’s time to act.",
                        tint: .smoothTeal
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    private func missionAssignment(
        course: String,
        title: String,
        due: String,
        color: Color
    ) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(course)
                    .font(.lhfMono(10, weight: .semibold))
                    .tracking(0.7)
                Text(title)
                    .font(.lhfAssignmentTitle(16))
            }
            .foregroundStyle(Color.v2Ink)

            Spacer(minLength: 10)

            Text(due)
                .font(.lhfSans(12, weight: .semibold))
                .foregroundStyle(Color.v2DateText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func featureRow(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.lhfSans(16, weight: .semibold))
                    .foregroundStyle(Color.v2Ink)
                Text(detail)
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.08), radius: 5, y: 2)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(0..<Self.pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.v2Ink : Color.v2DateText.opacity(0.28))
                        .frame(width: index == page ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
                }
            }
            .accessibilityHidden(true)

            Button {
                lhfHapticLight()
                if page == Self.pageCount - 1 {
                    onFinish()
                } else {
                    setPage(page + 1)
                }
            } label: {
                Text(page == Self.pageCount - 1 ? "Connect Canvas" : "Continue")
                    .font(.lhfSans(16, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private func setPage(_ target: Int) {
        let next = max(0, min(Self.pageCount - 1, target))
        guard next != page else { return }
        if reduceMotion {
            page = next
        } else {
            withAnimation(.easeInOut(duration: 0.30)) {
                page = next
            }
        }
    }
}

private struct MissionScatter: View {
    private let chips: [(String, Color, CGFloat, CGFloat, Double)] = [
        ("CIS 1200 · Today", .smoothTomato, 0.18, 0.20, -10),
        ("PHYS 151 · Fri", .smoothMarigold, 0.72, 0.12, 8),
        ("ECON 0100 · Mon", .smoothLemon, 0.86, 0.44, -7),
        ("PSYC 1010 · Tue", .smoothTeal, 0.28, 0.48, 11),
        ("MATH 1410 · Wed", .smoothCobalt, 0.66, 0.66, -5),
        ("ENGL 016 · Thu", .smoothGrape, 0.08, 0.77, 7),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    Text(chip.0)
                        .font(.lhfMono(11, weight: .semibold))
                        .foregroundStyle(Color.v2Ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(chip.1.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .rotationEffect(.degrees(chip.4))
                        .position(x: chip.2 * proxy.size.width, y: chip.3 * proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}
