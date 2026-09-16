import SwiftUI
import LowHangingFruitKit

/// An active assignment rendered as a saturated Smooth ticket. The fill, the
/// section label, and the compact value all describe when it is due.
///
/// **Completing is a swipe right, not a tap.** Tapping the body used to
/// complete the assignment, which put the app's only destructive-feeling action
/// on its largest, most casually-touched target — a card brushed while scrolling
/// filed real work as done. Tapping now expands the card, and completing takes a
/// deliberate horizontal drag past a threshold.
///
/// **The gesture is written around a bug this file has already caused.** A card
/// once carried a zero-distance drag gesture, which swallowed the enclosing
/// ScrollView's pan and left the list unable to scroll at all (commit
/// `4fab17d`). So the drag here demands 18pt of travel before it engages *and*
/// ignores any drag whose vertical component dominates, which leaves an ordinary
/// scroll to the ScrollView. Expanding is a tap *gesture* rather than a `Button`
/// for a related reason: a Button consumes the whole touch sequence, so the
/// swipe never reached the card and a horizontal drag merely expanded it.
///
/// The calendar button is gone from the collapsed card. It sat permanently in
/// the corner competing with the due date for the same glance, for an action
/// almost nobody takes on any given card; it now lives in the expanded state,
/// which is the moment you have actually asked about this one assignment.
struct AssignmentCardView: View {
    let item: DashItem
    /// Called once the exit animation has finished.
    let onComplete: () -> Void
    let onEdit: () -> Void

    @Environment(\.courseNameOverrides) private var courseNameOverrides

    @State private var exitOpacity: Double = 1
    @State private var exitOffset: CGFloat = 0
    @State private var exitScale: CGFloat = 1
    @State private var dragX: CGFloat = 0
    @State private var isExpanded = false
    @State private var isCompleting = false
    @State private var paperScatter = false
    @State private var isArmed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let corner: CGFloat = 18

    /// A compact thumb nudge, rather than the old near-full-card pull. Fast
    /// flicks can complete a little earlier through predicted-end translation.
    private let completeThreshold: CGFloat = 68

    /// Past the threshold the card stops following the finger. Without a cap a
    /// long drag pulls the card off its own row and the reveal behind it reads
    /// as a second, empty card.
    private let maxDrag: CGFloat = 86

    private var dragProgress: CGFloat {
        min(max(dragX / completeThreshold, 0), 1)
    }

    var body: some View {
        let now = Date()
        let state = item.state(now: now)

        return ZStack(alignment: .leading) {
            card(now: now)
                .offset(x: dragX)
                // The card only lifts enough to separate from the page. The
                // prior stretch/rotation treatment made a routine action feel
                // rubbery and fought the quiet paper language of the dashboard.
                .scaleEffect(exitScale * (1 - (0.003 * dragProgress)))
                .offset(y: -1.5 * dragProgress)
                .shadow(
                    color: Color.smoothInk.opacity(Double(dragProgress) * 0.08),
                    radius: 2 + (4 * dragProgress),
                    x: 0,
                    y: 2 + (2 * dragProgress)
                )
        }
        .opacity(exitOpacity)
        .offset(y: exitOffset)
        .overlay(alignment: .leading) {
            if isCompleting && !reduceMotion {
                completionScatterView
                    .padding(.leading, 24)
                    .allowsHitTesting(false)
            }
        }
        .gesture(completeDrag(state: state))
        // Swipe is invisible to VoiceOver, so completing needs a spoken action
        // of its own. Without this the feature would simply not exist for
        // anyone navigating by rotor.
        .accessibilityAction(named: "mark complete") { triggerComplete(state: state) }
    }

    // MARK: The card

    private func card(now: Date) -> some View {
        // Deliberately a tap gesture, not a Button. A Button consumes the
        // touch sequence, so the swipe below never reached the card.
        VStack(alignment: .leading, spacing: 0) {
            content(now: now)
            if isExpanded { expandedDetail(now: now) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                isExpanded.toggle()
            }
            lhfHapticLight()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(isExpanded ? "double tap to collapse" : "double tap for details")
        .background(smoothTaskFill(item.due, now: now))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private func content(now: Date) -> some View {
        let value = smoothDueValue(item.due, now: now)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                // Bold: the course is how you find your way around this list.
                // Scanning for "the CIS one" is the actual reading pattern, and
                // at 9pt regular it was the faintest thing on the card.
                //
                // Readings/events used to carry a small book glyph here (a
                // second, separate way of saying "nothing to turn in") until
                // the owner's device pass found it and the caveat below
                // stating the same fact for two different reasons — one icon
                // vocabulary, one text vocabulary, for one idea. The caveat
                // is now the single marker (see `DashItem.showsNothingToSubmit`);
                // this row is back to being plain course-code text.
                Text(item.assignment.displayCourse(overrides: courseNameOverrides).uppercased())
                    .font(.lhfMono(9.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(smoothTaskTextAccent(item.due, now: now))

                Text(item.assignment.title)
                    .font(.lhfAssignmentTitle(20))
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)

                // Visible on the collapsed card, not only once expanded — a
                // student scanning the list needs to know "nothing to turn in
                // here" without opening every card. Kept to one small line
                // under the title (not stacked onto the course-code row,
                // which is already doing the "find your class" job) so it
                // reads as a caveat about this one item rather than crowding
                // the thing that actually identifies the card. Covers both
                // Canvas no-submission assignments and readings/events —
                // see `DashItem.showsNothingToSubmit` — and, since
                // 2026-09-09, the "from announcements" caveat on tasks the
                // Announcement Watcher extracted (`DashItem.isFromAnnouncement`),
                // joined onto the same line by `DashItem.caveatText`.
                if let caveat = item.caveatText {
                    Text(caveat)
                        .font(.lhfSecondary(9, weight: .semibold))
                        .foregroundStyle(Color.smoothInk.opacity(0.68))
                }
            }

            Spacer(minLength: 8)

            // The due date is the one thing this card exists to tell you, and
            // it used to be 11pt beside a calendar glyph of equal weight. With
            // the glyph gone it takes the corner outright.
            VStack(alignment: .trailing, spacing: 3) {
                Text(value.primary)
                    .font(.lhfMono(18, weight: .medium))
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let secondary = value.secondary {
                    Text(secondary)
                        .font(.lhfMono(8.5, weight: .semibold))
                        .foregroundStyle(Color.smoothInk.opacity(0.68))
                }
                if item.dueOverride != nil {
                    Text("adjusted")
                        .font(.lhfMono(8.5))
                        .foregroundStyle(Color.smoothInk.opacity(0.68))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Expanded

    /// Shown only once the card is opened. This is where the calendar went: at
    /// this point the student has singled this assignment out, so a date control
    /// is what they are most likely to want and costs nothing when collapsed.
    private func expandedDetail(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.smoothInk.opacity(0.22))
                .frame(height: 1)
                .padding(.top, 12)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("due")
                        .font(.lhfAssignmentTitle(9))
                        .tracking(0.5)
                        .foregroundStyle(Color.smoothInk.opacity(0.68))
                    Text(fullDueText(item.due))
                        .font(.lhfAssignmentTitle(12.5))
                        .foregroundStyle(Color.smoothInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button { onEdit() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .medium))
                        Text("edit date")
                            .font(.lhfAssignmentTitle(12))
                    }
                    .foregroundStyle(Color.smoothInk)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("edit due date")
            }

            // The collapsed tag says *that*; this says *why*, in the one
            // moment the student has actually asked about this assignment.
            // Same predicate as the collapsed tag — see
            // `DashItem.showsNothingToSubmit`.
            if item.showsNothingToSubmit {
                Text("canvas expects nothing to be submitted for this — attend, read, or do it on paper.")
                    .font(.lhfAssignmentTitle(11.5))
                    .foregroundStyle(Color.smoothInk.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func fullDueText(_ due: Date?) -> String {
        guard let due else { return "no due date" }
        return due.formatted(date: .complete, time: .shortened).lowercased()
    }

    // MARK: Swipe to complete

    private func completeDrag(state: DueState) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                // Vertical intent belongs to the ScrollView. Checking this on
                // every change (not just the first) keeps a diagonal drag from
                // dragging the card sideways while the list scrolls under it.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let nextDrag = min(max(0, value.translation.width), maxDrag)
                let nextArmed = nextDrag >= completeThreshold
                if nextArmed && !isArmed { lhfHapticLight() }
                isArmed = nextArmed
                dragX = nextDrag
            }
            .onEnded { value in
                let horizontalFlick = value.predictedEndTranslation.width >= completeThreshold + 14
                if isArmed || (dragX >= 42 && horizontalFlick) {
                    triggerComplete(state: state)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        dragX = 0
                        isArmed = false
                    }
                }
            }
    }

    private func triggerComplete(state: DueState) {
        guard !isCompleting else { return }
        isCompleting = true
        lhfHaptic(for: state)

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                dragX = maxDrag
                exitOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onComplete() }
            return
        }

        // One clean beat: let the card settle after the swipe, release a few
        // pieces of the same paper used by the empty state, and make room for
        // the next assignment. There is no label or confirmation icon.
        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
            dragX = completeThreshold + 3
            exitScale = 1.006
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                paperScatter = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.22)) {
                dragX = completeThreshold + 6
                exitScale = 0.94
                exitOffset = -6
                exitOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { onComplete() }
    }

    /// Six small, geometric paper pieces echo the empty-dashboard celebration
    /// without replaying its full confetti moment for every assignment.
    private var completionScatterView: some View {
        ZStack {
            ForEach(Array(Self.scatterPieces.enumerated()), id: \.offset) { index, piece in
                CompletionPaperPiece(shape: piece.shape)
                    .foregroundStyle(piece.color)
                    .offset(paperScatter ? piece.destination : .zero)
                    .rotationEffect(.degrees(paperScatter ? piece.rotation : 0))
                    .scaleEffect(paperScatter ? 1 : 0.2)
                    .opacity(paperScatter ? 0 : piece.opacity)
                    .animation(
                        .easeOut(duration: 0.32).delay(Double(index) * 0.014),
                        value: paperScatter
                    )
            }
        }
    }

    private static let scatterPieces: [CompletionPaper] = [
        .init(destination: .init(width: -13, height: -24), rotation: -38, color: .smoothTomato, shape: .ticket, opacity: 0.9),
        .init(destination: .init(width: 9, height: -31), rotation: 44, color: .smoothMarigold, shape: .dash, opacity: 0.86),
        .init(destination: .init(width: 29, height: -17), rotation: -28, color: .smoothCobalt, shape: .dot, opacity: 0.82),
        .init(destination: .init(width: 31, height: 12), rotation: 52, color: .smoothTeal, shape: .ticket, opacity: 0.88),
        .init(destination: .init(width: 6, height: 28), rotation: -48, color: .smoothGrape, shape: .dash, opacity: 0.82),
        .init(destination: .init(width: -18, height: 20), rotation: 30, color: .smoothLemon, shape: .dot, opacity: 0.86),
    ]
}

private struct CompletionPaper {
    enum Shape { case ticket, dash, dot }
    let destination: CGSize
    let rotation: Double
    let color: Color
    let shape: Shape
    let opacity: Double
}

private struct CompletionPaperPiece: View {
    let shape: CompletionPaper.Shape

    var body: some View {
        Group {
            switch shape {
            case .ticket:
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .frame(width: 10, height: 6)
            case .dash:
                Capsule().frame(width: 10, height: 3)
            case .dot:
                Circle().frame(width: 5, height: 5)
            }
        }
    }
}

#if DEBUG
#Preview("Active cards") {
    ScrollView {
        VStack(spacing: 12) {
            ForEach(SampleData.items().filter { !$0.isCompleted }) { item in
                AssignmentCardView(item: item, onComplete: {}, onEdit: {})
            }
        }
        .padding(16)
    }
    .background(Color.v2Bg)
}
#endif
