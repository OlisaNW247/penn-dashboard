import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Serialized and restoring: the opt-in flag lives in the shared `UserDefaults.lhf`
/// domain (the shared-defaults trap in CLAUDE.md).
@MainActor
@Suite("Agent snapshot pass", .serialized)
struct AgentSnapshotPassTests {
    private let key = SharedDefaults.agentConnectionEnabledKey

    private func makeState() throws -> AppState {
        let suite = "AgentSnapshotPassTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true), dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        return state
    }

    @Test("with the opt-in off the pass sends nothing and does not even start")
    func offSendsNothing() async throws {
        let backup = UserDefaults.lhf.object(forKey: key)
        defer { if let backup { UserDefaults.lhf.set(backup, forKey: key) } else { UserDefaults.lhf.removeObject(forKey: key) } }
        let state = try makeState()
        state.agentConnectionEnabled = false
        await state.agentSnapshotPass(force: true)
        #expect(state.lastAgentSnapshotAt == nil)
        #expect(!state.isAgentSnapshotRunning)
    }

    @Test("the switch writes the flag to UserDefaults.lhf and back")
    func flagRoundTrip() async throws {
        let backup = UserDefaults.lhf.object(forKey: key)
        defer { if let backup { UserDefaults.lhf.set(backup, forKey: key) } else { UserDefaults.lhf.removeObject(forKey: key) } }
        #expect(key == "agentConnectionEnabledV1")
        let state = try makeState()
        await state.setAgentConnectionEnabled(true)
        #expect(UserDefaults.lhf.bool(forKey: key))
        #expect(state.agentConnectionEnabled)
        await state.setAgentConnectionEnabled(false)
        #expect(!UserDefaults.lhf.bool(forKey: key))
        #expect(!state.agentConnectionEnabled)
        #expect(!state.hasAgentConnections)
    }

    @Test("pendingAgentLink(from:) follows the availability rules")
    func linkAvailability() throws {
        let url = try #require(URL(string: "smooth://link?c=abcdef0123456789abcdef"))
        let state = try makeState()
        #expect(state.pendingAgentLink(from: url) == nil, "no backend in tests")

        let fixture = try makeState()
        fixture.forceFixtureDataForTesting(true)
        #expect(fixture.pendingAgentLink(from: url) == nil)

        // The gate is exactly the flag plus the laptop-sync availability.
        #expect(state.canUseAgentConnection == (FeatureFlags.agentConnection && state.canSyncWithLaptop))
        if state.canUseAgentConnection {
            #expect(state.pendingAgentLink(from: url) != nil)
        }
    }
}
