import Foundation
import os
import UserNotifications

/// What the scheduler needs from AlarmKit, as a protocol, so that
/// `NotificationScheduler` never names an iOS 26 type and the delivery rules
/// can be tested with a fake that touches nothing real. The one real
/// conformance is `BerserkAlarmScheduler` (iOS 26, behind
/// `#if canImport(AlarmKit)`).
@MainActor
protocol BerserkAlarmBackend: AnyObject {
    /// Whether alarms can be scheduled at all: AlarmKit is here and the App
    /// target has registered the intents the buttons run.
    var isReady: Bool { get }
    /// The current permission, read without asking.
    var authorization: BerserkAlarmAuthorization { get }
    /// Puts the one-time system question to the student.
    func requestAuthorization() async -> BerserkAlarmAuthorization
    /// Makes AlarmKit hold exactly `plan`, leaving a ringing alarm alone
    /// (`BerserkAlarmEngine.reconcile`), and reports the alarms it could not
    /// bring in line. Throws only when AlarmKit cannot be read at all.
    func reconcile(_ plan: [PlannedAlarm]) async throws -> BerserkReconcileReport
    /// Cancels every alarm that is not ringing.
    func cancelIdle()
    /// Cancels every alarm, ringing or not. Only for the student's own "off".
    func cancelAll()
    /// Stops and cancels the ringing alarms whose ids are in `finished`.
    func stopRinging(among finished: Set<UUID>)

    // The next three exist for the takeover screen (`BerserkTakeover.swift`):
    // which alarms are ringing right now, so Smooth can cover its window the
    // moment it is on screen with one going off; and the student's own stop
    // from inside the app. They have defaults below so a fake that does not
    // care about the takeover (every delivery test) keeps compiling.

    /// The ids of the alarms ringing right now. Empty where AlarmKit is
    /// absent; nil when AlarmKit could not be read, which the host treats as
    /// "judge nothing" rather than "nothing is ringing" (a ringing alarm
    /// judged silent would be dismissed and remembered as answered).
    func alertingAlarmIDs() -> [UUID]?
    /// Every change to which alarms are ringing, while the caller listens.
    /// Finishes at once where AlarmKit is absent.
    func alertingUpdates() -> AsyncStream<[UUID]>
    /// Stops one alarm (the student's own stop from inside the app). Stop,
    /// then cancel, errors ignored.
    func stopAlarm(id: UUID)
}

extension BerserkAlarmBackend {
    func alertingAlarmIDs() -> [UUID]? { [] }
    func alertingUpdates() -> AsyncStream<[UUID]> { AsyncStream { $0.finish() } }
    func stopAlarm(id: UUID) {}
}

/// Where a reschedule puts its notifications: the notification center in the
/// app, a fake in a test (the center traps in an unbundled test binary).
@MainActor
protocol PendingNotificationSink: AnyObject {
    /// Called once per pass before anything is added; the real sink makes sure
    /// the shared delegate is the center's.
    func prepare()
    /// Takes every pending request back. For "reminders off", never for a
    /// re-plan (`applyNotifications`).
    func removeAllPending()
    /// The identifier of every request pending now.
    func pendingIdentifiers() async -> [String]
    /// Takes the named pending requests back and nothing else.
    func removePending(identifiers: [String])
    /// Adds the request, replacing a pending one with the same identifier.
    /// False when the center refused it.
    func add(_ request: UNNotificationRequest) async -> Bool
}

/// What one reminder pass did, counted so a failure is a number somewhere
/// instead of a silent shortfall. Nothing here is shown to the student; the
/// scheduler keeps the latest as `lastPassReport` and logs a pass that was not
/// clean.
struct ReminderPassReport: Equatable, Sendable {
    /// Notification requests handed to the center and accepted, and those the
    /// center refused. Both are the pass's final application of the plan: a
    /// fallback re-applies the whole plan, so the first application's refusals
    /// are tried again there, not added up. A refused request is tried again
    /// by the next pass.
    var notificationsAdded = 0
    var notificationsFailed = 0
    /// Pending requests that were no longer in the plan and were taken back,
    /// over every application in the pass.
    var staleNotificationsRemoved = 0
    /// Wanted alarms AlarmKit would not hold, and unwanted ones it would not
    /// let go (`BerserkReconcileReport`).
    var alarmsUnscheduled = 0
    var alarmsUncancelled = 0

    var isClean: Bool { notificationsFailed == 0 && alarmsUnscheduled == 0 && alarmsUncancelled == 0 }

    mutating func record(_ applied: NotificationApplyResult) {
        notificationsAdded = applied.added
        notificationsFailed = applied.failed
        staleNotificationsRemoved += applied.staleRemoved
    }

    mutating func record(_ alarms: BerserkReconcileReport) {
        alarmsUnscheduled += alarms.unscheduled.count
        alarmsUncancelled += alarms.uncancelled.count
    }
}

/// The counts from one `applyNotifications`.
struct NotificationApplyResult: Equatable, Sendable {
    var added = 0
    var failed = 0
    var staleRemoved = 0
}

/// What `syncAlarms` did: the settlement the pass goes on with, and what the
/// reconcile could not do.
struct AlarmSyncResult: Sendable {
    let settlement: BerserkAlarmPlan.Settlement
    let report: BerserkReconcileReport
}

/// The outcome of `resolveLoudDelivery`.
struct LoudDeliveryDecision: Equatable {
    let delivery: LoudAlertDelivery
    /// Whether the permission prompt was shown, which can have taken the
    /// student minutes (the pass re-reads the clock when it was).
    let didPrompt: Bool
    /// When the delivery is the buzzes: which alarms to take back.
    let cancelScope: BerserkAlarmPlan.CancelScope
}

/// The alarm half of `NotificationScheduler.reschedule`. Kept out of the main
/// file because none of it needs the notification center, which is also what
/// lets a test run the whole pass against a fake backend and a fake sink.
extension NotificationScheduler {

    /// The backend to use: a test's, or on iOS 26 the real one, or none.
    func activeAlarmBackend() -> (any BerserkAlarmBackend)? {
        if let alarmBackendOverride { return alarmBackendOverride }
        #if canImport(AlarmKit) && os(iOS)
        if #available(iOS 26.0, *) { return BerserkAlarmScheduler.shared }
        #endif
        return nil
    }

    /// One reschedule pass, from "which alarms would there be" to "the
    /// notifications and the alarms agree". `reschedule` calls this once the
    /// notification permission is known to be good; it is a separate method
    /// so a test can run it against a fake sink and a fake backend.
    ///
    /// The order matters, and this is why:
    /// 1. Plan the alarms (pure) and decide the delivery first
    ///    (`resolveLoudDelivery`), because the three buzzes must be left out of
    ///    the notification plan if and only if an alarm is going to replace
    ///    them. That decision is also where the one-time alarm permission
    ///    prompt can appear, which is why it needs the plan: no prompt for a
    ///    student who has nothing to be alarmed about.
    /// 2. Stop any ringing alarm whose item is finished.
    /// 3. Bring the notifications in line (`applyNotifications`), with the loud
    ///    buzzes left out in alarm mode.
    /// 4. Reconcile the alarms against what AlarmKit already holds.
    /// 5. Settle (`BerserkAlarmPlan.settlement`): if AlarmKit threw in step 4,
    ///    or would not take the alarm of some items, the notifications are
    ///    brought in line again with the buzzes in, for every item in the first
    ///    case and for just those items in the second. A student who allowed
    ///    alarms and then hit an AlarmKit error must still be warned, not left
    ///    with neither. The wrong fix is to leave the buzzes out "because alarms
    ///    are on" without checking that the alarms were really scheduled.
    ///
    /// The pending notifications are never all removed and re-added
    /// (`applyNotifications` says why); `removeAllPending()` is for "reminders
    /// off" alone. It is notifications-only on purpose: this runs every few
    /// minutes, and an alarm that was cancelled and re-added each time would
    /// leave a window with nothing scheduled and would cancel one that is
    /// ringing right now.
    ///
    /// `mayPrompt` is false for a background re-plan
    /// (`rescheduleWithoutPrompting`): the permission question is then never
    /// asked, and a permission that was never asked delivers the buzzes.
    ///
    /// `notificationsAllowed` is false when the student has refused (or never
    /// answered) the notification permission. Then steps 1, 2 and 4 still run
    /// and the notification half (steps 3 and 5) does not: nothing can be
    /// delivered through the notification center, so nothing is added to it
    /// and what it already holds is left alone, and the alarms are planned,
    /// reconciled and taken back exactly as they would be with notifications
    /// on. AlarmKit is its own permission, and the decision's own reasons
    /// (the loud switch, preview data, a refusal from AlarmKit itself) are the
    /// only ones that take an alarm back. The one difference is the fallback
    /// the settlement describes: with no buzzes to put back, an item whose
    /// alarm AlarmKit would not take has no alert until the next pass tries
    /// it again.
    ///
    /// Returns what the pass did, counted (`ReminderPassReport`), and logs it
    /// when anything failed.
    @discardableResult
    func applyReminders(
        from items: [DashItem], now: Date, sink: any PendingNotificationSink,
        mayPrompt: Bool = true, notificationsAllowed: Bool = true
    ) async -> ReminderPassReport {
        var now = now
        var alarmPlan = plannedAlarms(from: items, now: now)
        let decision = await resolveLoudDelivery(plan: alarmPlan, mayPrompt: mayPrompt)
        if decision.didPrompt {
            // The student may have sat on the permission prompt for minutes,
            // and the buzzes' time-interval triggers are measured from the
            // moment they are added; planning from the old `now` would put
            // them that much late.
            now = Date()
            alarmPlan = plannedAlarms(from: items, now: now)
        }

        // Ticking an item off while its alarm rings is the one thing besides
        // the student's own stop that silences a ringing alarm.
        let finished = Set(Self.sweeperMinuteOptions.flatMap { minutes in
            SweeperSound.allCases.flatMap { sound in
                BerserkAlarmPlan.finishedAlarmIDs(from: items, lead: TimeInterval(minutes * 60), sound: sound)
            }
        })
        activeAlarmBackend()?.stopRinging(among: finished)

        var report = ReminderPassReport()

        guard notificationsAllowed else {
            report.record(await syncAlarms(plan: alarmPlan, decision: decision).report)
            return logged(report)
        }

        sink.prepare()
        let firstPassAsAlarms = decision.delivery == .alarms
        report.record(await applyNotifications(
            plannedRequests(from: items, now: now, loudAlertsAsAlarms: firstPassAsAlarms), to: sink))

        let synced = await syncAlarms(plan: alarmPlan, decision: decision)
        report.record(synced.report)
        let settlement = synced.settlement
        if settlement.loudAlertsAsAlarms != firstPassAsAlarms || !settlement.buzzFallbackAssignmentIDs.isEmpty {
            report.record(await applyNotifications(
                plannedRequests(from: items, now: now, loudAlertsAsAlarms: settlement.loudAlertsAsAlarms,
                                buzzFallbackAssignmentIDs: settlement.buzzFallbackAssignmentIDs),
                to: sink))
        }
        return logged(report)
    }

    /// Brings the pending notifications in line with `planned`: takes back the
    /// ones the plan no longer holds, then adds every planned request, and
    /// counts the adds the center refused.
    ///
    /// **Why not remove everything and add everything.** That is what a
    /// re-plan used to be, and it is not atomic (hardening plan C5, UCR-4,
    /// NOT-10): for the length of up to sixty awaited `add` calls the queue
    /// held only what had been re-added so far, and a pass that was cut short
    /// (the process killed, a wake out of budget) left the student with
    /// whatever fraction of their reminders it had reached. It also threw the
    /// result of every `add` away, so a refusal was a reminder that quietly
    /// never existed.
    ///
    /// **Why the stale ones go first and the adds second.** A wanted request
    /// is never removed, so there is no moment at which a reminder the student
    /// should have is missing: `add` replaces a pending request of the same
    /// identifier in one step. The stale ones go first, not last, because of
    /// the cap: iOS keeps only about sixty-four pending requests and drops the
    /// rest, so adding a whole new plan beside the old one and removing the old
    /// afterwards could hold more than the cap for a moment and lose some of
    /// the new. Removing first keeps the queue at most the size of the plan at
    /// every step. The wrong fix is "add everything, then remove everything
    /// that was there before", which fails twice: it can pass the cap, and it
    /// removes the requests it has just replaced.
    ///
    /// A refused add is counted, not retried here: the next pass re-adds the
    /// whole plan, and a retry loop in a pass that runs every few minutes would
    /// only delay the ones that work.
    func applyNotifications(
        _ planned: [UNNotificationRequest], to sink: any PendingNotificationSink
    ) async -> NotificationApplyResult {
        var result = NotificationApplyResult()
        let plannedIDs = Set(planned.map(\.identifier))
        let stale = await sink.pendingIdentifiers().filter { !plannedIDs.contains($0) }
        if !stale.isEmpty {
            sink.removePending(identifiers: stale)
            result.staleRemoved = stale.count
        }
        for request in planned {
            if await sink.add(request) { result.added += 1 } else { result.failed += 1 }
        }
        return result
    }

    /// Keeps the pass's report as `lastPassReport` and says so in the log when
    /// something failed. Counts only; nothing about the student's work.
    private func logged(_ report: ReminderPassReport) -> ReminderPassReport {
        lastPassReport = report
        if !report.isClean {
            Logger(subsystem: "com.lhf.lowhangingfruit", category: "reminders").error(
                "reminder pass incomplete: \(report.notificationsFailed) notifications refused, \(report.alarmsUnscheduled) alarms not scheduled, \(report.alarmsUncancelled) alarms not cancelled")
        }
        return report
    }

    /// Decides how this reschedule delivers the loud alert, asking for alarm
    /// permission if it has never been asked.
    ///
    /// Buzzes, without touching AlarmKit at all, when the loud-alert switch is
    /// off, when this is preview or demo data (`BerserkAlarmPlan.alarmsAllowed`),
    /// or when there is no usable backend (below iOS 26, on a Mac, or the App
    /// target has not registered its intents). The first two and a refused
    /// permission are the student's own "off", so they take every alarm back,
    /// ringing or not; the rest only take back the ones not yet ringing
    /// (`BerserkAlarmPlan.CancelScope`).
    ///
    /// **The question is asked only when `plan` has something to ring.** A
    /// student with no unsubmitted work due soon has nothing to be alarmed
    /// about, and a system prompt out of nowhere would be the first thing the
    /// feature said to them. It is asked from here, which runs while the app
    /// is open (the dashboard's refresh, a preference change), because AlarmKit
    /// cannot show its prompt from the background. If the request throws, or
    /// the answer is no, the delivery is buzzes, and the question is not asked
    /// again: `.denied` is final until the student changes it in Settings.
    ///
    /// **`mayPrompt: false` is the background's version of "from here".** A
    /// re-plan with nobody at the phone (`LHFBackgroundRefresh`) must not put
    /// the question, so a permission that was never asked is treated like one
    /// that could not be: the buzzes, taking back only idle alarms (there can
    /// be none to take, but a ringing one is never ours to stop).
    func resolveLoudDelivery(plan: [PlannedAlarm], mayPrompt: Bool = true) async -> LoudDeliveryDecision {
        func buzzes(_ scope: BerserkAlarmPlan.CancelScope, prompted: Bool = false) -> LoudDeliveryDecision {
            LoudDeliveryDecision(delivery: .buzzes, didPrompt: prompted, cancelScope: scope)
        }
        guard loudAlertEnabled else { return buzzes(.everything) }
        guard BerserkAlarmPlan.alarmsAllowed(isUsingFixtureData: fixtureDataProbe?() ?? false)
        else { return buzzes(.everything) }
        guard let backend = activeAlarmBackend(), backend.isReady else { return buzzes(.idleOnly) }

        var state = backend.authorization
        var prompted = false
        if state == .notDetermined, !plan.isEmpty, mayPrompt {
            state = await backend.requestAuthorization()
            prompted = true
        }
        switch BerserkAlarmPlan.delivery(alarmKitAvailable: true, authorization: state) {
        case .alarms:
            return LoudDeliveryDecision(delivery: .alarms, didPrompt: prompted, cancelScope: .idleOnly)
        case .buzzes:
            return buzzes(state == .denied ? .everything : .idleOnly, prompted: prompted)
        }
    }

    /// Brings AlarmKit in line with the decision and returns what the
    /// reschedule finally does (`BerserkAlarmPlan.settlement`), with what the
    /// reconcile could not do.
    ///
    /// - A delivery of `.alarms` reconciles. If AlarmKit would not take the
    ///   alarm of some items, those items alone get the buzzes
    ///   (`.alarmsPartlyReconciled`) and the rest keep their alarms. If AlarmKit
    ///   cannot be used at all the outcome is `.alarmKitThrew`, which takes
    ///   back the alarms that are not ringing and puts the buzzes back for
    ///   every item: with nothing known about the alarms, a half-scheduled set
    ///   plus no buzzes would leave some work with no alert at all.
    /// - Anything else takes alarms back by the decision's scope.
    func syncAlarms(plan: [PlannedAlarm], decision: LoudDeliveryDecision) async -> AlarmSyncResult {
        let backend = activeAlarmBackend()
        let outcome: BerserkAlarmPlan.Outcome
        var report = BerserkReconcileReport()
        if decision.delivery == .alarms, let backend {
            do {
                report = try await backend.reconcile(plan)
                let unscheduled = Set(report.unscheduled)
                let buzzFor = Set(plan.filter { unscheduled.contains($0.id) }.map(\.assignmentID))
                outcome = buzzFor.isEmpty ? .alarmsReconciled : .alarmsPartlyReconciled(buzzFor: buzzFor)
            } catch {
                outcome = .alarmKitThrew
            }
        } else {
            outcome = .buzzes(decision.cancelScope)
        }

        let settlement = BerserkAlarmPlan.settlement(for: outcome)
        switch settlement.alarmAction {
        case .keep: break
        case .cancelIdle: backend?.cancelIdle()
        case .cancelAll: backend?.cancelAll()
        }
        return AlarmSyncResult(settlement: settlement, report: report)
    }

    /// Cancels every alarm, ringing or not. Called when reminders are turned
    /// off and by `ContentView` on entering preview mode: the student's own
    /// "off". Refusing notifications is not one (AlarmKit is its own
    /// permission). Does not need the intents registered: taking an alarm back
    /// works whether or not one could be made.
    func cancelAlarms() {
        activeAlarmBackend()?.cancelAll()
    }
}
