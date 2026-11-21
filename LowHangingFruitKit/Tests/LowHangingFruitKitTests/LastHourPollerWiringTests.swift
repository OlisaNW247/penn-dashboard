import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The poller's real wiring (`LastHourPoller.start(state:scheduler:vm:)`)
/// against real objects: a Canvas feed item whose due date the student edited
/// to 30 minutes from now, a 20-minute Sweeper lead, so the ring is 10 minutes
/// out. Reproduces the phone's "alarm rang, poll never ran". The wiring reads
/// the real clock (`nextSweep` and `pollPlannerWindowIfInsideTheHour` default
/// `now`), so the scenario is built around `Date()` taken once.
@MainActor
@Suite("Last-hour poller wiring")
struct LastHourPollerWiringTests {
    private final class Calls: @unchecked Sendable { var n = 0 }

    private struct Rig {
        let state: AppState
        let scheduler: NotificationScheduler
        let vm: DashboardViewModel
        let defaults: UserDefaults
        let suite: String
        let now: Date
        let item: Assignment
    }

    private func rig(enableReminders: Bool = true, kind: Assignment.Kind = .assignment,
                     source: Assignment.Source = .canvas) throws -> Rig {
        let suite = "LastHourPollerWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        if enableReminders { defaults.set(true, forKey: "notif.enabled") }
        defaults.set(20, forKey: "notif.sweeperMinutes")
        let now = Date()
        let a = Assignment(
            source: source, sourceID: "event-assignment-15044555", kind: kind, course: "PHYS 0151",
            title: "Worksheet 10.1", dueAt: now.addingTimeInterval(30 * 3600),
            url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_1949400#assignment_15044555"))
        let store = try AssignmentStore(inMemory: true)
        store.upsert([a])
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.structuredDefaults = defaults
        state.sweeperCountsDefaults = defaults
        state.canvasItems = [a]
        state.setCourse("PHYS 0151", selected: true)
        state.setDueDateEdit(now.addingTimeInterval(30 * 60), for: a)
        state.rebuildDashboardItemsForTesting(now: now)
        let scheduler = NotificationScheduler(defaults: defaults)
        let vm = DashboardViewModel()
        vm.bind(to: state)
        vm.reload(preservingEdits: true)
        return Rig(state: state, scheduler: scheduler, vm: vm, defaults: defaults, suite: suite, now: now, item: a)
    }

    @Test("the view model carries the edited date")
    func editedDate() throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let item = try #require(r.vm.items.first { $0.assignment.id == r.item.id })
        #expect(item.due == r.now.addingTimeInterval(30 * 60))
    }

    @Test("plannedAlarms holds the ring at now + 10 min")
    func planned() throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let alarms = r.scheduler.plannedAlarms(from: r.vm.items, now: r.now)
        #expect(alarms.count == 1)
        #expect(alarms.first?.fireDate == r.now.addingTimeInterval(10 * 60))
    }

    @Test("nextSweep agrees with plannedAlarms")
    func nextSweep() throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        #expect(r.scheduler.nextSweep(in: r.vm.items, now: r.now)?.ringAt == r.now.addingTimeInterval(10 * 60))
    }

    @Test("start(state:scheduler:vm:) reaches the planner read")
    func wiringPolls() async throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let calls = Calls()
        r.state.plannerWindowFetchForTesting = { _, _ in
            calls.n += 1
            return PlannerWindowResult(items: [], completed: true, remaining: 700)
        }
        let poller = LastHourPoller(countsDefaults: r.defaults, sleep: { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        })
        poller.start(state: r.state, scheduler: r.scheduler, vm: r.vm)
        for _ in 0..<2000 where r.state.lastPlannerWindowResult == nil { await Task.yield() }
        poller.stop()
        #expect(calls.n == 1)
        #expect(r.state.lastPlannerWindowResult != nil)
    }

    @Test("reminders off: nextSweep is nil while plannedAlarms is not (a reschedule would cancel the alarm)")
    func remindersOff() throws {
        let r = try rig(enableReminders: false)
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        #expect(r.scheduler.nextSweep(in: r.vm.items, now: r.now) == nil)
        #expect(r.scheduler.plannedAlarms(from: r.vm.items, now: r.now).count == 1)
    }

    @Test("an item with no Canvas id in its URL still rings and is still the next sweep")
    func noURLFragment() throws {
        let r = try rig()
        defer { UserDefaults.standard.removePersistentDomain(forName: r.suite) }
        let item = try #require(r.vm.items.first)
        #expect(!item.requiresNoSubmission && !item.showsNothingToSubmit)
        #expect(r.scheduler.sweeperSettings.quietReason(for: item, courseRemindersOn: { _ in true }) == nil)
    }

    @Test("the trace logs a word only when it changes")
    func traceWords() async {
        let suite = "LastHourPollerWiringTests.trace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        final class Words: @unchecked Sendable { var w: [String] = [] }
        let words = Words()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let poller = LastHourPoller(clock: { now }, countsDefaults: defaults, log: { words.w.append($0) })
        let ok: @MainActor (Date?) async -> PlannerWindowResult? = { _ in PlannerWindowResult(items: [], completed: true, remaining: 700) }
        await poller.tick(nextRing: nil, poll: ok)
        await poller.tick(nextRing: nil, poll: ok)
        await poller.tick(nextRing: now.addingTimeInterval(7200), poll: ok)
        await poller.tick(nextRing: now.addingTimeInterval(7200), poll: ok)
        await poller.tick(nextRing: now.addingTimeInterval(600), poll: ok)
        #expect(words.w == ["tick nil-ring", "tick far-ring", "tick poll"])
    }

    @Test("settleAfterFetch polls inside the hour")
    func settlePins() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/ContentView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "func settleAfterFetch() async"))
        #expect(source[start.lowerBound...].prefix(6000).contains("pollInsideTheHour(source: .foreground)"))
    }

    /// A source scan, because the WebKit cookie store cannot be driven on the
    /// Mac. 2026-11-21: the persisted store alone (24-hour clock rule) read
    /// empty at night with a live session, so every poll was an unknown read.
    @Test("the poll's guard reads the live-merged cookies first, then the grades fetch's rule")
    func pollGuardShape() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/AppState+LastHourPoll.swift"), encoding: .utf8)
        let body = try #require(source.range(of: "func fetchPlannerWindowForPoll"))
        let text = String(source[body.lowerBound...].prefix(900))
        let cookies = try #require(text.range(of: "AutoSyncCoordinator.canvasCookies(forHost:"))
        let guardRange = try #require(text.range(of: "guard !cookies.isEmpty || hasCanvasCredentials"))
        #expect(cookies.lowerBound < guardRange.lowerBound)
    }
}
