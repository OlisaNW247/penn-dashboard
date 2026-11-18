import Foundation
import LowHangingFruitKit

/// What to cancel when work is confirmed submitted: every reminder request and
/// every Sweeper alarm id the item could have been scheduled under. Pure, so
/// the cancel is a table in a test.
///
/// An item matches when its own id, its `linkedID` (a paired Gradescope or
/// hidden twin) or its Canvas assignment id is in the submitted set, so a
/// Canvas read, a ledger tick and a twin's tick all land on the same card.
///
/// **Every option, not the current one**, as `BerserkTakeoverRules.alarmIndex`
/// does: an alarm scheduled before the student changed the lead time or sound
/// can still be pending. Alarm ids come from the one function
/// (`BerserkAlarmPlan.alarmID`) with the planner's own arithmetic (fire time
/// is due minus lead, against `assignment.id`); a second copy of that
/// arithmetic would produce ids nothing scheduled.
enum SubmissionObservation {
    nonisolated static func cancellations(
        submittedAssignmentIDs: Set<String>,
        items: [DashItem]
    ) -> (requestIDs: [String], alarmIDs: Set<UUID>) {
        var requestIDs: [String] = []
        var alarmIDs = Set<UUID>()
        for item in items {
            let a = item.assignment
            guard submittedAssignmentIDs.contains(item.id)
                    || (a.linkedID.map(submittedAssignmentIDs.contains) ?? false)
                    || (a.canvasAssignmentID.map(submittedAssignmentIDs.contains) ?? false)
            else { continue }
            for offset in LeadOffset.allCases {
                requestIDs.append("\(NotificationScheduler.requestIdentifierPrefix)\(a.id):\(offset.rawValue)")
            }
            guard let due = item.due else { continue }
            for minutes in NotificationScheduler.sweeperMinuteOptions {
                let fireDate = due.addingTimeInterval(-TimeInterval(minutes * 60))
                for sound in SweeperSound.allCases {
                    alarmIDs.insert(BerserkAlarmPlan.alarmID(assignmentID: a.id, fireDate: fireDate, sound: sound))
                }
            }
        }
        return (requestIDs, alarmIDs)
    }
}
