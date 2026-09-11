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
    @State private var dragX: CGFloat = 0
    @State private var isExpanded = false
    @State private var isCompleting = false
    @State private var completionBurst = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let corner: CGFloat = 18

    /// How far right the card has to travel to count as "done". Roughly a
    /// thumb's width: far enough that a stray horizontal nudge while scrolling
    /// doesn't reach it, short enough to be one comfortable motion.
    private let completeThreshold: CGFloat = 96

    /// Past the threshold the card stops following the finger. Without a cap a
    /// long drag pulls the card off its own row and the reveal behind it reads
    /// as a second, empty card.
    private let maxDrag: CGFloat = 132

    var body: some View {
        let now = Date()
        let state = item.state(now: now)

        return ZStack(alignment: .leading) {
            completeReveal
            card(now: now)
                .offset(x: dragX)
                .scaleEffect(isCompleting && !reduceMotion ? 1.012 : 1)
                .rotationEffect(.degrees(isCompleting && !reduceMotion ? -0.7 : 0))
        }
        .opacity(exitOpacity)
        .offset(y: exitOffset)
        .overlay(alignment: .trailing) {
            if isCompleting && !reduceMotion {
                completionBurstView
                    .padding(.trailing, 22)
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

    /// The green field behind the card, uncovered as it slides. Its checkmark
    /// only appears once the drag is far enough to be read as intent, so a small
    /// nudge shows a hint of colour rather than promising an action it won't
    /// take.
    private var completeReveal: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color.smoothTeal)
            .overlay(alignment: .leading) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.smoothInk)
                    .padding(.leading, 20)
                    .opacity(dragX >= completeThreshold ? 1 : 0.45)
                    .scaleEffect(dragX >= completeThreshold ? 1.15 : 1)
            }
            .opacity(dragX > 1 ? 1 : 0)
    }

    private func completeDrag(state: DueState) -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onChanged { value in
                // Vertical intent belongs to the ScrollView. Checking this on
                // every change (not just the first) keeps a diagonal drag from
                // dragging the card sideways while the list scrolls under it.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = min(max(0, value.translation.width), maxDrag)
            }
            .onEnded { _ in
                if dragX >= completeThreshold {
                    triggerComplete(state: state)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragX = 0 }
                }
            }
    }

    private func triggerComplete(state: DueState) {
        guard !isCompleting else { return }
        isCompleting = true
        lhfHaptic(for: state)

        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                dragX = maxDrag + 40
                exitOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onComplete() }
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
            dragX = maxDrag
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.62)) {
                completionBurst = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            withAnimation(.easeIn(duration: 0.28)) {
                dragX = maxDrag + 56
                exitOffset = -8
                exitOpacity = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.58) { onComplete() }
    }

    private var completionBurstView: some View {
        ZStack {
            Circle()
                .stroke(Color.smoothTeal.opacity(0.48), lineWidth: 2)
                .frame(width: 46, height: 46)
                .scaleEffect(completionBurst ? 1.7 : 0.78)
                .opacity(completionBurst ? 0 : 0.72)

            Circle()
                .fill(Color.smoothTeal)
                .frame(width: 46, height: 46)
                .shadow(color: Color.smoothTealInk.opacity(0.16), radius: 7, y: 3)

            Image(systemName: "checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.smoothPaper)
                .rotationEffect(.degrees(completionBurst ? 0 : -14))

            ForEach(Array(Self.burstOffsets.enumerated()), id: \.offset) { index, offset in
                Image(systemName: Self.burstSymbols[index])
                    .font(.system(size: index.isMultiple(of: 3) ? 7 : 6, weight: .bold))
                    .foregroundStyle(Self.burstColors[index])
                    .offset(completionBurst ? offset : .zero)
                    .rotationEffect(.degrees(completionBurst ? Double(index * 38) : 0))
                    .opacity(completionBurst ? 0 : 1)
            }
        }
        .scaleEffect(completionBurst ? 1 : 0.62)
        .opacity(completionBurst ? 1 : 0)
    }

    private static let burstOffsets: [CGSize] = [
        CGSize(width: -34, height: -24), CGSize(width: 0, height: -38),
        CGSize(width: 34, height: -22), CGSize(width: 38, height: 18),
        CGSize(width: 10, height: 40), CGSize(width: -28, height: 34),
        CGSize(width: -42, height: 2), CGSize(width: 42, height: -4),
    ]

    private static let burstColors: [Color] = [
        .smoothTomato, .smoothMarigold, .smoothLemon,
        .smoothTeal, .smoothMarigold, .smoothCobalt,
        .smoothGrape, .smoothTomato,
    ]

    private static let burstSymbols = [
        "circle.fill", "diamond.fill", "triangle.fill", "star.fill",
        "diamond.fill", "circle.fill", "star.fill", "triangle.fill",
    ]
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
