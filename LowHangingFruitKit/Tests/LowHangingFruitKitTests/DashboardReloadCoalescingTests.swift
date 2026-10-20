import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `DashboardViewModel` reloads off `AppState`'s publishes. A rebuild assigns
/// around eight `@Published` properties, and each used to cost a full reload
/// (every `DashItem` rebuilt, `items` republished, the dashboard's `body`
/// re-evaluated). A burst is now one reload.
@MainActor
@Suite("Dashboard view model: publishes are coalesced into one reload", .serialized)
struct DashboardReloadCoalescingTests {

    /// Lets the main run loop deliver what is waiting (the Combine sink is
    /// `receive(on: RunLoop.main)` and the reload is a main-actor task), which
    /// a test that never suspends would otherwise starve.
    private func pumpMainRunLoop(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test("three synchronous publishes cause exactly one reload, and a later publish still gets its own")
    func burstIsOneReload() throws {
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        let vm = DashboardViewModel()
        vm.bind(to: state)

        // Let anything the new `AppState` publishes on its own settle, so the
        // count below is the burst's and not start-up noise.
        pumpMainRunLoop(for: 0.3)
        let before = vm.publishedReloadCount

        state.objectWillChange.send()
        state.objectWillChange.send()
        state.objectWillChange.send()
        pumpMainRunLoop(for: 0.3)
        #expect(vm.publishedReloadCount - before == 1)

        // The flag was cleared before the reload ran, so the next change is
        // not swallowed.
        state.objectWillChange.send()
        pumpMainRunLoop(for: 0.3)
        #expect(vm.publishedReloadCount - before == 2)
    }
}
