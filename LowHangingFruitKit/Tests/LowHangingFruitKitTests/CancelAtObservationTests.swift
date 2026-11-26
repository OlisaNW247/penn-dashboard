import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `NotificationScheduler.cancelForSubmitted`: the reminders, buzzes and
/// Sweeper alarm of work a source has confirmed submitted are taken back at
/// the moment of observation, through the scheduler's own serializer. Fakes
/// for the notification center and AlarmKit (`FakeSink`, `FakeAlarmBackend`
/// from `BerserkAlarmDeliveryTests`); scratch defaults so nothing writes the
/// shared domain.
@MainActor
@Suite("Cancel at observation")
struct CancelAtObservationTests {
    let due = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ sourceID: String, url: String? = nil, linkedID: String? = nil) -> DashItem {
        DashItem(
            assignment: Assignment(source: .canvas, sourceID: sourceID, kind: .assignment, course: "CIS 1200",
                                   title: "HW \(sourceID)", dueAt: due, url: url.flatMap(URL.init(string:)),
                                   linkedID: linkedID),
            dueOverride: nil, isCompleted: false, completedAt: nil)
    }

    private func request(_ id: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(), trigger: nil)
    }

    /// The alarm ids an item could have: the default 10-minute one, and a
    /// 30-minute one a student's earlier setting left behind.
    private func alarms(_ item: DashItem) -> [UUID] {
        [10, 30].map {
            BerserkAlarmPlan.alarmID(assignmentID: item.assignment.id,
                                     fireDate: due.addingTimeInterval(-Double($0 * 60)))
        }
    }

    private func requestIDs(_ item: DashItem) -> [String] {
        let id = item.assignment.id
        return ["due:\(id):\(LeadOffset.h1.rawValue)", "due:\(id):\(LeadOffset.h24.rawValue)"]
            + (1...NotificationScheduler.loudAlertCount).map { "loud:\(id):\($0)" }
    }

    private struct Rig {
        let scheduler: NotificationScheduler
        let sink: FakeSink
        let backend: FakeAlarmBackend
        let defaults: UserDefaults
        let suite: String
    }

    private func rig(_ items: [DashItem], remindersOn: Bool = false) -> Rig {
        let suite = "lhf.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if remindersOn { defaults.set(true, forKey: "notif.enabled") }
        let scheduler = NotificationScheduler(defaults: defaults)
        let sink = FakeSink()
        let backend = FakeAlarmBackend(authorization: .authorized)
        scheduler.notificationSinkOverride = sink
        scheduler.alarmBackendOverride = backend
        for item in items {
            for id in requestIDs(item) { sink.seed(request(id)) }
            for id in alarms(item) { backend.store.seed(id) }
        }
        return Rig(scheduler: scheduler, sink: sink, backend: backend, defaults: defaults, suite: suite)
    }

    private func pending(_ r: Rig) -> Set<String> { Set(r.sink.requests.map(\.identifier)) }

    @Test("One observation removes exactly that item's requests, buzzes and alarms")
    func oneItem() async {
        let a = item("a"), b = item("b")
        let r = rig([a, b])
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let ringing = alarms(a)[0]
        r.backend.store.seed(ringing, ringing: true)

        let counts = await r.scheduler.cancelForSubmitted([a.id], items: [a, b], source: .grades)

        #expect(Set(r.sink.removedIdentifiers).isSuperset(of: Set(requestIDs(a))))
        #expect(pending(r) == Set(requestIDs(b)))
        #expect(r.backend.store.scheduledIDs == Set(alarms(b)))
        #expect(r.backend.store.stopCalls.contains(ringing), "a ringing alarm is stopped, not only cancelled")
        #expect(counts.requests == SubmissionObservation.cancellations(submittedAssignmentIDs: [a.id], items: [a]).requestIDs.count)
        #expect(counts.alarms > 0)
        #expect(SweeperCounts.snapshot(defaults: r.defaults)[SweeperCounts.cancelledKey("grades")] == 1)
    }

    @Test("Two ids remove both items and nothing of a third")
    func twoItems() async {
        let a = item("a"), b = item("b"), c = item("c")
        let r = rig([a, b, c])
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        await r.scheduler.cancelForSubmitted([a.id, b.id], items: [a, b, c])
        #expect(pending(r) == Set(requestIDs(c)))
        #expect(r.backend.store.scheduledIDs == Set(alarms(c)))
    }

    @Test("A Canvas assignment id matches through canvasAssignmentID")
    func canvasID() async {
        let a = item("a", url: "https://canvas.example.edu/courses/1/assignments/777"), b = item("b")
        let r = rig([a, b])
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        await r.scheduler.cancelForSubmitted(["777"], items: [a, b], source: .grades)
        #expect(pending(r) == Set(requestIDs(b)))
        #expect(r.backend.store.scheduledIDs == Set(alarms(b)))
    }

    @Test("A linked twin's id matches the card it is linked to")
    func twin() async {
        let a = item("a", linkedID: "gradescope:zz"), b = item("b")
        let r = rig([a, b])
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        await r.scheduler.cancelForSubmitted(["gradescope:zz"], items: [a, b], source: .gradescope)
        #expect(pending(r) == Set(requestIDs(b)))
    }

    @Test("An empty set, or an id no item has, calls nothing")
    func nothing() async {
        let a = item("a")
        let r = rig([a])
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let none = await r.scheduler.cancelForSubmitted([], items: [a])
        let unknown = await r.scheduler.cancelForSubmitted(["nope"], items: [a])
        #expect(none == (0, 0) && unknown == (0, 0))
        #expect(r.sink.removedIdentifiers.isEmpty)
        #expect(r.backend.store.cancelAttempts.isEmpty && r.backend.store.stopCalls.isEmpty)
        #expect(pending(r) == Set(requestIDs(a)))
        #expect(SweeperCounts.snapshot(defaults: r.defaults).isEmpty)
    }

    @Test("An alarm AlarmKit never held is ignored, not thrown out of the cancel")
    func missingAlarmIsIgnored() async {
        let a = item("a")
        let r = rig([])      // nothing seeded: every id is one AlarmKit does not hold
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let counts = await r.scheduler.cancelForSubmitted([a.id], items: [a])
        #expect(counts.alarms > 0)
        #expect(r.backend.store.scheduledIDs.isEmpty)
    }

    @Test("A cancel that arrives during a running pass is applied by it, not lost")
    func foldedIntoARunningPass() async {
        let a = item("a"), b = item("b")
        let r = rig([], remindersOn: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        r.scheduler.authStatusOverride = .authorized
        r.scheduler.setLoudAlertEnabled(true)
        let gate = Gate()
        let held = FakeAlarmBackend(authorization: .notDetermined, answer: .authorized)
        held.duringRequest = { await gate.wait() }
        r.scheduler.alarmBackendOverride = held
        let items = [a, b].map { DashItem(assignment: Assignment(
            source: .canvas, sourceID: $0.assignment.sourceID, kind: .assignment, course: "CIS 1200",
            title: "HW", dueAt: Date().addingTimeInterval(3 * 3600), url: nil), dueOverride: nil, isCompleted: false, completedAt: nil) }

        let pass = Task { await r.scheduler.reschedule(from: items) }
        for _ in 0..<200 where !gate.isWaiting { await Task.yield() }
        #expect(gate.isWaiting, "the pass is held at the permission question")
        _ = await r.scheduler.cancelForSubmitted([items[0].id], items: items)
        gate.open()
        await pass.value

        let ids = pending(r)
        #expect(!ids.contains { $0.contains(items[0].assignment.id) }, "the folded cancel ran in the rerun")
        #expect(ids.contains { $0.contains(items[1].assignment.id) }, "the other item's plan is intact")
    }

    @Test("The cancel path never completes anything")
    func neverCompletes() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        for name in ["NotificationScheduler.swift", "SubmissionObservation.swift", "AppState+LastHourPoll.swift",
                     "LastHourPoller.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(!code.contains("markCompleted("), "\(name) must never complete work")
            #expect(!code.contains("setCompleted("), "\(name) must never complete work")
        }
    }
}
