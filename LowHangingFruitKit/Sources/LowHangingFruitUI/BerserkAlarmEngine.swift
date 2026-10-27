import Foundation

// Berserk mode, the part of the AlarmKit glue that is only logic.
//
// `BerserkAlarmScheduler` (iOS 26, behind `#if canImport(AlarmKit)`) is a thin
// `BerserkAlarmStore` over `AlarmManager`. Everything that decides what to do
// with the store, which alarm to leave alone, what counts as a failure, is
// here instead, where a test on macOS can run it against an in-memory store.
// The first version had this inside the iOS-only class, and the two mistakes
// found in review (a ringing alarm silenced by an error path, a failed
// `schedule` that had in fact scheduled) were exactly the kind a macOS test
// could not see.

/// One alarm as the store reports it. `isRinging` is AlarmKit's `.alerting`.
struct StoredAlarm: Equatable, Sendable {
    let id: UUID
    let isRinging: Bool
}

/// The four AlarmKit calls the engine uses, as a protocol. The real
/// conformance is `BerserkAlarmScheduler`; tests use an in-memory store.
@MainActor
protocol BerserkAlarmStore: AnyObject {
    func storedAlarms() throws -> [StoredAlarm]
    func cancel(id: UUID) throws
    func stop(id: UUID) throws
    func schedule(_ planned: PlannedAlarm) async throws
}

@MainActor
enum BerserkAlarmEngine {

    /// Cancels the stale alarms and schedules the missing ones, and throws if
    /// the store ends up not holding the plan.
    ///
    /// **A ringing alarm is left alone.** The reschedule runs while the app is
    /// open, which is also when an alarm can be going off on top of it, and an
    /// alarm that has started ringing is no longer "wanted" by the plan (its
    /// time is past). Cancelling it would silence it for the student, so only
    /// the alarms that have not started ringing are offered to the diff.
    ///
    /// **A call that throws is judged by what the store holds, not by the
    /// throw.** AlarmKit can throw for an alarm that is in fact there (a
    /// duplicate id from another pass, an error after the work was done), and
    /// for a cancel of an alarm that has just gone away on its own (it fired,
    /// or the student stopped it). Both are the state the reconcile wanted, so
    /// after a throw the store is read again: a scheduled alarm that is present
    /// counts as scheduled, and a cancelled one that is absent counts as
    /// cancelled. Anything else is a real failure and is rethrown, and the
    /// caller falls back to the buzzes. The wrong fix is to treat every throw
    /// as a failure: that sends a student whose alarms are all fine to the
    /// buzzes, and (before the error path stopped touching ringing alarms)
    /// silenced one that was ringing.
    static func reconcile(_ plan: [PlannedAlarm], in store: any BerserkAlarmStore) async throws {
        let existing = try store.storedAlarms().filter { !$0.isRinging }.map(\.id)
        let diff = BerserkAlarmPlan.reconcile(desired: plan, existingIDs: existing)

        for id in diff.toCancel {
            do {
                try store.cancel(id: id)
            } catch {
                guard isAbsent(id, in: store) else { throw error }
            }
        }
        for planned in diff.toSchedule {
            do {
                try await store.schedule(planned)
            } catch {
                guard isPresent(planned.id, in: store) else { throw error }
            }
        }
    }

    /// Cancels every alarm that is not ringing. For an AlarmKit error and for
    /// "alarms are not usable right now": the student has not asked for
    /// silence, so a ringing alarm is not ours to stop.
    static func cancelIdle(in store: any BerserkAlarmStore) {
        guard let alarms = try? store.storedAlarms() else { return }
        for alarm in alarms where !alarm.isRinging {
            try? store.cancel(id: alarm.id)
        }
    }

    /// Cancels every alarm, ringing or not. Only for the student's own "off":
    /// the loud-alert switch, reminders off, preview mode,
    /// and alarm permission revoked.
    static func cancelAll(in store: any BerserkAlarmStore) {
        guard let alarms = try? store.storedAlarms() else { return }
        for alarm in alarms {
            try? store.cancel(id: alarm.id)
        }
    }

    /// Stops, then cancels, the ringing alarms that belong to finished work
    /// (`BerserkAlarmPlan.alertingIDsToStop`), and nothing else.
    static func stopRinging(among finished: Set<UUID>, in store: any BerserkAlarmStore) {
        guard !finished.isEmpty, let alarms = try? store.storedAlarms() else { return }
        let ids = BerserkAlarmPlan.alertingIDsToStop(
            alerting: alarms.filter(\.isRinging).map(\.id), finished: finished)
        for id in ids {
            try? store.stop(id: id)
            try? store.cancel(id: id)
        }
    }

    private static func isPresent(_ id: UUID, in store: any BerserkAlarmStore) -> Bool {
        (try? store.storedAlarms())?.contains { $0.id == id } ?? false
    }

    /// Absent only when the store could be read and the id is not in it: an
    /// unreadable store is not evidence of anything.
    private static func isAbsent(_ id: UUID, in store: any BerserkAlarmStore) -> Bool {
        guard let alarms = try? store.storedAlarms() else { return false }
        return !alarms.contains { $0.id == id }
    }
}
