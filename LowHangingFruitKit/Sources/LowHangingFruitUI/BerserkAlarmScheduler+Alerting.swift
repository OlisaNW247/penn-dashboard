#if canImport(AlarmKit) && os(iOS)
import Foundation
import AlarmKit

// Berserk mode, the takeover screen's three questions to AlarmKit: which
// alarms are ringing now, when that changes, and the student's own stop from
// inside the app. Their declarations and the defaults for a backend without
// AlarmKit are on `BerserkAlarmBackend` (`BerserkAlarmDelivery.swift`); the
// reason for them is `BerserkTakeover.swift`.
//
// A separate file, and an extension, so that `BerserkAlarmScheduler.swift` is
// untouched. Same conditional and same availability as that file: not compiled
// for the macOS slice `swift test` builds, and nothing here is exercised by it.

@available(iOS 26.0, *)
extension BerserkAlarmScheduler {

    /// The ids of the alarms ringing right now, or nil when AlarmKit could
    /// not be read. Nil and not "none" on purpose: the host dismisses a shown
    /// takeover whose alarm is no longer ringing and remembers that alarm as
    /// answered, so one failed read reported as "nothing is ringing" would
    /// silence the screen for an alarm that is still going and never let it
    /// back. Unknown is judged as nothing at all.
    func alertingAlarmIDs() -> [UUID]? {
        guard let alarms = try? AlarmManager.shared.alarms else { return nil }
        return alarms.filter { $0.state == .alerting }.map(\.id)
    }

    /// The ringing alarms' ids, again, every time AlarmKit reports a change.
    ///
    /// `alarmUpdates` is an `AsyncSequence` of the whole alarm list; this
    /// reduces it to the ids that matter and hands it on as an `AsyncStream`
    /// so the protocol (which a test fake and the macOS slice must satisfy)
    /// names no AlarmKit type. The task that reads AlarmKit is cancelled when
    /// the consumer stops listening, so a host whose `.task` restarts on a
    /// scene-phase change never leaves an orphan reader behind.
    func alertingUpdates() -> AsyncStream<[UUID]> {
        AsyncStream<[UUID]> { continuation in
            let reader = Task {
                for await alarms in AlarmManager.shared.alarmUpdates {
                    continuation.yield(alarms.filter { $0.state == .alerting }.map(\.id))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }

    /// The student's own stop, from inside the app: stop it, then cancel it so
    /// it is not left behind in the list. Errors are ignored on purpose: an
    /// alarm that is already gone (stopped from the lock screen a moment
    /// ago) is the outcome that was wanted.
    func stopAlarm(id: UUID) {
        try? AlarmManager.shared.stop(id: id)
        try? AlarmManager.shared.cancel(id: id)
    }
}
#endif
