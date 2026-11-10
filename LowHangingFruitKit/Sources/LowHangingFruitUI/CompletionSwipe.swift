import Foundation

/// Shared by the completed cards and the onboarding practice card. A vertical
/// scroll, a small accidental nudge, or a flick in the wrong direction cannot
/// change completion. The same thresholds as the active assignment card apply.
enum CompletionSwipe {
    static func accepts(horizontal: Double, vertical: Double, predicted: Double, undo: Bool) -> Bool {
        let direction = undo ? -1.0 : 1.0
        let distance = horizontal * direction
        guard distance > abs(vertical) else { return false }
        return distance >= 68 || (distance >= 42 && predicted * direction >= 82)
    }

    /// Which way a drag on a card is going, decided once, from its first
    /// reported movement, and then held until the finger lifts.
    ///
    /// The card swipes are attached with `.simultaneousGesture` so the
    /// dashboard's ScrollView always receives the touch as well. A plain
    /// `.gesture` let the card's `DragGesture` claim any drag that began on
    /// it: the old per-change "vertical belongs to the ScrollView" guard
    /// ignored the movement, but by then the scroll had already lost the
    /// touch, so a scroll that started on a card (and an opened card covers
    /// most of the screen) stuck or stuttered. Running both at once moves the
    /// problem the other way: now the card must refuse a scroll, for the
    /// whole drag, or a slightly diagonal scroll would nudge it sideways
    /// mid-list. Hence one decision per drag rather than a test per change.
    ///
    /// The wrong fix is raising `minimumDistance`: it only delays the moment
    /// the card steals the scroll, and makes the swipe feel late.
    enum Axis: Equatable {
        case undecided, horizontal, vertical
    }

    /// Horizontal only when sideways clearly wins. A tie goes to the scroll,
    /// because a lost scroll is the bug this exists to prevent, while a lost
    /// swipe just means swiping again.
    static func axis(width: Double, height: Double) -> Axis {
        abs(width) > abs(height) ? .horizontal : .vertical
    }
}
