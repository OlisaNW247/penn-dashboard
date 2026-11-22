import SwiftUI
import LowHangingFruitKit

/// The rules of the one-time overdue swipe lesson: a student who updates with
/// unfinished work five or more days past due is shown, once, how to clear a
/// card with a swipe, on one of their own cards. Pure, so the boundaries are
/// testable without a view.
enum OverdueSwipeLesson {
    nonisolated static let minimumOverdueDays = 5

    /// A row more than this many days late is not offered: a recycled Canvas
    /// site keeps last year's rows (CLAUDE.md, the term trap), and "387 days
    /// late" over work the student has never seen teaches nothing.
    nonisolated static let maximumOverdueDays = 60

    /// The most overdue unfinished item that is at least five whole days late
    /// (exactly five counts; four days and 23 hours does not) and at most 60.
    /// `due` is the override-aware date, because a date the student moved is
    /// the date the card shows and the one that decides whether it is late.
    /// Only work that is really owed: not an item an instructor cancelled (an
    /// applied fact; the dashboard files it under "cancelled"), not a calendar
    /// event and not a nothing-to-submit item, since "pull it right once it's
    /// done" over a lecture says something false (3.5.0 test pass, R-M3, R-L6).
    nonisolated static func candidate(in items: [DashItem], now: Date) -> DashItem? {
        let cutoff = now.addingTimeInterval(-Double(minimumOverdueDays) * 86_400)
        let oldest = now.addingTimeInterval(-Double(maximumOverdueDays + 1) * 86_400)
        return items
            .filter { !$0.isCompleted && !$0.isFactCancelled && !$0.requiresNoSubmission
                && $0.assignment.kind != .event
                && ($0.due.map { $0 <= cutoff && $0 > oldest } ?? false) }
            .sorted(by: DashItem.isOrderedByDueDate)
            .first
    }

    /// Whole days late, floored.
    nonisolated static func overdueDays(of item: DashItem, now: Date) -> Int {
        guard let due = item.due else { return 0 }
        return max(0, Int(floor(now.timeIntervalSince(due) / 86_400)))
    }

    /// Onboarding and the update wall are excluded structurally: the dashboard
    /// (`ContentView`) is only in the tree past onboarding and off the wall.
    /// A fresh install that just did the practice lesson is excluded because
    /// the lesson marks the store shown (`OnboardingView.beginCanvasWalkthrough`).
    nonisolated static func shouldShow(hasCandidate: Bool, alreadyShown: Bool,
                                       usingFixtureData: Bool, reconnecting: Bool) -> Bool {
        hasCandidate && !alreadyShown && !usingFixtureData && !reconnecting
    }

    #if DEBUG
    nonisolated static let forceArgument = "-LHFForceOverdueLesson"
    nonisolated static var isForced: Bool { ProcessInfo.processInfo.arguments.contains(forceArgument) }
    #else
    nonisolated static var isForced: Bool { false }
    #endif

    /// For the forced launch: the first unfinished item whatever its date, or,
    /// with none, a practice card made six days late. Used only to look at the
    /// screen; the shown key is not written, so it can be opened repeatedly.
    nonisolated static func forcedCandidate(in items: [DashItem], now: Date) -> DashItem {
        if let first = items.first(where: { !$0.isCompleted }) { return first }
        var item = PracticeCards.fallback(now: now)[0]
        item.dueOverride = now.addingTimeInterval(-6 * 86_400)
        return item
    }
}

/// Whether the lesson has been shown. `UserDefaults.lhf` (tier 2, a preference:
/// cheap to lose, meaningless off the device, see Persistence/SharedDefaults.swift)
/// and never the ledger, which holds the student's work and is never touched
/// for a thing like this.
struct OverdueSwipeLessonStore {
    nonisolated static let key = "overdueSwipeLessonShownV1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .lhf) { self.defaults = defaults }

    var hasShown: Bool { defaults.bool(forKey: Self.key) }
    func markShown() { defaults.set(true, forKey: Self.key) }
}

struct OverdueSwipeLessonView: View {
    let item: DashItem
    let overdueDays: Int
    let onCommit: () -> Void
    let onComplete: () -> Void
    let onDismiss: () -> Void

    @State private var swiped = false
    /// Off at the first touch, and never on under Reduce Motion.
    @State private var nudging = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("not now", action: onDismiss)
                    .font(.lhfSans(14, weight: .medium))
                    .foregroundStyle(Color.v2DateText)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(swiped ? "cleared." : "swipe right to clear it")
                        .font(.lhfSerif(26))
                        .accessibilityAddTraits(.isHeader)
                    Label(swiped ? "that's all a swipe does." : "\(overdueDays) days late. pull it right once it's done.",
                          systemImage: swiped ? "checkmark" : "arrow.right")
                        .font(.lhfSans(15, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                nudged(direction: swiped ? 0 : 1) {
                    AssignmentCardView(item: item,
                                       onComplete: { swiped = true; onComplete() },
                                       onCommit: onCommit,
                                       onEdit: {})
                        .allowsHitTesting(!swiped)
                        .opacity(swiped ? 0.25 : 1)
                        .accessibilityAction(named: "Mark complete") { onCommit(); swiped = true; onComplete() }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)

            if swiped {
                Button(action: onDismiss) {
                    Text("done")
                        .font(.lhfSans(16, weight: .semibold))
                        .foregroundStyle(Color.smoothPaper)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.smoothInk, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(20)
            }
        }
        .foregroundStyle(Color.smoothInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.smoothPaper.ignoresSafeArea())
    }

    /// The practice lesson's nudge, verbatim: a slow hint that the card moves,
    /// on a wrapper because the card owns its own drag. One branch on purpose:
    /// switching branches when `nudging` flips would rebuild the card mid-drag.
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
}
