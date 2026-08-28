import XCTest
@testable import LowHangingFruitUI
import LowHangingFruitKit

/// Covers the shipped "Explore with sample data" demo. Its whole promise is that
/// it shows a full dashboard while touching nothing: no persisted state, no
/// writes back to the real store, and no way for a background sync to erase it.
@MainActor
final class DemoModeTests: XCTestCase {

    private static let onboardingKey = "hasCompletedOnboarding"

    /// AppState reads the onboarding flag from UserDefaults at init, so tests
    /// that assert on it clear it first rather than inheriting another test's.
    private func clearOnboardingFlag() {
        UserDefaults.standard.removeObject(forKey: Self.onboardingKey)
    }

    private func demoState() -> AppState {
        clearOnboardingFlag()
        let state = AppState()
        state.enterDemoMode()
        return state
    }

    private func demoViewModel(boundTo state: AppState) -> DashboardViewModel {
        let vm = DashboardViewModel()
        vm.loadSampleData()
        vm.bind(to: state)
        return vm
    }

    func testDemoOpensTheDashboardWithoutPersistingOnboarding() {
        clearOnboardingFlag()
        let state = AppState()
        XCTAssertTrue(state.needsOnboarding)

        state.enterDemoMode()

        XCTAssertTrue(state.isDemoMode)
        XCTAssertFalse(state.needsOnboarding, "the demo has to open the dashboard")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.onboardingKey),
                       "in-memory only — the next launch goes back to the connect screen")
        XCTAssertFalse(state.isCanvasConnected, "the demo never claims a Canvas connection")
    }

    func testLeavingTheDemoReturnsToOnboarding() {
        let state = demoState()
        state.restartOnboarding()
        XCTAssertFalse(state.isDemoMode)
        XCTAssertTrue(state.needsOnboarding)
    }

    func testConnectingForRealClearsTheDemo() {
        let state = demoState()
        state.completeOnboarding()
        XCTAssertFalse(state.isDemoMode)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.onboardingKey))
        clearOnboardingFlag()
    }

    func testSampleDataFillsTheDashboard() {
        let vm = demoViewModel(boundTo: demoState())
        let now = Date()

        XCTAssertFalse(vm.thisWeekSections(now: now).isEmpty, "This week should have sections")
        XCTAssertFalse(vm.doneSections(now: now).isEmpty, "Done should have sections")
        XCTAssertGreaterThanOrEqual(vm.allSections(now: now).count,
                                    vm.thisWeekSections(now: now).count)
        XCTAssertGreaterThan(vm.weeklyProgress(now: now).total, 0, "the ring needs a total")
        XCTAssertTrue(vm.thisWeekSections(now: now).contains { $0.id == "overdue" },
                      "the demo should show the overdue state, not just a tidy list")
    }

    func testCompletingInTheDemoStaysOutOfTheRealStore() {
        let state = demoState()
        let vm = demoViewModel(boundTo: state)
        let before = state.completedAssignmentIDs

        guard let item = vm.items.first(where: { !$0.isCompleted }) else {
            return XCTFail("sample data should contain active items")
        }
        vm.complete(item)

        XCTAssertEqual(vm.items.first { $0.id == item.id }?.isCompleted, true)
        XCTAssertEqual(state.completedAssignmentIDs, before,
                       "a demo tap must not persist a completion")
    }

    func testAddingInTheDemoStaysInTheViewModel() {
        let state = demoState()
        let vm = demoViewModel(boundTo: state)
        let itemsBefore = vm.items.count
        let manualBefore = state.manualAssignments.count

        vm.addSampleItems([Assignment(source: .manual, sourceID: "demo-add", kind: .assignment,
                                      course: "CIS 1210", title: "Demo item",
                                      dueAt: Date().addingTimeInterval(3600), url: nil)])

        XCTAssertEqual(vm.items.count, itemsBefore + 1)
        XCTAssertEqual(state.manualAssignments.count, manualBefore,
                       "the demo's + flow must not write a real manual assignment")
    }

    /// The dashboard auto-refreshes every 5 minutes; before the demo shipped,
    /// that reload would have replaced the fixtures with an empty real store.
    func testARefreshCannotWipeTheDemoOut() {
        let state = demoState()
        let vm = demoViewModel(boundTo: state)
        let before = vm.items.count

        vm.reload(preservingEdits: true)

        XCTAssertEqual(vm.items.count, before)
    }
}
