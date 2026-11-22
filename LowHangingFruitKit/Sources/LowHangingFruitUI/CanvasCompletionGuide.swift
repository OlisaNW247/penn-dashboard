import SwiftUI
import LowHangingFruitKit

/// Local state only: the real dashboard's cards exercise the same gestures,
/// but no AppState, ledger, login, notification, or Canvas mutation is involved.
struct DashboardPracticeProgress {
    enum Feature: Int, CaseIterable {
        case lists, classes, add, announcements, assistant, settings

        var title: String {
            switch self {
            case .lists: "Your lists"
            case .classes: "Filter by class"
            case .add: "Add a task"
            case .announcements: "Announcements"
            case .assistant: "Ask AI"
            case .settings: "Settings"
            }
        }

        var detail: String {
            switch self {
            case .lists: "Switch between todo, all, and prev."
            case .classes: "Show assignments for one class."
            case .add: "Add an assignment or a recurring task."
            case .announcements: "Catch up on class announcements."
            case .assistant: "Ask about your classes, deadlines, and materials."
            case .settings: "Manage connections, reminders, and Smooth Sweeper."
            }
        }
    }
    /// There is deliberately no step between the undo practice and the
    /// first feature card. A "You've got it" pause lived there until
    /// 2026-10-30; the owner cut it because it did nothing but ask for a tap.
    enum Step: Equatable { case todo, previous, feature(Feature), ready }
    private(set) var step: Step = .todo

    mutating func complete() {
        guard step == .todo else { return }
        step = .previous
    }

    mutating func undo() {
        guard step == .previous else { return }
        step = .feature(.lists)
    }

    mutating func next() {
        switch step {
        case .feature(let feature):
            step = Feature(rawValue: feature.rawValue + 1).map(Step.feature) ?? .ready
        default: break
        }
    }

    mutating func back() {
        guard case .feature(let feature) = step else { return }
        step = Feature(rawValue: feature.rawValue - 1).map(Step.feature) ?? step
    }

    /// The student may leave the lesson from any step; the sync gate on
    /// `canContinue` still decides when the walk can actually move on.
    mutating func skip() { step = .ready }

    func canContinue(syncReady: Bool) -> Bool { step == .ready && syncReady }
}

/// The three cards the lesson lets the student practise on. Built from the
/// assignments the just-finished Canvas sync fetched, because testers read
/// invented classes as "I'm not taking those". Nothing here is written back:
/// the cards are plain values and swiping one only moves the lesson's own state.
enum PracticeCards {
    nonisolated static func items(from assignments: [Assignment], now: Date) -> [DashItem] {
        let upcoming = assignments
            .filter { ($0.dueAt ?? .distantPast) >= now }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        var picked: [Assignment] = []
        var seen = Set<String>()
        for a in upcoming where picked.count < 3 && seen.insert(a.course).inserted { picked.append(a) }
        for a in upcoming where picked.count < 3 && !picked.contains(where: { $0.id == a.id }) { picked.append(a) }
        picked.sort { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        if picked.isEmpty { return fallback(now: now) }
        return picked.map { DashItem(assignment: $0, dueOverride: nil, isCompleted: false, completedAt: nil) }
    }

    /// Courses that could be anyone's, so a student with nothing upcoming still
    /// sees something that is not claiming to be their schedule.
    nonisolated static func fallback(now: Date) -> [DashItem] {
        let rows: [(String, String, Double)] = [
            ("BIO 101", "lab report 2", 1),
            ("ECON 101", "problem set 3", 2),
            ("WRTG 101", "reading response", 4),
        ]
        return rows.enumerated().map { index, row in
            let assignment = Assignment(source: .canvas, sourceID: "practice-\(index + 1)", kind: .assignment,
                                        course: row.0, title: row.1,
                                        dueAt: now.addingTimeInterval(row.2 * 86_400), url: nil)
            return DashItem(assignment: assignment, dueOverride: nil, isCompleted: false, completedAt: nil)
        }
    }
}

struct CanvasCompletionGuide: View {
    let items: [DashItem]
    let isReady: Bool
    let notice: String?
    let onContinue: () -> Void

    @State private var progress = DashboardPracticeProgress()
    /// Off at the first touch, and never on under Reduce Motion.
    @State private var nudging = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var instructionFocused: Bool

    private var inPrevious: Bool { progress.step == .previous }
    private var practiced: Bool { progress.step != .todo && progress.step != .previous }
    private var feature: DashboardPracticeProgress.Feature? {
        if case .feature(let value) = progress.step { return value }
        return nil
    }
    private var selection: DashFilter { inPrevious ? .done : .thisWeek }

    var body: some View {
        VStack(spacing: 0) {
            skipBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    HStack(spacing: 8) {
                        DashViewPicker(selection: .constant(selection))
                            .modifier(FeatureHighlight(active: feature == .lists))
                        ClassFilterMenu(courses: [], selection: .constant(nil))
                            .modifier(FeatureHighlight(active: feature == .classes))
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.smoothTomatoInk)
                            .frame(width: 38, height: 38)
                            .background(Color.smoothTomato.opacity(0.22), in: Circle())
                            .modifier(FeatureHighlight(active: feature == .add))
                    }
                    .allowsHitTesting(false)
                    HStack(alignment: .top) {
                        if inPrevious || feature == .lists {
                            annotation(inPrevious ? "Finished work" : "Your lists", arrow: "arrow.up")
                        }
                        Spacer()
                        if feature == .classes { annotation("Classes", arrow: "arrow.up").padding(.trailing, 46) }
                        if feature == .add { annotation("Add task", arrow: "arrow.up") }
                    }
                    .accessibilityElement(children: .combine)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(feature?.title ?? (practiced ? "Almost there." : inPrevious ? "swipe left to undo" : "swipe right to finish"))
                            .font(.lhfSerif(26))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($instructionFocused)
                        Label(feature?.detail ?? (practiced ? "Smooth is finishing your first Canvas sync." : inPrevious ? "pull it left, or tap it, to put it back." : "pull the card to the right when you've turned something in."),
                              systemImage: feature != nil ? "info.circle" : inPrevious ? "arrow.left" : practiced ? "checkmark" : "arrow.right")
                            .font(.lhfSans(15, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let item = items.first {
                        if inPrevious {
                            nudged(direction: -1) {
                                DoneCardView(item: item, dayLabel: "Today", onTap: undo)
                            }
                        } else {
                            nudged(direction: practiced ? 0 : 1) {
                                AssignmentCardView(item: item, onComplete: complete, onEdit: {})
                                    .id(practiced)
                                    .allowsHitTesting(!practiced)
                                    .opacity(practiced ? 0.25 : 1)
                                    .accessibilityAction(named: "Mark complete", complete)
                            }
                        }
                    }
                    if !inPrevious {
                        ForEach(Array(items.dropFirst().prefix(2))) { item in
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
                        HStack {
                            if let feature, feature != .lists {
                                Button("Back") { change { progress.back() } }
                                    .font(.lhfSans(14))
                                    .frame(minWidth: 44, minHeight: 48)
                            }
                            Button(action: advance) {
                                HStack {
                                    if progress.step == .ready && !isReady {
                                        ProgressView().tint(Color.smoothPaper)
                                    }
                                    Text(progress.step == .ready ? (isReady ? "Continue" : "Syncing Canvas…") : (feature == .settings ? "Continue" : "Next"))
                                }
                                .font(.lhfSans(16, weight: .semibold))
                                .foregroundStyle(Color.smoothPaper)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Color.smoothInk, in: Capsule())
                            }
                            .disabled(progress.step == .ready && !isReady)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(isReady ? "Canvas is ready when you are." : "Syncing your Canvas…")
                            .font(.lhfSans(12))
                            .foregroundStyle(Color.smoothMuted)
                    }
                }
                Spacer(minLength: 0)
                if feature == .assistant {
                    annotation("Ask AI", arrow: "arrow.right")
                }
                SmoothStarMark(size: 58)
                    .frame(width: 60, height: 60)
                    .modifier(FeatureHighlight(active: feature == .assistant))
                    .accessibilityLabel("AI: ask about your classes")
            }
            .padding(20)
        }
        .foregroundStyle(Color.smoothInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.smoothPaper.ignoresSafeArea())
        .onAppear { instructionFocused = true }
        .onChange(of: progress.step) { _, _ in
            instructionFocused = true
            nudging = true
        }
    }

    private var skipBar: some View {
        HStack {
            Spacer()
            Button("skip") { skip() }
                .font(.lhfSans(14, weight: .medium))
                .foregroundStyle(Color.v2DateText)
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
    }

    /// A slow hint that the card moves: out about 22pt in the swipe's
    /// direction, back, a rest, until the first touch. The offset sits on this
    /// wrapper because the card views own their own drag and must not see it.
    /// One branch on purpose: switching between two `content()` branches when
    /// `nudging` flips would rebuild the card mid-drag and kill the student's swipe.
    private func nudged<Content: View>(direction: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .phaseAnimator([false, true]) { view, out in
                view.offset(x: (nudging && !reduceMotion && direction != 0 && out) ? 22 * direction : 0)
            } animation: { out in
                // Rest at home: wait, slide out, ease back, wait.
                out ? .easeInOut(duration: 0.7).delay(1.2) : .easeInOut(duration: 0.5)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in nudging = false })
    }

    private func skip() {
        change { progress.skip() }
        if progress.canContinue(syncReady: isReady) { onContinue() }
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
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 7) {
                        headerIcon("megaphone.fill", color: .smoothMarigold)
                            .modifier(FeatureHighlight(active: feature == .announcements))
                        if feature == .announcements { annotation("", arrow: "arrow.up") }
                    }
                    VStack(spacing: 7) {
                        headerIcon("person.crop.circle.fill", color: .smoothTeal)
                            .modifier(FeatureHighlight(active: feature == .settings))
                        if feature == .settings { annotation("", arrow: "arrow.up") }
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
    }

    private func annotation(_ text: String, arrow: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: arrow)
            if !text.isEmpty { Text(text) }
        }
        .font(.lhfSans(11, weight: .semibold))
        .foregroundStyle(Color.smoothCobaltInk)
        .fixedSize(horizontal: false, vertical: true)
    }


    private func advance() {
        if progress.canContinue(syncReady: isReady) { onContinue() }
        else {
            change { progress.next() }
            if progress.canContinue(syncReady: isReady) { onContinue() }
        }
    }

    private func change(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2), action)
    }

    private func complete() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { progress.complete() }
    }

    private func undo() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { progress.undo() }
    }
}

private struct FeatureHighlight: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0.5)
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(Color.smoothCobaltInk, lineWidth: 2)
                        .padding(-4)
                }
            }
    }
}
