import Foundation
import Testing

/// `LHFBackgroundRefresh` is iOS-only (`#if canImport(BackgroundTasks) &&
/// os(iOS)`), so the macOS test run never compiles it. What a wake must do
/// after its syncs is pinned here at the source level; what the re-plan it
/// calls does is pinned by running the scheduler against fakes in
/// `BerserkAlarmDeliveryTests` ("A re-plan without a prompt ...").
///
/// The wake used to sync, post "Turned in" and stop, so work handed in while
/// the app was closed kept its alarm (docs/HARDENING_PLAN_2026-10-25.md, C1).
/// The wrong fix is to call `reschedule` there: it can put the AlarmKit
/// permission question to a student who is not looking at the phone.
@Suite("Background wake re-plan")
struct BackgroundWakeReplanTests {

    @Test("the wake re-plans through the no-prompt path and never through reschedule or a permission request")
    func wakeNeverCanPrompt() throws {
        let code = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        #expect(code.contains("rescheduleWithoutPrompting(from:"))
        #expect(!code.contains(".reschedule(from"), "reschedule can prompt for alarm permission")
        #expect(!code.contains("requestAuthorization"))
        #expect(!code.contains("setEnabled"), "setEnabled asks the notification center for permission")
    }

    @Test("the re-plan runs after the three syncs, before the renewal wait, and before the early return for no notices")
    func replanOrder() throws {
        let code = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        let run = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func run() async", in: code)
        let order = [
            "await state.syncIfConfigured()",
            "await AutoSyncCoordinator.syncConnectedServices(state: state)",
            "await AutoSyncCoordinator.refreshCanvasGrades(state: state)",
            "await replan(scheduler: scheduler, state: state)",
            "await state.awaitPendingSilentRenewal()",
            "guard !notices.isEmpty else { return }",
            "await scheduler.postTurnedInNotifications(notices)",
        ]
        let found = try HardeningSourceScan.positions(of: order, in: run)
        #expect(zip(found, found.dropFirst()).allSatisfy(<),
                "a wake that returns early for lack of notices must not skip the re-plan, and the renewal wait must not starve it")
    }

    @Test("the re-plan builds its items the way the dashboard does and honours the reminders switch")
    func replanBody() throws {
        let code = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        let replan = try HardeningSourceScan.body(
            ofFunctionDeclaredWith: "func replan(scheduler: NotificationScheduler, state: AppState) async", in: code)
        let order = [
            "guard scheduler.isEnabled else { return }",
            "dashboard.bind(to: state)",
            "dashboard.reload(preservingEdits: true)",
            "await scheduler.rescheduleWithoutPrompting(from: dashboard.items)",
        ]
        let found = try HardeningSourceScan.positions(of: order, in: replan)
        #expect(zip(found, found.dropFirst()).allSatisfy(<))
    }
}
