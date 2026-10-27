import Foundation
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
    /// (`BerserkAlarmEngine.reconcile`).
    func reconcile(_ plan: [PlannedAlarm]) async throws
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
    func removeAllPending()
    func add(_ request: UNNotificationRequest) async
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
    /// 3. Add the notifications, with the loud buzzes left out in alarm mode.
    /// 4. Reconcile the alarms against what AlarmKit already holds.
    /// 5. Settle (`BerserkAlarmPlan.settlement`): if AlarmKit threw in step 4,
    ///    the notifications are added again with the buzzes in. A student who
    ///    allowed alarms and then hit an AlarmKit error must still be warned,
    ///    not left with neither. The wrong fix is to leave the buzzes out
    ///    "because alarms are on" without checking that the alarms were really
    ///    scheduled.
    ///
    /// `removeAllPending()` is notifications-only on purpose: this runs every
    /// few minutes, and an alarm that was cancelled and re-added each time
    /// would leave a window with nothing scheduled and would cancel one that
    /// is ringing right now.
    ///
    /// `mayPrompt` is false for a background re-plan
    /// (`rescheduleWithoutPrompting`): the permission question is then never
    /// asked, and a permission that was never asked delivers the buzzes.
    func applyReminders(
        from items: [DashItem], now: Date, sink: any PendingNotificationSink, mayPrompt: Bool = true
    ) async {
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

        sink.prepare()
        let firstPassAsAlarms = decision.delivery == .alarms
        sink.removeAllPending()
        for request in plannedRequests(from: items, now: now, loudAlertsAsAlarms: firstPassAsAlarms) {
            await sink.add(request)
        }

        let settlement = await syncAlarms(plan: alarmPlan, decision: decision)
        if settlement.loudAlertsAsAlarms != firstPassAsAlarms {
            sink.removeAllPending()
            for request in plannedRequests(from: items, now: now,
                                           loudAlertsAsAlarms: settlement.loudAlertsAsAlarms) {
                await sink.add(request)
            }
        }
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
    /// reschedule finally does (`BerserkAlarmPlan.settlement`).
    ///
    /// - A delivery of `.alarms` reconciles. If AlarmKit throws, the outcome
    ///   is `.alarmKitThrew`, which takes back the alarms that are not ringing
    ///   and puts the buzzes back for this pass: a half-scheduled set of
    ///   alarms plus no buzzes would leave some work with no alert at all.
    /// - Anything else takes alarms back by the decision's scope.
    func syncAlarms(plan: [PlannedAlarm], decision: LoudDeliveryDecision) async -> BerserkAlarmPlan.Settlement {
        let backend = activeAlarmBackend()
        let outcome: BerserkAlarmPlan.Outcome
        if decision.delivery == .alarms, let backend {
            do {
                try await backend.reconcile(plan)
                outcome = .alarmsReconciled
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
        return settlement
    }

    /// Cancels every alarm, ringing or not. Called when reminders are turned
    /// off, when notifications are refused, and by `ContentView` on entering
    /// preview mode: the student's own "off". Does not need the intents
    /// registered: taking an alarm back works whether or not one could be made.
    func cancelAlarms() {
        activeAlarmBackend()?.cancelAll()
    }
}
