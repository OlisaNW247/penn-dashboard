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

    /// Lets the main-actor tasks the sink enqueues run. Yielding is what
    /// gives them a turn; a nested `RunLoop.main.run(until:)` does not, which
    /// is why the first version of this test counted zero reloads on a view
    /// model that was reloading fine on the phone (2026-10-20). The sleep is
    /// a margin, not the mechanism.
    private func settle() async throws {
        for _ in 0..<32 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<32 { await Task.yield() }
    }

    @Test("three synchronous publishes cause exactly one reload, and a later publish still gets its own")
    func burstIsOneReload() async throws {
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        let vm = DashboardViewModel()
        vm.bind(to: state)

        // Let anything the new `AppState` publishes on its own settle, so the
        // count below is the burst's and not start-up noise.
        try await settle()
        let before = vm.publishedReloadCount

        state.objectWillChange.send()
        state.objectWillChange.send()
        state.objectWillChange.send()
        try await settle()
        #expect(vm.publishedReloadCount - before == 1)

        // The flag was cleared before the reload ran, so the next change is
        // not swallowed.
        state.objectWillChange.send()
        try await settle()
        #expect(vm.publishedReloadCount - before == 2)
    }
}
