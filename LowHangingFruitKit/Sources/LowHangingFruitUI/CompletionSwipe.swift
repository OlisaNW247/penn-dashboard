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
}
