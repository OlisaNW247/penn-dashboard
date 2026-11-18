import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Marco, 2026-11-18: work no read can ever confirm (an external-tool survey,
/// a modules row with no Canvas id) gets the three buzzes at the sweep time,
/// never the alarm, whatever the delivery. The invariant under test is the
/// one the settlement already keeps: every loud item ends with exactly one of
/// an alarm or its buzzes.
@MainActor
@Suite("Sweeper: buzz-only delivery")
struct BuzzOnlyDeliveryTests {

    private func make(_ id: String, now: Date, tool: Bool = false, hours: Double = 3,
                      source: Assignment.Source = .canvas, url: String? = nil) -> DashItem {
        var i = DashItem(
            assignment: Assignment(source: source, sourceID: id, kind: .assignment, course: "CIS 1200",
                                   title: "HW \(id)", dueAt: now + hours * 3600, url: url.flatMap(URL.init(string:))),
            dueOverride: nil, isCompleted: false, completedAt: nil)
        i.isExternalTool = tool
        return i
    }

    private func rig(_ authorization: BerserkAlarmAuthorization, _ body: (NotificationScheduler, FakeAlarmBackend, FakeSink, Date) async -> Void) async {
        let name = "lhf.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { return }
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "notif.enabled")
        let scheduler = NotificationScheduler(defaults: defaults)
        let backend = FakeAlarmBackend(authorization: authorization)
        let sink = FakeSink()
        scheduler.alarmBackendOverride = backend
        scheduler.notificationSinkOverride = sink
        scheduler.authStatusOverride = .authorized
        await body(scheduler, backend, sink, Date())
    }

    @Test("The plan leaves unconfirmable items out and keeps the others' ids")
    func planExcludes() async {
        await rig(.authorized) { scheduler, _, _, now in
            let sure = make("sure", now: now)
            let items = [sure, make("tool", now: now, tool: true),
                         make("mod", now: now, source: .canvasModules)]
            let plan = scheduler.plannedAlarms(from: items, now: now)
            #expect(plan.map(\.assignmentID) == [sure.assignment.id])
            #expect(plan.first?.id == BerserkAlarmPlan.alarmID(
                assignmentID: sure.assignment.id,
                fireDate: (sure.due ?? .distantPast).addingTimeInterval(-NotificationScheduler.loudAlertLead)),
                    "alarm ids do not change for confirmable work")
        }
    }

    @Test("Alarm delivery: the unconfirmable item has three buzzes and no alarm, its neighbour the reverse")
    func alarmsMode() async {
        await rig(.authorized) { scheduler, backend, sink, now in
            let sure = make("sure", now: now)
            let tool = make("tool", now: now, tool: true, hours: 4)
            let mod = make("mod", now: now, hours: 5, source: .canvasModules)
            await scheduler.reschedule(from: [sure, tool, mod], now: now)

            #expect(backend.store.scheduledIDs.count == 1)
            #expect(sink.buzzCount(for: sure.assignment.id) == 0)
            #expect(sink.buzzCount(for: tool.assignment.id) == NotificationScheduler.loudAlertCount)
            #expect(sink.buzzCount(for: mod.assignment.id) == NotificationScheduler.loudAlertCount)
        }
    }

    @Test("Buzz delivery: everything has buzzes and nothing is alarmed")
    func buzzesMode() async {
        await rig(.denied) { scheduler, backend, sink, now in
            let items = [make("sure", now: now), make("tool", now: now, tool: true, hours: 4)]
            await scheduler.reschedule(from: items, now: now)
            #expect(backend.store.scheduledIDs.isEmpty)
            for i in items { #expect(sink.buzzCount(for: i.assignment.id) == NotificationScheduler.loudAlertCount) }
        }
    }

    @Test("Every loud item ends with exactly one of an alarm or buzzes, across deliveries")
    func exactlyOne() async {
        for auth in [BerserkAlarmAuthorization.authorized, .denied] {
            await rig(auth) { scheduler, backend, sink, now in
                let items = [make("a", now: now), make("b", now: now, tool: true, hours: 4),
                             make("c", now: now, hours: 5, source: .canvasModules)]
                await scheduler.reschedule(from: items, now: now)
                let alarmed = Set(scheduler.plannedAlarms(from: items, now: now).map(\.assignmentID))
                for i in items {
                    let hasAlarm = alarmed.contains(i.assignment.id) && !backend.store.scheduledIDs.isEmpty
                    let hasBuzz = sink.buzzCount(for: i.assignment.id) > 0
                    #expect(hasAlarm != hasBuzz, "\(i.assignment.sourceID) under \(auth)")
                }
            }
        }
    }

    @Test("A buzz-only item's wake moments are not planned")
    func noWakeMoments() async {
        await rig(.authorized) { scheduler, _, _, now in
            let plan = scheduler.plannedAlarms(from: [make("tool", now: now, tool: true)], now: now)
            #expect(plan.isEmpty)
        }
    }
}
