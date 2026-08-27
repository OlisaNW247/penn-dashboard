import SwiftUI
import LowHangingFruitKit

/// An active (incomplete) assignment card: white surface, 13pt corners, soft
/// shadow, and a 6pt urgency-colored spine on the left edge.
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

    private let corner: CGFloat = 13

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
            card(state: state, now: now)
                .offset(x: dragX)
        }
        .opacity(exitOpacity)
        .offset(y: exitOffset)
        .gesture(completeDrag(state: state))
        // Swipe is invisible to VoiceOver, so completing needs a spoken action
        // of its own. Without this the feature would simply not exist for
        // anyone navigating by rotor.
        .accessibilityAction(named: "mark complete") { triggerComplete(state: state) }
    }

    // MARK: The card

    private func card(state: DueState, now: Date) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(state.spineColor)
                .frame(width: 6)

            // Deliberately a tap gesture, not a Button. A Button consumes the
            // touch sequence, so the swipe below never reached the card: a
            // horizontal drag registered as a tap and merely expanded it. Tap
            // gestures don't claim drags, which leaves the horizontal one to
            // this card and the vertical one to the ScrollView.
            VStack(alignment: .leading, spacing: 0) {
                content(state: state, now: now)
                if isExpanded { expandedDetail(now: now) }
            }
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
                lhfHapticLight()
            }
            // Losing the Button also loses what it told VoiceOver, so the trait
            // and the actions are restored by hand.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "double tap to collapse" : "double tap for details")
        }
        .background(Color.v2Card)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: Color.v2CardShadow.opacity(0.06), radius: 2, y: 1)
    }

    private func content(state: DueState, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
                    .font(.lhfSans(9.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.v2CourseCode)

                Text(item.assignment.title)
                    .font(.lhfSans(14, weight: .medium))
                    .foregroundStyle(Color.v2Ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Visible on the collapsed card, not only once expanded — a
                // student scanning the list needs to know "nothing to turn in
                // here" without opening every card. Kept to one small line
                // under the title (not stacked onto the course-code row,
                // which is already doing the "find your class" job) so it
                // reads as a caveat about this one item rather than crowding
                // the thing that actually identifies the card. Covers both
                // Canvas no-submission assignments and readings/events —
                // see `DashItem.showsNothingToSubmit`.
                if item.showsNothingToSubmit {
                    Text("nothing to submit")
                        .font(.lhfSans(9, weight: .semibold))
                        .foregroundStyle(Color.v2CourseCode)
                }
            }

            Spacer(minLength: 8)

            // The due date is the one thing this card exists to tell you, and
            // it used to be 11pt beside a calendar glyph of equal weight. With
            // the glyph gone it takes the corner outright.
            VStack(alignment: .trailing, spacing: 2) {
                Text(dueText(item.due, now: now))
                    .font(.lhfSans(13.5, weight: .semibold))
                    .foregroundStyle(state.dueTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if item.dueOverride != nil {
                    Text("adjusted")
                        .font(.lhfSans(8.5))
                        .foregroundStyle(Color.v2CourseCode)
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
                .fill(Color.v2Divider)
                .frame(height: 0.5)
                .padding(.top, 12)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("due")
                        .font(.lhfSans(9, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(Color.v2CourseCode)
                    Text(fullDueText(item.due))
                        .font(.lhfSans(12.5, weight: .medium))
                        .foregroundStyle(Color.v2Ink)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button { onEdit() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .medium))
                        Text("edit date")
                            .font(.lhfSans(12, weight: .medium))
                    }
                    .foregroundStyle(Color.v2SpineBlue)
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
                    .font(.lhfSans(11.5))
                    .foregroundStyle(.secondary)
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
            .fill(Color.v2SpineGreen)
            .overlay(alignment: .leading) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
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
        lhfHaptic(for: state)
        withAnimation(.easeIn(duration: 0.28)) {
            // Finish the direction the finger was already going, rather than
            // snapping back and then leaving upward, which reads as a rejected
            // gesture followed by an unrelated deletion.
            dragX = maxDrag + 40
            exitOpacity = 0
        }
        // Defer the data mutation until the exit animation finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            onComplete()
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
