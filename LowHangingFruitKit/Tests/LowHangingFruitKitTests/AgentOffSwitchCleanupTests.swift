import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Agent off-switch cleanup (R-I3)")
struct AgentOffSwitchCleanupTests {
    private func run(flagOn: Bool = false, optedIn: Bool = true, done: Bool = false,
                     backend: Bool = true, fixture: Bool = false) -> Bool {
        AgentPassRules.shouldRunOffSwitchCleanup(flagOn: flagOn, optedIn: optedIn, alreadyDone: done,
                                                 hasBackend: backend, isFixtureData: fixture)
    }

    @Test("runs only when the flag is off, the opt-in is on, and it has not run")
    func table() {
        #expect(run())
        #expect(!run(flagOn: true))
        #expect(!run(optedIn: false))
        #expect(!run(done: true))
        #expect(!run(backend: false))
        #expect(!run(fixture: true))
    }

    @Test("the done key")
    func wiring() {
        #expect(AppState.agentOffCleanupDoneKey == "agentOffSwitchCleanupDoneV1")
    }
}
