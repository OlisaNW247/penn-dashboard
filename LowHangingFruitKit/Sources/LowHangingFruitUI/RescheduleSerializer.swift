import Foundation

/// Runs at most one pass at a time and folds the calls that arrive meanwhile
/// into one more pass with the latest input.
///
/// **Why `NotificationScheduler.reschedule` needs this.** A pass is a chain of
/// awaits: the notification permission refresh, the alarm permission prompt,
/// up to sixty `center.add` calls, AlarmKit's `schedule`. The main actor is
/// free at every one of them, so a second pass can start in the middle of the
/// first. It does: answering the alarm prompt reactivates the scene, which
/// starts the dashboard's own refresh, which calls `reschedule`. Two passes
/// then read the same empty list of alarms and schedule the same ids, one of
/// them meets an error for the duplicate and falls back to the buzzes while
/// the other goes on scheduling, and the student is left with both alerts, or
/// with neither.
///
/// **How.** `submit` while idle runs the pass, then runs it again with the
/// newest input for as long as calls kept arriving while it ran. `submit`
/// while a pass is running records its input as the latest (replacing any
/// earlier waiting one: the plan is a function of the items, so only the last
/// matters) and returns at once. Callers keep awaiting as before, with one
/// difference to know about: **a call that arrives during a pass can return
/// before its own input has been applied.** It is applied by the rerun the
/// running pass makes before it finishes, so by the time the first caller's
/// `await` returns, every input anyone submitted has been applied or
/// superseded by a newer one. The wrong fix is a lock that makes the second
/// caller wait its turn: that queues a pass per call (a dashboard refresh and
/// a preference change would each cost a full cancel-and-re-add of sixty
/// notifications), and every one but the last is thrown away by the next.
///
/// The `perform` closure of a call that was folded in is never called; the
/// running pass's closure handles the rerun, which is why every caller must
/// pass an equivalent one.
@MainActor
final class RescheduleSerializer<Input> {
    private(set) var isRunning = false
    private var latest: Input?

    init() {}

    func submit(_ input: Input, perform: @MainActor (Input) async -> Void) async {
        guard !isRunning else {
            latest = input
            return
        }
        isRunning = true
        var current = input
        while true {
            await perform(current)
            guard let next = latest else { break }
            latest = nil
            current = next
        }
        isRunning = false
    }
}
