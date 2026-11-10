import SwiftUI
import LowHangingFruitKit

/// "Done" tab — completed assignments styled as archived: greige surface, muted
/// grey spine, green check, strikethrough title. Tap or swipe left to undo.
///
/// Leads with the week's count ("4 down this week") rather than ending on it:
/// with a whole semester of finished work below, the one number worth seeing
/// sat at the bottom of a long scroll. Only this week's cards show by
/// default; the rest of the semester waits behind a single "earlier this
/// semester" row that opens in place, so the tab reads as "this week's
/// progress" first and an archive second.
struct DoneView: View {
    let sections: [DashSection]
    let weeklyDone: Int
    let onUncomplete: (DashItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEarlier = false

    private var thisWeek: DashSection? { sections.first { $0.id == "doneWeek" } }
    private var earlier: DashSection? { sections.first { $0.id == "doneSemester" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)

            if let thisWeek {
                cards(for: thisWeek)
            }

            if let earlier {
                earlierToggle(count: earlier.items.count)

                if showsEarlier {
                    VStack(alignment: .leading, spacing: 10) {
                        cards(for: earlier)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if weeklyDone > 0 {
                Text("\(weeklyDone) down this week.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
                Text("nice pace.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            } else if !sections.isEmpty {
                // Completed work exists, it just wasn't finished this week —
                // don't claim "nothing done yet.".
                Text("nothing new this week.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
            } else {
                Text("nothing done yet.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
                Text("let's fix that.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            }
        }
        .padding(.top, sections.isEmpty ? 60 : 0)
    }

    private func cards(for section: DashSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(section.items) { item in
                DoneCardView(
                    item: item,
                    dayLabel: section.dayLabel?(item),
                    onTap: { onUncomplete(item) }
                )
                .transition(.opacity)
            }
        }
    }

    private func earlierToggle(count: Int) -> some View {
        DisclosureRow(title: "earlier this semester", count: count, isOpen: showsEarlier) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                showsEarlier.toggle()
            }
        }
    }
}

/// A completed card keeps its original deadline fill at reduced opacity.
struct DoneCardView: View {
    let item: DashItem
    let dayLabel: String?
    let onTap: () -> Void

    @Environment(\.courseNameOverrides) private var courseNameOverrides

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0
    @State private var didUndo = false
    /// Held for one drag; see `CompletionSwipe.Axis`.
    @State private var swipeAxis: CompletionSwipe.Axis = .undecided
    private let corner: CGFloat = 18

    var body: some View {
        ZStack(alignment: .trailing) {
            if dragX < -18 {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(Color.smoothCobaltInk)
                    .padding(.trailing, 18)
                    .accessibilityHidden(true)
            }
            card.offset(x: dragX)
        }
        .contentShape(RoundedRectangle(cornerRadius: corner))
        .onTapGesture { if item.canMarkActive { undo() } }
        // Simultaneous so a scroll that starts on a finished card still
        // scrolls; the axis is decided once per drag (CompletionSwipe.Axis).
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    if swipeAxis == .undecided {
                        swipeAxis = CompletionSwipe.axis(
                            width: value.translation.width,
                            height: value.translation.height
                        )
                    }
                    guard item.canMarkActive, !didUndo, swipeAxis == .horizontal else { return }
                    dragX = max(-86, min(0, value.translation.width))
                }
                .onEnded { value in
                    let wasHorizontal = swipeAxis == .horizontal
                    swipeAxis = .undecided
                    guard item.canMarkActive, wasHorizontal else { return }
                    if CompletionSwipe.accepts(horizontal: value.translation.width,
                                               vertical: value.translation.height,
                                               predicted: value.predictedEndTranslation.width,
                                               undo: true) {
                        undo()
                    } else {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)) {
                            dragX = 0
                        }
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.canMarkActive ? .isButton : [])
        .accessibilityHint(item.canMarkActive ? "Tap or swipe left to mark incomplete" : "turned in on canvas")
        .accessibilityAction { if item.canMarkActive { undo() } }
        .accessibilityActionIf(item.canMarkActive, named: "Mark incomplete") { undo() }
    }

    private func undo() {
        guard item.canMarkActive, !didUndo else { return }
        didUndo = true
        lhfHapticLight()
        // Persist immediately through the existing onUncomplete path. There
        // is no delayed animation callback that could lose the user's action.
        onTap()
        // The latch used to stay set, on the assumption that the row always
        // leaves the list once it is un-ticked. A Canvas-submitted item does
        // not leave, so the card sat frozen at its dragX and ignored every
        // later drag. If the row is still on screen, spring it home and make
        // it usable again; `didUndo` only guards re-entrancy within one gesture.
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8)) {
            dragX = 0
        }
        didUndo = false
    }

    private var card: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.assignment.displayCourse(overrides: courseNameOverrides).uppercased())
                    .font(.lhfMono(9.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(smoothTaskTextAccent(item.due))
                Text(item.assignment.title)
                    .font(.lhfAssignmentTitle(20))
                    .foregroundStyle(Color.smoothInk)
                    .strikethrough(true, color: Color.smoothInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if let dayLabel {
                Text(dayLabel)
                    .font(.lhfMono(15, weight: .medium))
                    .foregroundStyle(Color.smoothInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(smoothTaskFill(item.due))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .opacity(0.55)
    }
}

private extension View {
    /// Offers a named accessibility action only when `condition` holds.
    @ViewBuilder
    func accessibilityActionIf(_ condition: Bool, named name: String, _ handler: @escaping () -> Void) -> some View {
        if condition { accessibilityAction(named: name, handler) } else { self }
    }
}
