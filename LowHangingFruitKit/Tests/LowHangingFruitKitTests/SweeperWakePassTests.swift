import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Records what the pass sent. A class so the `@Sendable` seam can append.
final class WakeTransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _puts: [(token: String, environment: String, moments: [Date], plan: String)] = []
    private var _deletes = 0
    var failPuts = false
    var puts: [(token: String, environment: String, moments: [Date], plan: String)] { lock.withLock { _puts } }
    var deletes: Int { lock.withLock { _deletes } }

    var transport: SweeperWakeTransport {
        SweeperWakeTransport(
            put: { [self] token, environment, moments, plan in
                if failPuts { throw BackendError.transport }
                lock.withLock { _puts.append((token, environment, moments, plan)) }
                return moments.count
            },
            delete: { [self] in
                lock.withLock { _deletes += 1 }
                return 1
            })
    }
}

@MainActor
@Suite("Sweeper wake pass", .serialized)
struct SweeperWakePassTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let state: AppState
        let log: WakeTransportLog
        let defaults: UserDefaults
        let suite: String
    }

    private func rig(token: String? = "abcdef0123", available: Bool = true) throws -> Rig {
        let suite = "SweeperWakePassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true), dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.sweeperWakeDefaults = defaults
        state.sweeperCountsDefaults = defaults
        state.sweeperWakeAvailabilityForTesting = available
        let log = WakeTransportLog()
        state.sweeperWakeTransportForTesting = log.transport
        if let token { state.noteDeviceToken(token) }
        return Rig(state: state, log: log, defaults: defaults, suite: suite)
    }

    private func alarm(_ minutesAhead: Double) -> PlannedAlarm {
        let fire = now.addingTimeInterval(minutesAhead * 60)
        return PlannedAlarm(id: UUID(), assignmentID: "a\(minutesAhead)", fireDate: fire, title: "HW",
                            course: "CIS 1200", dueAt: fire.addingTimeInterval(600), link: nil)
    }

    private func run(_ r: Rig, _ plan: [PlannedAlarm], reminders: Bool = true, sweeper: Bool = true,
                     at time: Date? = nil, force: Bool = false) async {
        await r.state.sweeperWakePass(plan: plan, remindersOn: reminders, sweeperOn: sweeper,
                                      force: force, now: time ?? now)
    }

    @Test("with a switch off, or no token, nothing is sent")
    func gatesOff() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        await run(r, [alarm(120)], reminders: false)
        await run(r, [alarm(120)], sweeper: false)
        #expect(r.log.puts.isEmpty && r.log.deletes == 0)

        let noToken = try rig(token: nil)
        defer { noToken.defaults.removePersistentDomain(forName: noToken.suite) }
        await run(noToken, [alarm(120)])
        #expect(noToken.log.puts.isEmpty)

        let notPenn = try rig(available: false)
        defer { notPenn.defaults.removePersistentDomain(forName: notPenn.suite) }
        await run(notPenn, [alarm(120)])
        #expect(notPenn.log.puts.isEmpty)
    }

    @Test("a first plan is sent with the token, the environment, the moments and the hash")
    func firstSend() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        await run(r, [alarm(120)])
        let put = try #require(r.log.puts.first)
        #expect(put.token == "abcdef0123")
        #expect(put.environment == SweeperWakeClient.currentEnvironment)
        #expect(put.moments == SweeperWakePlan.moments(fromFireDates: [alarm(120).fireDate], now: now))
        #expect(put.plan == SweeperWakePlan.planHash(put.moments))
        #expect(r.defaults.bool(forKey: AppState.sweeperWakeEverSentKey))
        #expect(SweeperCounts.snapshot(defaults: r.defaults)[SweeperCounts.momentsSent] == 2)
    }

    @Test("an unchanged plan inside ten minutes is not re-sent; a changed one is; ten minutes on it is")
    func throttle() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        await run(r, [alarm(120)])
        await run(r, [alarm(120)], at: now.addingTimeInterval(120))
        #expect(r.log.puts.count == 1)
        await run(r, [alarm(120), alarm(180)], at: now.addingTimeInterval(180))
        #expect(r.log.puts.count == 2)
        await run(r, [alarm(120), alarm(180)], at: now.addingTimeInterval(180 + 599))
        #expect(r.log.puts.count == 2)
        await run(r, [alarm(120), alarm(180)], at: now.addingTimeInterval(180 + 600))
        #expect(r.log.puts.count == 3)
    }

    @Test("a new device token sends again at once")
    func tokenChangeForcesSend() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        await run(r, [alarm(120)])
        r.state.noteDeviceToken("ABCDEF9999")
        await run(r, [alarm(120)], at: now.addingTimeInterval(30))
        #expect(r.log.puts.count == 2)
        #expect(r.log.puts.last?.token == "abcdef9999", "lowercased")
        // Not hex: ignored, nothing changes.
        r.state.noteDeviceToken("not hex!")
        await run(r, [alarm(120)], at: now.addingTimeInterval(60))
        #expect(r.log.puts.count == 2)
    }

    @Test("an empty plan is still sent, so the server's row empties")
    func emptyPlan() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        await run(r, [alarm(120)])
        await run(r, [], at: now.addingTimeInterval(60))
        #expect(r.log.puts.count == 2)
        #expect(r.log.puts.last?.moments.isEmpty == true)
        #expect(r.log.puts.last?.plan == SweeperWakePlan.planHash([]))
    }

    @Test("a failed put is silent, counted, and retried at the next pass")
    func failure() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        r.log.failPuts = true
        await run(r, [alarm(120)])
        #expect(!r.defaults.bool(forKey: AppState.sweeperWakeEverSentKey))
        #expect(SweeperCounts.snapshot(defaults: r.defaults)[SweeperCounts.putFailed] == 1)
        r.log.failPuts = false
        await run(r, [alarm(120)], at: now.addingTimeInterval(5))
        #expect(r.log.puts.count == 1)
    }

    @Test("fixture data never sends, and neither does a background context")
    func fixtureAndBackground() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        r.state.forceFixtureDataForTesting(true)
        await run(r, [alarm(120)])
        #expect(r.log.puts.isEmpty)
        r.state.forceFixtureDataForTesting(false)
        r.state.renewalContext = .background
        await run(r, [alarm(120)])
        #expect(r.log.puts.isEmpty)
        r.state.renewalContext = .foreground
        await run(r, [alarm(120)])
        #expect(r.log.puts.count == 1)
    }

    @Test("switching reminders or the Sweeper off after a send asks the server to forget")
    func withdrawOnSwitch() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        await run(r, [alarm(120)])
        #expect(r.defaults.bool(forKey: AppState.sweeperWakeEverSentKey))
        await run(r, [], reminders: false, at: now.addingTimeInterval(60))
        #expect(r.log.deletes == 1)
        #expect(!r.defaults.bool(forKey: AppState.sweeperWakeEverSentKey))
        // Already forgotten: a second pass with the switch still off asks nothing.
        await run(r, [], reminders: false, at: now.addingTimeInterval(120))
        #expect(r.log.deletes == 1)
        #expect(r.log.puts.count == 1)
    }

    @Test("the scheduler's switch closures and the disconnect path delete only after a send")
    func explicitWithdraw() async throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        await r.state.withdrawSweeperWakeIfSent()
        #expect(r.log.deletes == 0, "a phone that never sent makes no request")
        await run(r, [alarm(120)])
        await r.state.withdrawSweeperWakeIfSent()
        #expect(r.log.deletes == 1)
        #expect(!r.defaults.bool(forKey: AppState.sweeperWakeEverSentKey))
        // The memory is cleared, so the next pass sends the plan again.
        await run(r, [alarm(120)], at: now.addingTimeInterval(30))
        #expect(r.log.puts.count == 2)
    }

    @Test("the scheduler tells the wake when reminders or the Sweeper go off")
    func schedulerHook() {
        let suite = "SweeperWakePassTests.sched.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = NotificationScheduler(defaults: defaults)
        scheduler.notificationSinkOverride = FakeSink()
        scheduler.alarmBackendOverride = FakeAlarmBackend(authorization: .authorized)
        var told = 0
        scheduler.onSweeperWakeInputOff = { told += 1 }
        scheduler.setLoudAlertEnabled(true)
        #expect(told == 0)
        scheduler.setLoudAlertEnabled(false)
        #expect(told == 1)
        // `setEnabled(false)` reaches the real notification center, which
        // traps in an unbundled test process, so its half is a source pin.
        let code = try? HardeningSourceScan.uiCode("NotificationScheduler.swift")
        let body = try? HardeningSourceScan.body(ofFunctionDeclaredWith: "func setEnabled(_ on: Bool) async", in: code ?? "")
        let offBranch = body?.range(of: "cancelAlarms()")
        let hook = body?.range(of: "onSweeperWakeInputOff?()")
        #expect(offBranch != nil && hook != nil && offBranch!.lowerBound < hook!.lowerBound)
    }

    @Test("registration failing is a count and nothing else")
    func registrationFailure() throws {
        let r = try rig()
        defer { r.defaults.removePersistentDomain(forName: r.suite) }
        r.state.noteDeviceTokenRegistrationFailed()
        #expect(SweeperCounts.snapshot(defaults: r.defaults)[SweeperCounts.registerFailed] == 1)
    }

    @Test("the pass is never called from a background wake, and the registrar never from one either")
    func notFromTheBackground() throws {
        let background = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        #expect(!background.contains("sweeperWakePass"))
        #expect(!background.contains("registerForRemoteNotifications"))
        #expect(!background.contains("SweeperWakeRegistrar"))
        let content = try HardeningSourceScan.uiCode("ContentView.swift")
        let settle = try HardeningSourceScan.body(ofFunctionDeclaredWith: "private func settleAfterFetch() async", in: content)
        let order = ["await scheduler.reschedule(from: vm.items)", "SweeperWakeRegistrar.registerIfNeeded(", "await state.sweeperWakePass("]
        let found = try HardeningSourceScan.positions(of: order, in: settle)
        #expect(zip(found, found.dropFirst()).allSatisfy(<))
    }

    @Test("the flag exists and gates the pass's first branch")
    func flag() throws {
        let code = try HardeningSourceScan.uiCode("AppState+SweeperWake.swift")
        #expect(code.contains("guard FeatureFlags.sweeperWake else"))
        #expect(code.contains("!isSweeperWakeRunning"))
        let disconnect = try HardeningSourceScan.body(
            ofFunctionDeclaredWith: "func disconnectCanvas(keepingStudentWork: Bool = true)",
            in: try HardeningSourceScan.uiCode("AppState.swift"))
        #expect(disconnect.contains("withdrawSweeperWakeIfSent()"))
    }
}
