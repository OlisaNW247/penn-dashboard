import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Notifications and Berserk alarms already scheduled for a Canvas assignment
/// kept going after the student disconnected Canvas, until they next opened
/// the dashboard, the screen that re-plans (hardening plan C9). The disconnect
/// now ends by running the dashboard's own re-plan, through a hook the
/// dashboard wires (`AppState.reminderReplanner`).
@MainActor
@Suite("Disconnect re-plans reminders", .serialized)
struct DisconnectReplansTests {
    /// Puts `UserDefaults.lhf` back after each test (see `LHFDefaultsGuard`).
    private let defaultsGuard = LHFDefaultsGuard()

    private static let course = "REPLAN 7101"

    private func ledgerWithCanvasWork(due: Date) throws -> AssignmentStore {
        let store = try AssignmentStore(inMemory: true)
        store.upsert([
            Assignment(source: .canvas, sourceID: "event-assignment-7101", kind: .assignment, course: Self.course,
                       title: "Problem Set 1", dueAt: due,
                       url: URL(string: "https://canvas.upenn.edu/courses/7101/assignments/7101")),
        ])
        return store
    }

    private func makeState(store: AssignmentStore) -> AppState {
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        return state
    }

    @Test("a disconnect runs the re-plan, and runs it after the Canvas work is already gone from the dashboard")
    func disconnectRunsTheReplan() async throws {
        let store = try ledgerWithCanvasWork(due: Date().addingTimeInterval(3 * 3_600))
        let state = makeState(store: store)
        #expect(!state.canvasItems.isEmpty)

        var runs = 0
        var canvasItemsWhenItRan: Int?
        var ledgerRowsWhenItRan: Int?
        state.reminderReplanner = {
            runs += 1
            canvasItemsWhenItRan = state.canvasItems.count
            ledgerRowsWhenItRan = store.rowCount()
        }

        state.disconnectCanvas()
        await state.awaitPendingReminderReplan()

        #expect(runs == 1)
        #expect(canvasItemsWhenItRan == 0, "it plans from what is left, not from before the disconnect")
        #expect(ledgerRowsWhenItRan == 0, "the unfinished row was purged first")
    }

    @Test("with no dashboard mounted there is no hook, and a disconnect still completes")
    func noHookNoCrash() async throws {
        let state = makeState(store: try ledgerWithCanvasWork(due: Date().addingTimeInterval(3_600)))
        #expect(state.reminderReplanner == nil)
        state.disconnectCanvas()
        await state.awaitPendingReminderReplan()
        #expect(state.canvasItems.isEmpty)
    }

    @Test("end to end: the notifications and the alarm scheduled for the Canvas work are gone once Canvas is disconnected")
    func pendingRemindersAreCancelled() async throws {
        let now = Date()
        let store = try ledgerWithCanvasWork(due: now.addingTimeInterval(3 * 3_600))
        let state = makeState(store: store)

        let suite = "lhf.tests.replan.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "notif.enabled")
        let scheduler = NotificationScheduler(defaults: defaults)
        let sink = FakeSink()
        let backend = FakeAlarmBackend(authorization: .authorized)
        scheduler.notificationSinkOverride = sink
        scheduler.authStatusOverride = .authorized
        scheduler.alarmBackendOverride = backend
        scheduler.fixtureDataProbe = { false }
        scheduler.setLoudAlertEnabled(true)

        // What the dashboard feeds the scheduler, from the state, as `vm.items` does.
        func dashItems() -> [DashItem] {
            state.canvasItems.map {
                DashItem(assignment: $0, dueOverride: nil, isCompleted: false, completedAt: nil)
            }
        }
        state.reminderReplanner = { await scheduler.reschedule(from: dashItems()) }

        // The student's reminders as they stood before the disconnect.
        await scheduler.reschedule(from: dashItems(), now: now)
        #expect(!sink.requests.isEmpty, "a reminder is pending for the Canvas work")
        #expect(!backend.store.scheduledIDs.isEmpty, "and an alarm is set")

        state.disconnectCanvas()
        await state.awaitPendingReminderReplan()

        #expect(sink.requests.isEmpty, "nothing is left pending for work that is gone")
        #expect(backend.store.scheduledIDs.isEmpty, "and no alarm will ring for it")
    }

    // MARK: Wiring

    @Test("ContentView wires the hook to a full re-plan from freshly rebuilt items; the disconnect calls it last")
    func wiring() throws {
        let content = try uiSource("ContentView.swift")
        guard !content.isEmpty else { return }
        let hook = try #require(content.range(of: "state.reminderReplanner = {"))
        let hookBody = String(content[hook.lowerBound...].prefix(400))
        #expect(hookBody.contains("[weak vm, weak scheduler]"))
        let reload = try #require(hookBody.range(of: "vm.reload(preservingEdits: true)"))
        let reschedule = try #require(hookBody.range(of: "await scheduler.reschedule(from: vm.items)"))
        #expect(reload.lowerBound < reschedule.lowerBound)
        // Not the debounced preference path: it returns at once on an empty list, which is exactly
        // the state a Canvas-only student is in after disconnecting.
        #expect(!hookBody.contains("rescheduleAfterPreferenceChange"))

        let appState = try uiSource("AppState.swift")
        let disconnect = try #require(appState.range(of: "func disconnectCanvas(keepingStudentWork: Bool = true) {"))
        let body = String(appState[disconnect.lowerBound...].prefix(16_000))
        let code = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        // The call, at statement indent, not the function's own declaration further down.
        let replan = try #require(code.range(of: "\n        replanRemindersAfterDisconnect()\n"))
        let rebuild = try #require(code.range(of: "\n        rebuildDashboardItems()\n"))
        #expect(rebuild.lowerBound < replan.lowerBound, "after the rebuild, so it plans from what is left")
        #expect(!code.contains("rescheduleAfterPreferenceChange"))
    }

    private func uiSource(_ filename: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI").appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }
}
