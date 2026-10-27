import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// MARK: - Fakes

private enum FakeAlarmError: Error { case boom, duplicate, notFound }

/// An in-memory `AlarmManager`: the alarms it holds, every call made on it, and
/// switches for the failures AlarmKit can produce.
@MainActor
final class FakeAlarmStore: BerserkAlarmStore {
    /// id -> is ringing.
    private(set) var alarms: [UUID: Bool] = [:]
    private(set) var scheduleAttempts: [UUID] = []
    private(set) var cancelAttempts: [UUID] = []
    private(set) var stopCalls: [UUID] = []

    /// `schedule` throws and stores nothing.
    var failingScheduleIDs: Set<UUID> = []
    /// `schedule` stores the alarm and then throws (it did the work).
    var throwsButStoresIDs: Set<UUID> = []
    /// `cancel` removes the alarm and throws (it had just gone away).
    var vanishingCancelIDs: Set<UUID> = []
    /// `cancel` throws and leaves the alarm.
    var failingCancelIDs: Set<UUID> = []
    /// The first `cancel` of each of these throws and leaves the alarm; a later
    /// one works (a transient failure).
    var failingFirstCancelIDs: Set<UUID> = []
    /// `alarms` throws.
    var readFailure: Error?

    var scheduledIDs: Set<UUID> { Set(alarms.keys) }
    var ringingIDs: Set<UUID> { Set(alarms.filter(\.value).keys) }

    func seed(_ id: UUID, ringing: Bool = false) { alarms[id] = ringing }

    func storedAlarms() throws -> [StoredAlarm] {
        if let readFailure { throw readFailure }
        return alarms.map { StoredAlarm(id: $0.key, isRinging: $0.value) }
    }

    func cancel(id: UUID) throws {
        cancelAttempts.append(id)
        if failingCancelIDs.contains(id) { throw FakeAlarmError.boom }
        if failingFirstCancelIDs.contains(id), cancelAttempts.filter({ $0 == id }).count == 1 {
            throw FakeAlarmError.boom
        }
        let existed = alarms.removeValue(forKey: id) != nil
        if vanishingCancelIDs.contains(id) || !existed { throw FakeAlarmError.notFound }
    }

    func stop(id: UUID) throws {
        stopCalls.append(id)
        guard alarms.removeValue(forKey: id) != nil else { throw FakeAlarmError.notFound }
    }

    func schedule(_ planned: PlannedAlarm) async throws {
        scheduleAttempts.append(planned.id)
        if alarms[planned.id] != nil { throw FakeAlarmError.duplicate }
        if failingScheduleIDs.contains(planned.id) { throw FakeAlarmError.boom }
        alarms[planned.id] = false
        if throwsButStoresIDs.contains(planned.id) { throw FakeAlarmError.boom }
    }
}

/// The scheduler's view of AlarmKit, with the real engine over a fake store so
/// that what the engine does to the alarms is what a test observes.
@MainActor
final class FakeAlarmBackend: BerserkAlarmBackend {
    let store = FakeAlarmStore()
    var isReady = true
    var authorization: BerserkAlarmAuthorization
    /// What a permission request answers; applied to `authorization` when it
    /// is a yes or a no.
    var answer: BerserkAlarmAuthorization
    /// Runs inside the permission request, to hold it open.
    var duringRequest: (() async -> Void)?

    private(set) var authorizationRequests = 0
    private(set) var cancelIdleCalls = 0
    private(set) var cancelAllCalls = 0

    init(authorization: BerserkAlarmAuthorization, answer: BerserkAlarmAuthorization = .authorized) {
        self.authorization = authorization
        self.answer = answer
    }

    func requestAuthorization() async -> BerserkAlarmAuthorization {
        authorizationRequests += 1
        await duringRequest?()
        if answer == .authorized || answer == .denied { authorization = answer }
        return answer
    }

    func reconcile(_ plan: [PlannedAlarm]) async throws -> BerserkReconcileReport {
        try await BerserkAlarmEngine.reconcile(plan, in: store)
    }

    func cancelIdle() {
        cancelIdleCalls += 1
        BerserkAlarmEngine.cancelIdle(in: store)
    }

    func cancelAll() {
        cancelAllCalls += 1
        BerserkAlarmEngine.cancelAll(in: store)
    }

    func stopRinging(among finished: Set<UUID>) {
        BerserkAlarmEngine.stopRinging(among: finished, in: store)
    }
}

/// The notification center, as a list. Like the real one, adding a request
/// whose identifier is pending replaces it in place.
@MainActor
final class FakeSink: PendingNotificationSink {
    private(set) var requests: [UNNotificationRequest] = []
    /// How many times `removeAllPending` was called.
    private(set) var removals = 0
    /// Every identifier `removePending` was asked for, in order.
    private(set) var removedIdentifiers: [String] = []
    /// Every `add`, in order, accepted or not.
    private(set) var addAttempts: [String] = []
    /// Every operation in the order it happened ("remove:<id>", "add:<id>"),
    /// and the most that was ever pending at once.
    private(set) var log: [String] = []
    private(set) var mostPending = 0
    /// `add` of these identifiers is refused, as the center does when it
    /// rejects a request.
    var refusedIdentifiers: Set<String> = []

    func prepare() {}

    /// Puts a request in the queue as an earlier pass would have left it.
    func seed(_ request: UNNotificationRequest) {
        requests.removeAll { $0.identifier == request.identifier }
        requests.append(request)
    }

    func removeAllPending() {
        requests = []
        removals += 1
    }

    func pendingIdentifiers() async -> [String] {
        requests.map(\.identifier)
    }

    func removePending(identifiers: [String]) {
        for id in identifiers {
            removedIdentifiers.append(id)
            log.append("remove:\(id)")
        }
        requests.removeAll { identifiers.contains($0.identifier) }
    }

    func add(_ request: UNNotificationRequest) async -> Bool {
        addAttempts.append(request.identifier)
        log.append("add:\(request.identifier)")
        if refusedIdentifiers.contains(request.identifier) { return false }
        if let index = requests.firstIndex(where: { $0.identifier == request.identifier }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
        mostPending = max(mostPending, requests.count)
        return true
    }

    func buzzCount(for assignmentID: String) -> Int {
        requests.filter { $0.identifier.hasPrefix("loud:\(assignmentID):") }.count
    }
}

/// Holds one caller until the test lets it go. A second waiter does not wait:
/// if the code under test were to run two passes at once, the test should see
/// two requests and fail, not hang.
@MainActor
final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    private var isOpen = false

    func wait() async {
        if isOpen || isWaiting { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// What ran, and how many at once.
@MainActor
final class PassLog {
    private(set) var ran: [Int] = []
    private(set) var mostAtOnce = 0
    private var running = 0

    func begin(_ n: Int) {
        ran.append(n)
        running += 1
        mostAtOnce = max(mostAtOnce, running)
    }

    func end() { running -= 1 }
}

/// One row of the "exactly one of alarm or buzzes" table.
private struct Scenario: Sendable, CustomTestStringConvertible {
    /// `alarmsExceptSecond`: the second of the three items has the buzzes, the
    /// other two have their alarms.
    enum Expectation: Sendable { case alarms, buzzes, neither, alarmsExceptSecond }
    enum Fault: Sendable { case none, secondScheduleFails, firstScheduleThrowsButStores, storeUnreadable }

    let name: String
    var hasBackend = true
    var isReady = true
    var authorization: BerserkAlarmAuthorization = .authorized
    var promptAnswer: BerserkAlarmAuthorization = .authorized
    var fault: Fault = .none
    var loudSwitchOn = true
    var fixtureData = false
    let expectation: Expectation

    var testDescription: String { name }
}

private let scenarios: [Scenario] = [
    Scenario(name: "authorized, AlarmKit takes the plan", expectation: .alarms),
    Scenario(name: "authorized, AlarmKit refuses one item's alarm: that item has the buzzes, the others keep theirs",
             fault: .secondScheduleFails, expectation: .alarmsExceptSecond),
    Scenario(name: "authorized, AlarmKit cannot be read at all: every item has the buzzes",
             fault: .storeUnreadable, expectation: .buzzes),
    Scenario(name: "authorized, schedule throws but the alarm is there",
             fault: .firstScheduleThrowsButStores, expectation: .alarms),
    Scenario(name: "denied", authorization: .denied, expectation: .buzzes),
    Scenario(name: "not asked yet, student says yes", authorization: .notDetermined,
             promptAnswer: .authorized, expectation: .alarms),
    Scenario(name: "not asked yet, student says no", authorization: .notDetermined,
             promptAnswer: .denied, expectation: .buzzes),
    Scenario(name: "not asked yet, the request fails", authorization: .notDetermined,
             promptAnswer: .failed, expectation: .buzzes),
    Scenario(name: "the App target's intent factory is nil", isReady: false, expectation: .buzzes),
    Scenario(name: "no AlarmKit at all (below iOS 26, or a Mac)", hasBackend: false, expectation: .buzzes),
    Scenario(name: "the loud alert is switched off: neither, by the student's choice",
             loudSwitchOn: false, expectation: .neither),
    Scenario(name: "preview or demo data: the buzzes as before, never an alarm",
             fixtureData: true, expectation: .buzzes),
]

/// Berserk mode, the behaviour: a reschedule run against a fake AlarmKit and a
/// fake notification center, through the same code the app runs. These are the
/// tests for what the student ends up with, which no source scan can show.
@MainActor
@Suite("Berserk alarm delivery")
struct BerserkAlarmDeliveryTests {

    // MARK: Exactly one alert per item

    /// **The invariant.** Every item the loud alert covers ends up with exactly
    /// one of an alarm or its three buzzes, whatever AlarmKit does, and never
    /// both. The one exception is the student's own switch, which leaves
    /// neither. The first version of this feature could end a pass with both
    /// (a second pass colliding with the first) or with neither (an error after
    /// the buzzes were already left out).
    @Test("Every loud-eligible item ends with exactly one of an alarm or the buzzes", arguments: scenarios)
    fileprivate func exactlyOneAlertPerItem(_ scenario: Scenario) async {
        await withScheduler { scheduler, now in
            let items = eligible(now)
            let (backend, sink) = arrange(scenario, scheduler)
            if scenario.fault == .secondScheduleFails {
                backend.store.failingScheduleIDs = [alarmID(of: items[1])]
            }
            if scenario.fault == .firstScheduleThrowsButStores {
                backend.store.throwsButStoresIDs = [alarmID(of: items[0])]
            }
            if scenario.fault == .storeUnreadable {
                backend.store.readFailure = FakeAlarmError.boom
            }

            await scheduler.applyReminders(from: items + noise(now), now: now, sink: sink)

            for (index, item) in items.enumerated() {
                let hasAlarm = backend.store.scheduledIDs.contains(alarmID(of: item))
                let buzzes = sink.buzzCount(for: item.assignment.id)
                #expect(!(hasAlarm && buzzes > 0), "\(item.assignment.id): both an alarm and buzzes")
                switch scenario.expectation {
                case .alarms: #expect(hasAlarm && buzzes == 0, "\(item.assignment.id)")
                case .buzzes: #expect(!hasAlarm && buzzes == NotificationScheduler.loudAlertCount,
                                      "\(item.assignment.id)")
                case .neither: #expect(!hasAlarm && buzzes == 0, "\(item.assignment.id)")
                case .alarmsExceptSecond:
                    if index == 1 {
                        #expect(!hasAlarm && buzzes == NotificationScheduler.loudAlertCount,
                                "\(item.assignment.id): the item AlarmKit refused is warned by the buzzes")
                    } else {
                        #expect(hasAlarm && buzzes == 0, "\(item.assignment.id): keeps its alarm")
                    }
                }
            }
            let expectedAlarms = [Scenario.Expectation.alarms: items.count,
                                  .alarmsExceptSecond: items.count - 1][scenario.expectation] ?? 0
            #expect(backend.store.scheduledIDs.count == expectedAlarms, "no stray alarms")
            // Nothing else about the notifications moved: the work the alert does
            // not cover keeps its own reminders in every scenario.
            #expect(sink.requests.contains { $0.identifier.hasPrefix("due:canvas:reading:") })
        }
    }

    /// The same reschedule twice changes nothing: ids are derived, the diff
    /// leaves what is there, and no alarm is scheduled again.
    @Test("A second pass over the same items schedules nothing new")
    func secondPassIsIdempotent() async {
        await withScheduler { scheduler, now in
            let (backend, sink) = arrange(Scenario(name: "", expectation: .alarms), scheduler)
            let items = eligible(now)
            await scheduler.applyReminders(from: items, now: now, sink: sink)
            let first = backend.store.scheduleAttempts
            await scheduler.applyReminders(from: items, now: now, sink: sink)
            #expect(first.count == items.count)
            #expect(backend.store.scheduleAttempts == first, "no alarm was scheduled a second time")
            #expect(backend.store.scheduledIDs == Set(items.map(alarmID(of:))))
        }
    }

    @Test("A finished or moved item loses its alarm on the next pass")
    func staleAlarmsAreCancelled() async {
        await withScheduler { scheduler, now in
            let (backend, sink) = arrange(Scenario(name: "", expectation: .alarms), scheduler)
            var items = eligible(now)
            await scheduler.applyReminders(from: items, now: now, sink: sink)
            let before = items.map(alarmID(of:))

            items[0].isCompleted = true                                  // ticked off
            items[1] = item("CIS 1200", "b", due: now + 9 * 3600)        // due date moved
            await scheduler.applyReminders(from: items, now: now, sink: sink)

            #expect(!backend.store.scheduledIDs.contains(before[0]))
            #expect(!backend.store.scheduledIDs.contains(before[1]))
            #expect(backend.store.scheduledIDs.contains(before[2]))
            #expect(backend.store.scheduledIDs.contains(alarmID(of: items[1])))
            #expect(backend.store.scheduledIDs.count == 2)
        }
    }

    // MARK: A ringing alarm is the student's

    private func ringingRig(
        _ scheduler: NotificationScheduler, scenario: Scenario
    ) -> (FakeAlarmBackend, FakeSink, ringing: UUID, idle: UUID) {
        let (backend, sink) = arrange(scenario, scheduler)
        let ringing = UUID(), idle = UUID()
        backend.store.seed(ringing, ringing: true)
        backend.store.seed(idle)
        return (backend, sink, ringing, idle)
    }

    @Test("An AlarmKit error never silences a ringing alarm, and one alarm's failure does not take back the others")
    func errorNeverSilencesARingingAlarm() async {
        await withScheduler { scheduler, now in
            let items = eligible(now)
            let (backend, sink, ringing, idle) = ringingRig(
                scheduler, scenario: Scenario(name: "", fault: .secondScheduleFails, expectation: .alarmsExceptSecond))
            backend.store.failingScheduleIDs = [alarmID(of: items[1])]

            await scheduler.applyReminders(from: items, now: now, sink: sink)

            #expect(backend.store.scheduledIDs == [ringing, alarmID(of: items[0]), alarmID(of: items[2])],
                    "the ringing alarm rings on, the stale one is gone, the two that worked stay")
            #expect(!backend.store.scheduledIDs.contains(idle))
            #expect(!backend.store.stopCalls.contains(ringing))
            #expect(backend.cancelIdleCalls == 0 && backend.cancelAllCalls == 0, "nothing was taken back wholesale")
            #expect(sink.buzzCount(for: items[1].assignment.id) == 3, "and the refused item has the buzzes")
        }
    }

    @Test("When AlarmKit cannot be read at all, every item falls back to the buzzes and a ringing alarm is left alone")
    func unreadableAlarmKitNeverSilencesARingingAlarm() async {
        await withScheduler { scheduler, now in
            let items = eligible(now)
            let (backend, sink, ringing, _) = ringingRig(
                scheduler, scenario: Scenario(name: "", fault: .storeUnreadable, expectation: .buzzes))
            backend.store.readFailure = FakeAlarmError.boom

            await scheduler.applyReminders(from: items, now: now, sink: sink)

            #expect(backend.store.scheduledIDs.contains(ringing))
            #expect(!backend.store.stopCalls.contains(ringing))
            #expect(items.allSatisfy { sink.buzzCount(for: $0.assignment.id) == 3 }, "the buzzes are back for all")
        }
    }

    @Test("A cancel that throws for an alarm already gone is not an error, so nothing falls back")
    func vanishedAlarmIsNotAFailure() async {
        await withScheduler { scheduler, now in
            let items = eligible(now)
            let (backend, sink, ringing, idle) = ringingRig(scheduler, scenario: Scenario(name: "", expectation: .alarms))
            backend.store.vanishingCancelIDs = [idle]

            await scheduler.applyReminders(from: items, now: now, sink: sink)

            #expect(backend.store.scheduledIDs == Set(items.map(alarmID(of:))).union([ringing]))
            #expect(items.allSatisfy { sink.buzzCount(for: $0.assignment.id) == 0 })
            #expect(backend.cancelIdleCalls == 0 && backend.cancelAllCalls == 0)
        }
    }

    @Test("Moving to the buzzes because alarms are unusable spares a ringing alarm")
    func unusableAlarmsSpareARingingAlarm() async {
        for scenario in [
            Scenario(name: "factory nil", isReady: false, expectation: .buzzes),
            Scenario(name: "not asked, and no answer", authorization: .notDetermined,
                     promptAnswer: .failed, expectation: .buzzes),
        ] {
            await withScheduler { scheduler, now in
                let (backend, sink, ringing, idle) = ringingRig(scheduler, scenario: scenario)
                await scheduler.applyReminders(from: eligible(now), now: now, sink: sink)
                #expect(backend.store.scheduledIDs == [ringing], "\(scenario.name)")
                #expect(!backend.store.scheduledIDs.contains(idle), "\(scenario.name)")
            }
        }
    }

    @Test("The student's own off, a refusal or preview takes back every alarm, ringing or not")
    func explicitOffTakesEverything() async {
        for scenario in [
            Scenario(name: "loud switch off", loudSwitchOn: false, expectation: .neither),
            Scenario(name: "permission revoked", authorization: .denied, expectation: .buzzes),
            Scenario(name: "preview entered", fixtureData: true, expectation: .buzzes),
        ] {
            await withScheduler { scheduler, now in
                let (backend, sink, _, _) = ringingRig(scheduler, scenario: scenario)
                await scheduler.applyReminders(from: eligible(now), now: now, sink: sink)
                #expect(backend.store.scheduledIDs.isEmpty, "\(scenario.name)")
            }
        }
    }

    @Test("Reminders off take back every alarm, ringing or not")
    func remindersOffTakesEverything() async {
        await withScheduler(remindersOn: false) { scheduler, now in
            let backend = FakeAlarmBackend(authorization: .authorized)
            backend.store.seed(UUID(), ringing: true)
            backend.store.seed(UUID())
            scheduler.alarmBackendOverride = backend
            scheduler.notificationSinkOverride = FakeSink()
            scheduler.authStatusOverride = .authorized

            await scheduler.reschedule(from: eligible(now), now: now)

            #expect(backend.store.scheduledIDs.isEmpty)
        }
    }

    // MARK: Refusing notifications is not refusing alarms

    /// The notification permission and the AlarmKit permission are two
    /// questions, and declining notifications is the commonest onboarding
    /// answer. A pass used to take every alarm back and return as soon as it
    /// saw the notification refusal (hardening plan C2, NOT-02).
    private func declinedRig(
        _ scheduler: NotificationScheduler, status: UNAuthorizationStatus,
        alarms: BerserkAlarmAuthorization, answer: BerserkAlarmAuthorization = .authorized
    ) -> (FakeAlarmBackend, FakeSink) {
        let backend = FakeAlarmBackend(authorization: alarms, answer: answer)
        let sink = FakeSink()
        scheduler.alarmBackendOverride = backend
        scheduler.notificationSinkOverride = sink
        scheduler.authStatusOverride = status
        return (backend, sink)
    }

    @Test("With notifications refused or unanswered, the alarms are still planned and reconciled", arguments: [
        UNAuthorizationStatus.denied, .notDetermined,
    ])
    func declinedNotificationsStillPlanAlarms(status: UNAuthorizationStatus) async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let (backend, sink) = declinedRig(scheduler, status: status, alarms: .authorized)
            let items = eligible(now)
            let stale = UUID(), ringing = UUID()
            backend.store.seed(stale)
            backend.store.seed(ringing, ringing: true)

            await scheduler.reschedule(from: items + noise(now), now: now)

            #expect(backend.store.scheduledIDs == Set(items.map(alarmID(of:))).union([ringing]),
                    "every eligible item has its alarm, the stale one is gone, the ringing one rings on")
            #expect(backend.cancelAllCalls == 0, "nothing here is the student's own off")
            #expect(sink.requests.isEmpty && sink.removals == 0,
                    "nothing can be delivered, so the notification center is not touched")
        }
    }

    @Test("With notifications refused, AlarmKit's own refusal, the loud switch and preview still take every alarm back")
    func declinedNotificationsKeepTheAlarmOffSwitches() async {
        let rows: [(name: String, alarms: BerserkAlarmAuthorization, loudOn: Bool, fixture: Bool)] = [
            ("AlarmKit refused", .denied, true, false),
            ("loud switch off", .authorized, false, false),
            ("preview or demo data", .authorized, true, true),
        ]
        for row in rows {
            await withScheduler(remindersOn: true) { scheduler, now in
                let (backend, sink) = declinedRig(scheduler, status: .denied, alarms: row.alarms)
                scheduler.setLoudAlertEnabled(row.loudOn)
                scheduler.fixtureDataProbe = { row.fixture }
                backend.store.seed(UUID(), ringing: true)
                backend.store.seed(UUID())

                await scheduler.reschedule(from: eligible(now), now: now)

                #expect(backend.store.scheduledIDs.isEmpty, "\(row.name)")
                #expect(sink.requests.isEmpty, "\(row.name)")
            }
        }
    }

    @Test("With notifications refused, AlarmKit's own question is still asked once, and a yes means alarms")
    func declinedNotificationsStillAskAlarmKit() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let (backend, _) = declinedRig(scheduler, status: .denied, alarms: .notDetermined, answer: .authorized)
            let items = eligible(now)

            await scheduler.reschedule(from: items, now: now)
            await scheduler.reschedule(from: items, now: now)

            #expect(backend.authorizationRequests == 1)
            #expect(backend.store.scheduledIDs == Set(items.map(alarmID(of:))))
        }
    }

    @Test("With notifications refused, a finished item's ringing alarm is still stopped")
    func declinedNotificationsStillStopFinishedAlarms() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let (backend, _) = declinedRig(scheduler, status: .denied, alarms: .authorized)
            let done = item("CIS 1200", "done", due: now + 300, completed: true)
            backend.store.seed(alarmID(of: done), ringing: true)

            await scheduler.reschedule(from: [done], now: now)

            #expect(backend.store.stopCalls == [alarmID(of: done)])
            #expect(backend.store.scheduledIDs.isEmpty)
        }
    }

    // MARK: Ticking an item off stops its ringing alarm

    @Test("Only the ringing alarm of a finished item is stopped, then cancelled")
    func finishedItemStopsItsRingingAlarm() async {
        await withScheduler { scheduler, now in
            // Both fired five minutes ago, so both are legitimately ringing and
            // neither is in the plan.
            let done = item("CIS 1200", "done", due: now + 300, completed: true)
            let live = item("CIS 1200", "live", due: now + 300)
            let stranger = UUID()
            let (backend, sink) = arrange(Scenario(name: "", expectation: .alarms), scheduler)
            backend.store.seed(alarmID(of: done), ringing: true)
            backend.store.seed(alarmID(of: live), ringing: true)
            backend.store.seed(stranger, ringing: true)

            await scheduler.applyReminders(from: [done, live], now: now, sink: sink)

            #expect(backend.store.stopCalls == [alarmID(of: done)])
            #expect(backend.store.scheduledIDs == [alarmID(of: live), stranger], "everything else rings on")
        }
    }

    @Test("The finished item's id is derived from its effective due date, not the feed's")
    func finishedItemUsesTheOverride() async {
        await withScheduler { scheduler, now in
            let moved = item("CIS 1200", "moved", due: now - 86_400, completed: true, override: now + 300)
            let fromTheFeedDate = BerserkAlarmPlan.alarmID(
                assignmentID: moved.assignment.id,
                fireDate: (moved.assignment.dueAt ?? now).addingTimeInterval(-NotificationScheduler.loudAlertLead))
            let (backend, sink) = arrange(Scenario(name: "", expectation: .alarms), scheduler)
            backend.store.seed(alarmID(of: moved), ringing: true)
            backend.store.seed(fromTheFeedDate, ringing: true)

            await scheduler.applyReminders(from: [moved], now: now, sink: sink)

            #expect(backend.store.stopCalls == [alarmID(of: moved)])
            #expect(backend.store.scheduledIDs == [fromTheFeedDate])
        }
    }

    @Test("Which ringing alarms to stop: those of finished items, and no others")
    func ringingStopRule() {
        let now = Date()
        let done = item("CIS 1200", "done", due: now + 300, completed: true)
        let open = item("CIS 1200", "open", due: now + 300)
        let undated = item("CIS 1200", "undated", due: nil, completed: true)
        let finished = BerserkAlarmPlan.finishedAlarmIDs(from: [done, open, undated])
        #expect(finished == [alarmID(of: done)], "completed and dated only")

        let other = UUID()
        #expect(BerserkAlarmPlan.alertingIDsToStop(alerting: [other, alarmID(of: done), alarmID(of: open)],
                                                   finished: finished) == [alarmID(of: done)])
        #expect(BerserkAlarmPlan.alertingIDsToStop(alerting: [other], finished: finished).isEmpty)
        #expect(BerserkAlarmPlan.alertingIDsToStop(alerting: [alarmID(of: done), alarmID(of: done)],
                                                   finished: finished).count == 1)
        #expect(BerserkAlarmPlan.alertingIDsToStop(alerting: [alarmID(of: done)], finished: []).isEmpty)
    }

    // MARK: The engine, against the fake store

    @Test("Reconcile leaves a ringing alarm alone even though the plan does not want it")
    func reconcileSkipsRinging() async throws {
        let store = FakeAlarmStore()
        let ringing = UUID(), idle = UUID()
        store.seed(ringing, ringing: true)
        store.seed(idle)
        try await BerserkAlarmEngine.reconcile([], in: store)
        #expect(store.scheduledIDs == [ringing])
    }

    @Test("cancelIdle spares a ringing alarm; cancelAll does not")
    func cancelScopes() {
        let store = FakeAlarmStore()
        let ringing = UUID(), idle = UUID()
        store.seed(ringing, ringing: true)
        store.seed(idle)
        BerserkAlarmEngine.cancelIdle(in: store)
        #expect(store.scheduledIDs == [ringing])
        BerserkAlarmEngine.cancelAll(in: store)
        #expect(store.scheduledIDs.isEmpty)
    }

    @Test("A schedule that throws is a failure only if the alarm is not there afterwards")
    func scheduleThrowIsJudgedByTheStore() async throws {
        let planned = planAlarm("a")
        let stored = FakeAlarmStore()
        stored.throwsButStoresIDs = [planned.id]
        let kept = try await BerserkAlarmEngine.reconcile([planned], in: stored)
        #expect(stored.scheduledIDs == [planned.id])
        #expect(kept.isClean)

        let failed = FakeAlarmStore()
        failed.failingScheduleIDs = [planned.id]
        let report = try await BerserkAlarmEngine.reconcile([planned], in: failed)
        #expect(report.unscheduled == [planned.id])
        #expect(report.uncancelled.isEmpty)
    }

    @Test("A cancel that throws is a failure only if the alarm is still there afterwards")
    func cancelThrowIsJudgedByTheStore() async throws {
        let gone = UUID(), stuck = UUID()
        let vanishing = FakeAlarmStore()
        vanishing.seed(gone)
        vanishing.vanishingCancelIDs = [gone]
        let vanished = try await BerserkAlarmEngine.reconcile([], in: vanishing)
        #expect(vanished.isClean)

        let failing = FakeAlarmStore()
        failing.seed(stuck)
        failing.failingCancelIDs = [stuck]
        let report = try await BerserkAlarmEngine.reconcile([], in: failing)
        #expect(report.uncancelled == [stuck])
        #expect(report.unscheduled.isEmpty)
        #expect(failing.cancelAttempts.filter { $0 == stuck }.count == 2, "tried, then tried once more")
    }

    /// The old throw path ended in `cancelIdle`, which cancelled every idle alarm
    /// a second time, so a cancel that failed once got a retry. A background wake
    /// has no next pass, so without the retry an alarm for work already handed
    /// in could ring.
    @Test("A cancel that fails once is retried, and the alarm is gone and not reported")
    func failedCancelIsRetriedOnce() async throws {
        let stale = UUID()
        let store = FakeAlarmStore()
        store.seed(stale)
        store.failingFirstCancelIDs = [stale]

        let report = try await BerserkAlarmEngine.reconcile([], in: store)

        #expect(store.scheduledIDs.isEmpty, "the stale alarm is gone")
        #expect(report.isClean && report.uncancelled.isEmpty)
        #expect(store.cancelAttempts.filter { $0 == stale }.count == 2)
    }

    @Test("The retry cancels only what failed: the alarms just scheduled are left alone")
    func retryOnlyTouchesTheFailedCancels() async throws {
        let wanted = planAlarm("wanted")
        let stale = UUID(), fine = UUID()
        let store = FakeAlarmStore()
        store.seed(stale)
        store.seed(fine)
        store.failingFirstCancelIDs = [stale]

        let report = try await BerserkAlarmEngine.reconcile([wanted], in: store)

        #expect(report.isClean)
        #expect(store.scheduledIDs == [wanted.id])
        #expect(store.cancelAttempts.filter { $0 == fine }.count == 1, "a cancel that worked is not repeated")
        #expect(!store.cancelAttempts.contains(wanted.id), "a wanted alarm is never cancelled")
    }

    @Test("A pass takes back a finished item's alarm whose first cancel failed, with nothing left uncancelled")
    func passRetriesAFailedCancel() async {
        await withScheduler { scheduler, now in
            var items = eligible(now)
            let (backend, sink) = arrange(Scenario(name: "", expectation: .alarms), scheduler)
            await scheduler.applyReminders(from: items, now: now, sink: sink)
            let before = alarmID(of: items[0])
            #expect(backend.store.scheduledIDs.contains(before))

            items[0].isCompleted = true                       // handed in; no next pass will follow
            backend.store.failingFirstCancelIDs = [before]
            let report = await scheduler.applyReminders(from: items, now: now, sink: sink)

            #expect(!backend.store.scheduledIDs.contains(before), "it must not ring")
            #expect(report.alarmsUncancelled == 0)
            #expect(report.isClean)
        }
    }

    /// The first failure used to end the pass: the alarms after it in the diff
    /// were never tried, and the throw sent every item to the buzzes
    /// (hardening plan C5, NOT-07).
    @Test("One alarm's failure does not stop the others being scheduled or cancelled")
    func oneFailureDoesNotAbortTheRest() async throws {
        let a = planAlarm("a"), b = planAlarm("b"), c = planAlarm("c")
        let stuck = UUID(), stale = UUID()
        let store = FakeAlarmStore()
        store.seed(stuck)
        store.seed(stale)
        store.failingCancelIDs = [stuck]
        store.failingScheduleIDs = [b.id]

        let report = try await BerserkAlarmEngine.reconcile([a, b, c], in: store)

        #expect(report.unscheduled == [b.id])
        #expect(report.uncancelled == [stuck])
        #expect(store.scheduledIDs == [a.id, c.id, stuck], "a and c were scheduled, stale went, stuck could not")
        #expect(store.scheduleAttempts.contains(a.id) && store.scheduleAttempts.contains(c.id))
        #expect(store.cancelAttempts.contains(stale))
    }

    @Test("An unreadable store is a failure, not a pass")
    func unreadableStoreThrows() async {
        let store = FakeAlarmStore()
        store.readFailure = FakeAlarmError.boom
        await #expect(throws: FakeAlarmError.self) {
            try await BerserkAlarmEngine.reconcile([planAlarm("a")], in: store)
        }
    }

    // MARK: Settlement

    @Test("Settlement: the buzzes are left out only when AlarmKit took the alarms")
    func settlementTable() {
        typealias Plan = BerserkAlarmPlan
        #expect(Plan.settlement(for: .alarmsReconciled)
                == Plan.Settlement(loudAlertsAsAlarms: true, alarmAction: .keep))
        #expect(Plan.settlement(for: .alarmsPartlyReconciled(buzzFor: ["canvas:b"]))
                == Plan.Settlement(loudAlertsAsAlarms: true, alarmAction: .keep,
                                   buzzFallbackAssignmentIDs: ["canvas:b"]))
        #expect(Plan.settlement(for: .alarmKitThrew)
                == Plan.Settlement(loudAlertsAsAlarms: false, alarmAction: .cancelIdle))
        #expect(Plan.settlement(for: .buzzes(.idleOnly))
                == Plan.Settlement(loudAlertsAsAlarms: false, alarmAction: .cancelIdle))
        #expect(Plan.settlement(for: .buzzes(.everything))
                == Plan.Settlement(loudAlertsAsAlarms: false, alarmAction: .cancelAll))
    }

    /// The only outcomes that may leave the buzzes out are the ones that
    /// leave the alarms in; every other one puts the buzzes back and takes the
    /// idle alarms away. The "both" and "neither" states are what this rules
    /// out.
    @Test("No outcome leaves the buzzes out without the alarms, or the alarms in with the buzzes")
    func settlementNeverSplits() {
        let outcomes: [BerserkAlarmPlan.Outcome] = [
            .alarmsReconciled, .alarmsPartlyReconciled(buzzFor: ["canvas:b"]), .alarmKitThrew,
            .buzzes(.idleOnly), .buzzes(.everything),
        ]
        for outcome in outcomes {
            let settlement = BerserkAlarmPlan.settlement(for: outcome)
            #expect(settlement.loudAlertsAsAlarms == (settlement.alarmAction == .keep), "\(outcome)")
        }
    }

    // MARK: The delivery decision

    @Test("The decision's table, with the scope of what to take back")
    func decisionTable() async {
        struct Row {
            var authorization: BerserkAlarmAuthorization
            var answer: BerserkAlarmAuthorization = .authorized
            var isReady = true
            var switchOn = true
            var fixture = false
            var plan = true
            let delivery: LoudAlertDelivery
            let scope: BerserkAlarmPlan.CancelScope
        }
        let rows: [Row] = [
            Row(authorization: .authorized, delivery: .alarms, scope: .idleOnly),
            Row(authorization: .denied, delivery: .buzzes, scope: .everything),
            Row(authorization: .notDetermined, answer: .denied, delivery: .buzzes, scope: .everything),
            Row(authorization: .notDetermined, answer: .failed, delivery: .buzzes, scope: .idleOnly),
            Row(authorization: .notDetermined, plan: false, delivery: .buzzes, scope: .idleOnly),
            Row(authorization: .authorized, isReady: false, delivery: .buzzes, scope: .idleOnly),
            Row(authorization: .authorized, switchOn: false, delivery: .buzzes, scope: .everything),
            Row(authorization: .authorized, fixture: true, delivery: .buzzes, scope: .everything),
        ]
        for row in rows {
            await withScheduler { scheduler, now in
                let backend = FakeAlarmBackend(authorization: row.authorization, answer: row.answer)
                backend.isReady = row.isReady
                scheduler.alarmBackendOverride = backend
                scheduler.setLoudAlertEnabled(row.switchOn)
                scheduler.fixtureDataProbe = { row.fixture }
                let plan = row.plan ? [planAlarm("a")] : []
                let decision = await scheduler.resolveLoudDelivery(plan: plan)
                #expect(decision.delivery == row.delivery, "\(row.authorization) \(row.answer)")
                #expect(decision.cancelScope == row.scope, "\(row.authorization) \(row.answer)")
            }
        }
    }

    @Test("Not asked yet: with something to ring the student is asked once; a yes means alarms")
    func asksOnceWhenThereIsSomethingToRing() async {
        await withScheduler { scheduler, _ in
            let backend = FakeAlarmBackend(authorization: .notDetermined, answer: .authorized)
            scheduler.alarmBackendOverride = backend
            let plan = [planAlarm("a")]
            let first = await scheduler.resolveLoudDelivery(plan: plan)
            #expect(first.delivery == .alarms && first.didPrompt)
            let second = await scheduler.resolveLoudDelivery(plan: plan)
            #expect(second.delivery == .alarms && !second.didPrompt)
            #expect(backend.authorizationRequests == 1)
        }
    }

    @Test("Nothing to ring, or a refusal on file, or AlarmKit unusable: the student is not asked")
    func noPromptWhenThereIsNothingToAskAbout() async {
        await withScheduler { scheduler, _ in
            let notAsked = FakeAlarmBackend(authorization: .notDetermined)
            scheduler.alarmBackendOverride = notAsked
            _ = await scheduler.resolveLoudDelivery(plan: [])
            #expect(notAsked.authorizationRequests == 0)

            let denied = FakeAlarmBackend(authorization: .denied)
            scheduler.alarmBackendOverride = denied
            _ = await scheduler.resolveLoudDelivery(plan: [planAlarm("a")])
            #expect(denied.authorizationRequests == 0, "a refusal on file is final")

            let notReady = FakeAlarmBackend(authorization: .notDetermined)
            notReady.isReady = false
            scheduler.alarmBackendOverride = notReady
            _ = await scheduler.resolveLoudDelivery(plan: [planAlarm("a")])
            #expect(notReady.authorizationRequests == 0)
        }
    }

    // MARK: Fixture data never rings (AppState's own answer)

    @Test("The probe is AppState.isUsingFixtureData: fixture data gets the buzzes and never asks AlarmKit")
    func fixtureDataNeverRings() async {
        await withScheduler { scheduler, _ in
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            let backend = FakeAlarmBackend(authorization: .notDetermined)
            scheduler.alarmBackendOverride = backend
            scheduler.fixtureDataProbe = { state.isUsingFixtureData }
            let plan = [planAlarm("a")]

            state.forceFixtureDataForTesting(true)
            let fixture = await scheduler.resolveLoudDelivery(plan: plan)
            #expect(fixture.delivery == .buzzes && fixture.cancelScope == .everything)
            #expect(backend.authorizationRequests == 0, "not even the permission prompt, for sample data")

            state.forceFixtureDataForTesting(false)
            let real = await scheduler.resolveLoudDelivery(plan: plan)
            #expect(real.delivery == .alarms)
        }
    }

    @Test("Nothing forbids alarms but fixture data")
    func fixtureRule() {
        #expect(BerserkAlarmPlan.alarmsAllowed(isUsingFixtureData: false))
        #expect(!BerserkAlarmPlan.alarmsAllowed(isUsingFixtureData: true))
    }

    // MARK: One pass at a time

    @Test("A call that arrives mid-run waits for the next run; only the newest of several is kept")
    func serializerFoldsCalls() async {
        let serializer = RescheduleSerializer<Int>()
        let log = PassLog()
        let gate = Gate()

        let first = Task {
            await serializer.submit(1) { n in
                log.begin(n)
                if n == 1 { await gate.wait() }
                log.end()
            }
        }
        while !gate.isWaiting { await Task.yield() }

        // While 1 is in flight.
        await serializer.submit(2) { _ in Issue.record("a folded call's own closure must not run") }
        await serializer.submit(3) { _ in Issue.record("a folded call's own closure must not run") }
        #expect(log.ran == [1], "nothing else has started")
        #expect(serializer.isRunning)

        gate.open()
        await first.value
        #expect(log.ran == [1, 3], "2 was superseded; 3 ran once, after 1")
        #expect(log.mostAtOnce == 1)
        #expect(!serializer.isRunning)

        await serializer.submit(4) { n in log.begin(n); log.end() }
        #expect(log.ran == [1, 3, 4], "idle again, so the next call runs at once")
    }

    @Test("A call that arrives during the rerun is run again, and the runs never overlap")
    func serializerKeepsRerunning() async {
        let serializer = RescheduleSerializer<Int>()
        let log = PassLog()
        await serializer.submit(1) { n in
            log.begin(n)
            if n == 1 { await serializer.submit(2) { _ in } }
            if n == 2 { await serializer.submit(3) { _ in } }
            await Task.yield()
            log.end()
        }
        #expect(log.ran == [1, 2, 3])
        #expect(log.mostAtOnce == 1)
    }

    /// The scenario that motivated the serializer, through the real
    /// `reschedule`: the alarm permission prompt is open, the scene reactivates
    /// and the dashboard asks for another reschedule. It must neither start a
    /// second prompt nor schedule an alarm twice, and the newest items must be
    /// the ones applied.
    @Test("A reschedule that arrives during the permission prompt waits, then the newest items are applied once")
    func rescheduleDuringThePrompt() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let backend = FakeAlarmBackend(authorization: .notDetermined, answer: .authorized)
            let sink = FakeSink()
            scheduler.alarmBackendOverride = backend
            scheduler.notificationSinkOverride = sink
            scheduler.authStatusOverride = .authorized
            let gate = Gate()
            backend.duringRequest = { await gate.wait() }

            let a = item("CIS 1200", "a", due: now + 3 * 3600)
            let b = item("CIS 1200", "b", due: now + 4 * 3600)
            let c = item("CIS 1200", "c", due: now + 5 * 3600)

            let firstCall = Task { await scheduler.reschedule(from: [a], now: now) }
            while !gate.isWaiting { await Task.yield() }

            // Dismissing the prompt reactivates the scene: two more calls.
            await scheduler.reschedule(from: [a, b], now: now)
            await scheduler.reschedule(from: [a, c], now: now)
            #expect(backend.authorizationRequests == 1, "no second prompt")
            #expect(backend.store.scheduleAttempts.isEmpty, "nothing scheduled by the folded calls")
            #expect(sink.requests.isEmpty && sink.removals == 0, "and the notifications untouched")

            gate.open()
            await firstCall.value

            #expect(backend.store.scheduleAttempts.count == Set(backend.store.scheduleAttempts).count,
                    "no alarm id scheduled twice")
            #expect(backend.store.scheduledIDs == [alarmID(of: a), alarmID(of: c)], "the newest items won")
            #expect(!backend.store.scheduleAttempts.contains(alarmID(of: b)), "the superseded call never ran")
            for assignmentID in ["canvas:a", "canvas:b", "canvas:c"] {
                #expect(sink.buzzCount(for: assignmentID) == 0, "\(assignmentID): alarms, so no buzzes")
            }
            #expect(backend.cancelIdleCalls == 0 && backend.cancelAllCalls == 0, "and no fallback happened")
        }
    }

    // MARK: Re-planning the notifications without emptying the queue

    /// Buzz-mode scenario (AlarmKit refused), so the sink holds both the
    /// ordinary reminders and the buzzes.
    private func buzzRig(_ scheduler: NotificationScheduler) -> (FakeAlarmBackend, FakeSink) {
        arrange(Scenario(name: "", authorization: .denied, expectation: .buzzes), scheduler)
    }

    /// A re-plan used to `removeAllPending()` and then `add` every request
    /// again, so for the length of the awaited adds the queue held a fraction
    /// of the plan (hardening plan C5, UCR-4). A request the plan still wants
    /// is now never removed.
    @Test("A re-plan over unchanged items removes nothing and never shrinks the queue")
    func replanOverUnchangedItemsRemovesNothing() async {
        await withScheduler { scheduler, now in
            let (_, sink) = buzzRig(scheduler)
            let items = eligible(now) + noise(now)
            await scheduler.applyReminders(from: items, now: now, sink: sink)
            let before = Set(sink.requests.map(\.identifier))
            #expect(!before.isEmpty)

            await scheduler.applyReminders(from: items, now: now, sink: sink)

            #expect(sink.removals == 0, "removeAllPending is for reminders-off, not a re-plan")
            #expect(sink.removedIdentifiers.isEmpty, "nothing was stale")
            #expect(Set(sink.requests.map(\.identifier)) == before)
            #expect(sink.mostPending == before.count, "the queue never held more than the plan")
        }
    }

    @Test("Only the requests the plan no longer holds are taken back, and before anything is added")
    func staleRequestsAreTakenBackFirst() async {
        await withScheduler { scheduler, now in
            let (_, sink) = buzzRig(scheduler)
            var items = eligible(now) + noise(now)
            await scheduler.applyReminders(from: items, now: now, sink: sink)
            let first = sink.log.count

            items[0].isCompleted = true            // "a" is handed in
            await scheduler.applyReminders(from: items, now: now, sink: sink)

            let pass = Array(sink.log[first...])
            let removed = pass.filter { $0.hasPrefix("remove:") }.map { String($0.dropFirst("remove:".count)) }
            #expect(!removed.isEmpty)
            #expect(removed.allSatisfy { $0.contains("canvas:a") }, "only the finished item's requests: \(removed)")
            #expect(removed.contains { $0.hasPrefix("loud:canvas:a:") }, "its buzzes are taken back")
            #expect(sink.buzzCount(for: "canvas:a") == 0)
            #expect(sink.buzzCount(for: "canvas:b") == NotificationScheduler.loudAlertCount)
            let firstAdd = pass.firstIndex { $0.hasPrefix("add:") } ?? pass.count
            let lastRemove = pass.lastIndex { $0.hasPrefix("remove:") } ?? -1
            #expect(lastRemove < firstAdd, "removals first, so the queue never passes the cap")
            #expect(sink.removals == 0)
        }
    }

    /// The whole plan swapped for another of the same size. Adding the new
    /// plan beside the old and removing the old afterwards would hold twice the
    /// cap for a moment, and iOS keeps about sixty-four.
    @Test("Swapping a full plan for another never holds more than the plan at once")
    func replanStaysUnderTheCap() async {
        await withScheduler { scheduler, now in
            let (_, sink) = arrange(
                Scenario(name: "", authorization: .denied, loudSwitchOn: false, expectation: .neither), scheduler)
            let courses = ["CIS 1200", "MATH 1400", "PHYS 0150"]
            @MainActor func plan(_ tag: String) -> [DashItem] {
                (0..<40).map { item(courses[$0 % 3], "\(tag)\($0)", due: now + 8 * 86_400 + Double($0) * 3600) }
            }
            await scheduler.applyReminders(from: plan("old"), now: now, sink: sink)
            #expect(sink.requests.count == NotificationScheduler.maxPending)

            await scheduler.applyReminders(from: plan("new"), now: now, sink: sink)

            #expect(sink.requests.count == NotificationScheduler.maxPending)
            #expect(sink.requests.allSatisfy { $0.identifier.contains("canvas:new") })
            #expect(sink.mostPending <= NotificationScheduler.maxPending, "at most the cap at every step")
        }
    }

    @Test("A request the center refuses is counted, the rest are still added, and the next pass adds it")
    func refusedAddsAreCounted() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let (_, sink) = buzzRig(scheduler)
            let items = eligible(now)
            let refused = "due:canvas:b:3600"
            sink.refusedIdentifiers = [refused]

            let report = await scheduler.applyReminders(from: items, now: now, sink: sink)

            #expect(report.notificationsFailed == 1)
            #expect(report.notificationsAdded == sink.requests.count)
            #expect(sink.requests.count > 1, "one refusal does not stop the others")
            #expect(!sink.requests.contains { $0.identifier == refused })
            #expect(!report.isClean)

            sink.refusedIdentifiers = []
            let next = await scheduler.applyReminders(from: items, now: now, sink: sink)
            #expect(next.isClean && sink.requests.contains { $0.identifier == refused })
        }
    }

    @Test("The scheduler keeps the latest pass's counts")
    func lastPassReportIsKept() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let backend = FakeAlarmBackend(authorization: .authorized)
            let sink = FakeSink()
            scheduler.alarmBackendOverride = backend
            scheduler.notificationSinkOverride = sink
            scheduler.authStatusOverride = .authorized
            #expect(scheduler.lastPassReport == nil)
            let items = eligible(now)
            backend.store.failingScheduleIDs = [alarmID(of: items[1])]
            sink.refusedIdentifiers = ["due:canvas:c:3600"]

            await scheduler.reschedule(from: items, now: now)

            let report = scheduler.lastPassReport
            #expect(report?.notificationsFailed == 1)
            #expect(report?.alarmsUnscheduled == 1)
            #expect(report?.alarmsUncancelled == 0)
            #expect(report?.isClean == false)
        }
    }

    /// The partial fallback adds one item's buzzes and nothing else changes:
    /// the first pass's reminders are still wanted by the second.
    @Test("A fallback for one refused alarm adds that item's buzzes and removes nothing the plan still holds")
    func fallbackAddsWithoutRemoving() async {
        await withScheduler { scheduler, now in
            let items = eligible(now)
            let (backend, sink) = arrange(
                Scenario(name: "", fault: .secondScheduleFails, expectation: .alarmsExceptSecond), scheduler)
            backend.store.failingScheduleIDs = [alarmID(of: items[1])]

            await scheduler.applyReminders(from: items + noise(now), now: now, sink: sink)

            #expect(sink.removals == 0)
            #expect(sink.removedIdentifiers.isEmpty, "the buzzes were added to what the first pass left")
            #expect(sink.buzzCount(for: items[1].assignment.id) == NotificationScheduler.loudAlertCount)
            #expect(sink.buzzCount(for: items[0].assignment.id) == 0)
        }
    }

    // MARK: A re-plan with nobody at the phone (the background wake)

    /// A rig for `reschedule` and `rescheduleWithoutPrompting`: reminders on,
    /// notifications allowed, AlarmKit as the scenario says.
    private func wakeRig(
        _ scheduler: NotificationScheduler,
        authorization: BerserkAlarmAuthorization,
        answer: BerserkAlarmAuthorization = .authorized
    ) -> (FakeAlarmBackend, FakeSink) {
        let backend = FakeAlarmBackend(authorization: authorization, answer: answer)
        let sink = FakeSink()
        scheduler.alarmBackendOverride = backend
        scheduler.notificationSinkOverride = sink
        scheduler.authStatusOverride = .authorized
        return (backend, sink)
    }

    /// The background wake cannot show AlarmKit's permission question. A
    /// never-asked permission therefore means "not allowed yet": the buzzes
    /// for this pass, and the question stays for the next time the app is
    /// open. The control half is the same scheduler through `reschedule`,
    /// which does ask, so the test cannot pass because the question was
    /// never going to be asked.
    @Test("A re-plan without a prompt never asks AlarmKit for permission, and a never-asked permission means the buzzes")
    func replanWithoutPromptNeverAsks() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let (backend, sink) = wakeRig(scheduler, authorization: .notDetermined)
            let items = eligible(now)

            await scheduler.rescheduleWithoutPrompting(from: items, now: now)

            #expect(backend.authorizationRequests == 0, "nobody is looking at the phone")
            #expect(backend.store.scheduledIDs.isEmpty)
            #expect(items.allSatisfy { sink.buzzCount(for: $0.assignment.id) == NotificationScheduler.loudAlertCount },
                    "the student is still warned, by the buzzes")

            await scheduler.reschedule(from: items, now: now)

            #expect(backend.authorizationRequests == 1, "the foreground pass puts the question")
            #expect(backend.store.scheduledIDs == Set(items.map(alarmID(of:))))
        }
    }

    @Test("A re-plan without a prompt takes back the alarm of work handed in since, and stops one that is ringing")
    func replanWithoutPromptTakesBackFinishedWork() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let (backend, sink) = wakeRig(scheduler, authorization: .authorized)
            var items = eligible(now)
            // Due in five minutes, so its alarm time has passed: it is
            // ringing, and the plan no longer wants it.
            let late = item("CIS 1200", "late", due: now + 300)
            backend.store.seed(alarmID(of: late), ringing: true)
            await scheduler.reschedule(from: items + [late], now: now)
            #expect(backend.store.scheduledIDs == Set(items.map(alarmID(of:))).union([alarmID(of: late)]))

            // Between the two passes the student hands in `a` and `late` on
            // Canvas, and the wake's sync learns it.
            items[0].isCompleted = true
            let lateDone = item("CIS 1200", "late", due: now + 300, completed: true)
            await scheduler.rescheduleWithoutPrompting(from: items + [lateDone], now: now)

            #expect(!backend.store.scheduledIDs.contains(alarmID(of: items[0])), "the finished item's alarm is gone")
            #expect(backend.store.stopCalls == [alarmID(of: lateDone)], "the ringing one is stopped")
            #expect(backend.store.scheduledIDs == [alarmID(of: items[1]), alarmID(of: items[2])])
            #expect(backend.authorizationRequests == 0)
            #expect(sink.buzzCount(for: items[0].assignment.id) == 0)
        }
    }

    /// The serializer folds a call that arrives mid-pass into the running
    /// pass's rerun. That rerun has to be judged by the folded call's
    /// permission: the question is never answered here (`.failed` leaves the
    /// permission unasked), so a rerun that kept the first caller's right to
    /// prompt would ask a second time, from what is now a background pass.
    @Test("A background re-plan that joins a running pass keeps its no-prompt rule for the rerun")
    func foldedNoPromptCallKeepsItsRule() async {
        await withScheduler(remindersOn: true) { scheduler, now in
            let (backend, _) = wakeRig(scheduler, authorization: .notDetermined, answer: .failed)
            let gate = Gate()
            backend.duringRequest = { await gate.wait() }
            let a = item("CIS 1200", "a", due: now + 3 * 3600)
            let b = item("CIS 1200", "b", due: now + 4 * 3600)

            let foreground = Task { await scheduler.reschedule(from: [a], now: now) }
            while !gate.isWaiting { await Task.yield() }
            await scheduler.rescheduleWithoutPrompting(from: [a, b], now: now)
            gate.open()
            await foreground.value

            #expect(backend.authorizationRequests == 1, "the rerun is the background call's, and must not ask again")
        }
    }

    // MARK: - Fixture

    /// A scheduler over a scratch `UserDefaults` suite. `remindersOn` primes the
    /// persisted master switch ("notif.enabled", pinned by
    /// `SharedDefaultsMigrationTests`), which is off for a fresh suite and which
    /// `reschedule` honours; `setEnabled(true)` would ask the notification
    /// center for permission, which a test cannot.
    private func withScheduler(
        remindersOn: Bool = false,
        _ body: (NotificationScheduler, Date) async -> Void
    ) async {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("could not open a scratch defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        if remindersOn { defaults.set(true, forKey: "notif.enabled") }
        await body(NotificationScheduler(defaults: defaults), Date())
    }

    /// Three items the loud alert covers, and the fake AlarmKit and fake
    /// notification center a scenario describes, wired into the scheduler.
    private func arrange(_ scenario: Scenario, _ scheduler: NotificationScheduler) -> (FakeAlarmBackend, FakeSink) {
        let backend = FakeAlarmBackend(authorization: scenario.authorization, answer: scenario.promptAnswer)
        backend.isReady = scenario.isReady
        scheduler.alarmBackendOverride = scenario.hasBackend ? backend : nil
        let sink = FakeSink()
        scheduler.notificationSinkOverride = sink
        scheduler.fixtureDataProbe = { scenario.fixtureData }
        scheduler.setLoudAlertEnabled(scenario.loudSwitchOn)
        return (backend, sink)
    }

    private func eligible(_ now: Date) -> [DashItem] {
        [
            item("CIS 1200", "a", due: now + 3 * 3600),
            item("CIS 1200", "b", due: now + 4 * 3600),
            item("CIS 1200", "c", due: now + 5 * 3600),
        ]
    }

    /// Work the alert does not cover: a reading keeps its plain reminders, and
    /// a finished item has nothing to say.
    private func noise(_ now: Date) -> [DashItem] {
        [
            item("CIS 1200", "reading", due: now + 5 * 3600, kind: .event),
            item("CIS 1200", "done", due: now + 5 * 3600, completed: true),
        ]
    }

    private func item(
        _ course: String, _ id: String, due: Date?,
        kind: Assignment.Kind = .assignment,
        completed: Bool = false,
        override: Date? = nil
    ) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: id, kind: kind,
                                   course: course, title: "HW \(id)", dueAt: due, url: nil),
            dueOverride: override, isCompleted: completed, completedAt: nil
        )
    }

    /// The id the plan gives this item's alarm, derived independently of the
    /// planner: (assignment id, effective due minus the lead).
    private func alarmID(of item: DashItem) -> UUID {
        BerserkAlarmPlan.alarmID(
            assignmentID: item.assignment.id,
            fireDate: (item.due ?? .distantPast).addingTimeInterval(-NotificationScheduler.loudAlertLead))
    }

    private func planAlarm(_ id: String) -> PlannedAlarm {
        let fire = Date(timeIntervalSince1970: 1_800_000_000)
        return PlannedAlarm(id: BerserkAlarmPlan.alarmID(assignmentID: id, fireDate: fire),
                            assignmentID: id, fireDate: fire, title: id,
                            course: "CIS 1200",
                            dueAt: fire.addingTimeInterval(NotificationScheduler.loudAlertLead),
                            link: nil)
    }
}
