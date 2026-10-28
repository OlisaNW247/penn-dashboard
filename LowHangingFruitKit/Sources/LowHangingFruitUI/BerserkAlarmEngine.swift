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

/// What a reconcile could not do, by alarm id. Empty lists mean the store
/// holds the plan.
struct BerserkReconcileReport: Equatable, Sendable {
    /// Wanted alarms the store does not hold after the pass.
    var unscheduled: [UUID] = []
    /// Alarms the plan does not want that are still there after the cancel and
    /// its one retry (idle ones: a ringing alarm is never offered for
    /// cancelling).
    var uncancelled: [UUID] = []

    var isClean: Bool { unscheduled.isEmpty && uncancelled.isEmpty }
}

@MainActor
enum BerserkAlarmEngine {

    /// Cancels the stale alarms and schedules the missing ones, and reports
    /// which of them it could not. Throws only when the store cannot be read
    /// at all, because then nothing is known about any alarm.
    ///
    /// **A ringing alarm is left alone.** The reschedule runs while the app is
    /// open, which is also when an alarm can be going off on top of it, and an
    /// alarm that has started ringing is no longer "wanted" by the plan (its
    /// time is past). Cancelling it would silence it for the student, so only
    /// the alarms that have not started ringing are offered to the diff.
    ///
    /// **One alarm's failure is that alarm's, not the pass's.** This used to
    /// throw at the first call that failed, which did two things at once: the
    /// alarms after it in the diff were never tried, and the caller read the
    /// throw as "AlarmKit does not work", put the buzzes back for every item
    /// and cancelled every idle alarm, including all the ones that had been
    /// scheduled fine (hardening plan C5, NOT-07). One item whose alarm
    /// AlarmKit refused downgraded the rest. Now every call in the diff is
    /// tried, and the returned report names the alarms that are not as the
    /// plan wanted, so the caller can give just those items the buzzes. The
    /// wrong fix is to swallow the failures: an item whose alarm never got
    /// scheduled would then have no alert of either kind.
    ///
    /// **A call that throws is judged by what the store holds, not by the
    /// throw.** AlarmKit can throw for an alarm that is in fact there (a
    /// duplicate id from another pass, an error after the work was done), and
    /// for a cancel of an alarm that has just gone away on its own (it fired,
    /// or the student stopped it). Both are the state the reconcile wanted, so
    /// after a throw the store is read again: a scheduled alarm that is present
    /// counts as scheduled, and a cancelled one that is absent counts as
    /// cancelled. Anything else is a real failure and goes in the report. The
    /// wrong fix is to treat every throw as a failure: that sends a student
    /// whose alarms are all fine to the buzzes, and (before the error path
    /// stopped touching ringing alarms) silenced one that was ringing.
    ///
    /// **A cancel that failed is tried once more before it is reported.** The
    /// old throw path ended in `cancelIdle`, which cancelled every idle alarm
    /// again, so a cancel that failed once got a second attempt for free; the
    /// isolated version would have dropped it. That matters most for a
    /// background wake, which has no next pass: an alarm for work the student
    /// has handed in, whose first cancel failed, would ring. So every id that
    /// failed is cancelled once more at the end, after the scheduling (a moment
    /// later, and AlarmKit's own state may have settled), and only an alarm
    /// that is still there after that is reported in `uncancelled`. A stale
    /// alarm that survives both attempts changes nothing for the items that are
    /// wanted: their alarms are fine, and it is offered to the next pass's diff
    /// again. The wrong fix is `cancelIdle` for the retry: it would cancel the
    /// wanted alarms that had just been scheduled.
    @discardableResult
    static func reconcile(
        _ plan: [PlannedAlarm], in store: any BerserkAlarmStore
    ) async throws -> BerserkReconcileReport {
        let existing = try store.storedAlarms().filter { !$0.isRinging }.map(\.id)
        let diff = BerserkAlarmPlan.reconcile(desired: plan, existingIDs: existing)
        var report = BerserkReconcileReport()

        for id in diff.toCancel where !cancelled(id, in: store) {
            report.uncancelled.append(id)
        }
        for planned in diff.toSchedule {
            do {
                try await store.schedule(planned)
            } catch {
                if !isPresent(planned.id, in: store) { report.unscheduled.append(planned.id) }
            }
        }
        // The second attempt; see above. What is still there is what is reported.
        report.uncancelled = report.uncancelled.filter { !cancelled($0, in: store) }
        return report
    }

    /// One cancel, judged by what the store holds: done if it did not throw, or
    /// threw for an alarm that is in fact gone.
    private static func cancelled(_ id: UUID, in store: any BerserkAlarmStore) -> Bool {
        do {
            try store.cancel(id: id)
            return true
        } catch {
            return isAbsent(id, in: store)
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
