import Foundation
import LowHangingFruitKit

/// What an opened card offers to take away, if anything: the student's own
/// work, and only that.
///
/// A one-off task (the + sheet's "one-off") can be deleted. An occurrence of a
/// recurring task cannot be deleted, because the next rebuild would mint it
/// again from its rule; what the student means by removing one is to end the
/// rule, so that is what the card offers instead. Everything else on the
/// dashboard belongs to Canvas, Gradescope or an announcement and reappears
/// from its feed, so it offers nothing.
///
/// A pure rule over the `Assignment`, with the card's words beside it, so the
/// decision and the strings are tested without a view. The card gets the answer
/// from `DashItem.removal`, snapshotted when the view model reloads, for the
/// reason `DashItem.requiresNoSubmission` is: the card holds no `AppState`.
enum OwnTaskRemoval: Equatable {
    /// A one-off task, by its `ManualAssignment.id`.
    case deleteTask(id: UUID)
    /// An occurrence of a recurring task, by the `RecurringTask.id` that minted it.
    case stopRepeating(taskID: UUID)

    /// The decision. Nothing in preview or demo data: those items are bundled
    /// fixtures whose ids belong to no stored task, and a reviewer's tap must
    /// not reach the student's real defaults (the same rule as
    /// `AppState.setDueDateEdit`).
    ///
    /// The switch is exhaustive on purpose, so a new `Assignment.Source` has to
    /// choose here instead of silently inheriting "nothing".
    static func offered(for assignment: Assignment, isUsingFixtureData: Bool) -> OwnTaskRemoval? {
        guard !isUsingFixtureData else { return nil }
        switch assignment.source {
        case .manual:
            // `.manual` is shared by two producers; the sourceID tells them
            // apart (see the note above `RecurringTask.occurrenceSourceID`).
            if let own = ManualAssignment(assignment) {
                return .deleteTask(id: own.id)
            }
            return RecurringTask.occurrenceTaskID(fromSourceID: assignment.sourceID)
                .map { .stopRepeating(taskID: $0) }
        case .canvasSuggestion:
            // Minted only by `RecurringTask`, so any such item is an occurrence.
            return RecurringTask.occurrenceTaskID(fromSourceID: assignment.sourceID)
                .map { .stopRepeating(taskID: $0) }
        case .canvas, .gradescope, .canvasModules, .canvasAnnouncement:
            return nil
        }
    }

    // MARK: The card's words

    /// The button on the opened card.
    var buttonLabel: String {
        switch self {
        case .deleteTask:   return "delete"
        case .stopRepeating: return "stop repeating"
        }
    }

    /// What VoiceOver says for the button; "delete" alone does not say what.
    var accessibilityLabel: String {
        switch self {
        case .deleteTask:   return "delete task"
        case .stopRepeating: return "stop repeating task"
        }
    }

    /// The confirmation dialog's title.
    var confirmationTitle: String {
        switch self {
        case .deleteTask:   return "delete this task?"
        case .stopRepeating: return "stop repeating?"
        }
    }

    /// The dialog's destructive button.
    var confirmLabel: String {
        switch self {
        case .deleteTask:   return "delete"
        case .stopRepeating: return "stop"
        }
    }

    /// The dialog's other button.
    static let cancelLabel = "cancel"
}
