import SwiftUI
import LowHangingFruitKit

/// Local state only: the real dashboard's cards exercise the same gestures,
/// but no AppState, ledger, login, notification, or Canvas mutation is involved.
struct DashboardPracticeProgress {
    enum Step { case todo, previous, finished }
    private(set) var step: Step = .todo

    mutating func complete() {
        guard step == .todo else { return }
        step = .previous
    }

    mutating func undo() {
        guard step == .previous else { return }
        step = .finished
    }

    func canContinue(syncReady: Bool) -> Bool { step == .finished && syncReady }
}

struct CanvasCompletionGuide: View {
    let isReady: Bool
    let notice: String?
    let onContinue: () -> Void

    @State private var progress = DashboardPracticeProgress()
    @State private var samples = SampleData.items()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var instructionFocused: Bool

    private var inPrevious: Bool { progress.step == .previous }
    private var practiced: Bool { progress.step == .finished }
    private var selection: DashFilter { inPrevious ? .done : .thisWeek }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    HStack(spacing: 8) {
                        DashViewPicker(selection: .constant(selection))
                        ClassFilterMenu(courses: [], selection: .constant(nil))
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.smoothTomatoInk)
                            .frame(width: 38, height: 38)
                            .background(Color.smoothTomato.opacity(0.22), in: Circle())
                    }
                    .allowsHitTesting(false)
                    .opacity(0.55)
                    HStack(alignment: .top) {
                        annotation(inPrevious ? "Finished work" : "Your lists", arrow: "arrow.up")
                        Spacer()
                        if !inPrevious && !practiced {
                            annotation("Classes", arrow: "arrow.up")
                            annotation("Add task", arrow: "arrow.up")
                        }
                    }
                    .accessibilityElement(children: .combine)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(practiced ? "You’ve got it." : inPrevious ? "2 / 2 · Undo in prev" : "1 / 2 · Try a swipe")
                            .font(.lhfSerif(26))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($instructionFocused)
                        Label(practiced ? "Your assignment is back in todo." : inPrevious ? "Swipe left or tap to undo." : "Swipe right to mark this done.",
                              systemImage: inPrevious ? "arrow.left" : practiced ? "checkmark" : "arrow.right")
                            .font(.lhfSans(15, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let item = samples.first {
                        if inPrevious {
                            DoneCardView(item: item, dayLabel: "Today", onTap: undo)
                        } else {
                            AssignmentCardView(item: item, onComplete: complete, onEdit: {})
                                .id(practiced)
                                .allowsHitTesting(!practiced)
                                .accessibilityAction(named: "Mark complete", complete)
                        }
                    }
                    if !inPrevious {
                        ForEach(Array(samples.dropFirst().prefix(2))) { item in
                            AssignmentCardView(item: item, onComplete: {}, onEdit: {})
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .opacity(0.25)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
            }

            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.lhfMono(10))
                        .foregroundStyle(Color.smoothMuted)
                    if let notice {
                        Text(notice).font(.lhfSans(12)).foregroundStyle(Color.smoothMuted)
                    }
                    if practiced {
                        Button(action: { if progress.canContinue(syncReady: isReady) { onContinue() } }) {
                            HStack {
                                if !isReady { ProgressView().tint(Color.smoothPaper) }
                                Text(isReady ? "Continue" : "Syncing Canvas…")
                            }
                            .font(.lhfSans(16, weight: .semibold))
                            .foregroundStyle(Color.smoothPaper)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Color.smoothInk, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!isReady)
                    } else {
                        Text(isReady ? "Canvas is ready when you are." : "Syncing your Canvas…")
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.smoothMuted)
                    }
                }
                Spacer(minLength: 0)
                if inPrevious || practiced {
                    annotation("Ask AI", arrow: "arrow.right")
                }
                SmoothStarMark(size: 58)
                    .frame(width: 60, height: 60)
                    .opacity(0.55)
                    .accessibilityLabel("AI: ask about your classes")
            }
            .padding(20)
        }
        .foregroundStyle(Color.smoothInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.smoothPaper.ignoresSafeArea())
        .onAppear { instructionFocused = true }
        .onChange(of: progress.step) { _, _ in instructionFocused = true }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                SmoothWordmark(pointSize: 30)
                Text("Your day, at a glance")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
            }
            .opacity(0.55)
            Spacer()
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    headerIcon("megaphone.fill", color: .smoothMarigold)
                    headerIcon("person.crop.circle.fill", color: .smoothTeal)
                }
                if !inPrevious && !practiced {
                    HStack(spacing: 10) {
                        annotation("Updates", arrow: "arrow.up")
                        annotation("Settings", arrow: "arrow.up")
                    }
                }
            }
        }
    }

    private func headerIcon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 48, height: 48)
            .background(color.opacity(0.22), in: Circle())
            .opacity(0.55)
    }

    private func annotation(_ text: String, arrow: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: arrow)
            Text(text)
        }
        .font(.lhfSans(11, weight: .semibold))
        .foregroundStyle(Color.smoothCobaltInk)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func complete() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { progress.complete() }
    }

    private func undo() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { progress.undo() }
    }
}
