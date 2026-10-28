import SwiftUI

enum DashboardTourStep: Int, CaseIterable {
    case views, classes, add, announcements, assistant, profile

    var title: String {
        switch self {
        case .views: "Your assignments"
        case .classes: "One class at a time"
        case .add: "Add your own"
        case .announcements: "Stay in the loop"
        case .assistant: "Ask AI"
        case .profile: "Make it yours"
        }
    }

    var detail: String {
        switch self {
        case .views: "Switch between todo, all, and prev for finished work."
        case .classes: "Filter your list by class."
        case .add: "Add an assignment or a recurring task."
        case .announcements: "Read class announcements and updates here."
        case .assistant: "Ask about your classes, deadlines, and course materials."
        case .profile: "Manage connections, reminders, and Smooth Sweeper."
        }
    }
}

struct DashboardTourAnchors: PreferenceKey {
    static var defaultValue: [DashboardTourStep: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [DashboardTourStep: Anchor<CGRect>], nextValue: () -> [DashboardTourStep: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func dashboardTourTarget(_ step: DashboardTourStep) -> some View {
        anchorPreference(key: DashboardTourAnchors.self, value: .bounds) { [step: $0] }
    }
}

/// Anchors follow the real controls through layout and text-size changes.
/// The overlay consumes taps so advancing a lesson cannot open a destination.
struct DashboardTour: View {
    let anchors: [DashboardTourStep: Anchor<CGRect>]
    let onFinish: () -> Void
    @State private var step = DashboardTourStep.views
    @State private var cardHeight: CGFloat = 260
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let target = anchors[step].map { geometry[$0].insetBy(dx: -6, dy: -6) } ?? .zero
            let below = target.midY < geometry.size.height / 2
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                    path.addRoundedRect(in: target, cornerSize: CGSize(width: 22, height: 22))
                }
                .fill(.black.opacity(0.48), style: FillStyle(eoFill: true))
                .contentShape(Rectangle())
                .onTapGesture { }
                .accessibilityHidden(true)

                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color.smoothPaper, lineWidth: 2)
                    .frame(width: target.width, height: target.height)
                    .position(x: target.midX, y: target.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    if below { arrow(target: target, below: true) }
                    ScrollView {
                        card.background {
                            GeometryReader { cardGeometry in
                                Color.clear.preference(key: TourCardHeight.self, value: cardGeometry.size.height)
                            }
                        }
                    }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: min(cardHeight, max(160, below ? geometry.size.height - target.maxY - 60 : target.minY - 60)))
                        .onPreferenceChange(TourCardHeight.self) { cardHeight = $0 }
                    if !below { arrow(target: target, below: false) }
                }
                .padding(.horizontal, 20)
                .frame(width: geometry.size.width)
                .padding(.top, below ? max(0, target.maxY + 8) : 0)
                .padding(.bottom, below ? 0 : max(0, geometry.size.height - target.minY + 8))
                .frame(height: geometry.size.height, alignment: below ? .top : .bottom)
            }
        }
        .onAppear { headingFocused = true }
        .onChange(of: step) { _, _ in headingFocused = true }
    }

    private func arrow(target: CGRect, below: Bool) -> some View {
        HStack {
            Image(systemName: below ? "arrow.up" : "arrow.down")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.smoothPaper)
                .offset(x: max(0, target.midX - 32))
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(step.rawValue + 1) / \(DashboardTourStep.allCases.count)")
                    .font(.lhfMono(12))
                Spacer()
                Button("Skip", action: onFinish)
                    .font(.lhfSans(14))
                    .frame(minWidth: 44, minHeight: 44)
            }
            Text(step.title)
                .font(.lhfSerif(28))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(step.detail)
                .font(.lhfSans(16))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if step != .views {
                    Button("Back") { advance(-1) }
                        .frame(minWidth: 44, minHeight: 44)
                }
                Spacer()
                Button(step == .profile ? "Let’s go" : "Next") {
                    if step == .profile { onFinish() } else { advance(1) }
                }
                .font(.lhfSans(16, weight: .semibold))
                .foregroundStyle(Color.smoothPaper)
                .padding(.horizontal, 24)
                .frame(minHeight: 48)
                .background(Color.smoothInk, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.smoothInk)
        .padding(20)
        .background(Color.smoothPaper, in: RoundedRectangle(cornerRadius: 24))
    }

    private func advance(_ direction: Int) {
        guard let next = DashboardTourStep(rawValue: step.rawValue + direction) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { step = next }
    }
}

private struct TourCardHeight: PreferenceKey {
    static var defaultValue: CGFloat { 260 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
