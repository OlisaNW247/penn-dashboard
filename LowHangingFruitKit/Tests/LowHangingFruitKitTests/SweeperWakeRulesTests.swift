import Foundation
import Testing
@testable import LowHangingFruitUI

@Suite("Sweeper wake rules")
struct SweeperWakeRulesTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func gates(
        backend: Bool = true, onboarded: Bool = true, penn: Bool = true, flag: Bool = true,
        reminders: Bool = true, sweeper: Bool = true, token: Bool = true,
        fixture: Bool = false, foreground: Bool = true
    ) -> Bool {
        SweeperWakeRules.gatesPass(
            hasBackend: backend, pastOnboarding: onboarded, isPenn: penn, flag: flag,
            remindersOn: reminders, sweeperOn: sweeper, hasToken: token, fixture: fixture,
            foreground: foreground)
    }

    @Test("every gate passes together, and each one alone stops a send")
    func gateTable() {
        #expect(gates())
        #expect(!gates(backend: false))
        #expect(!gates(onboarded: false))
        #expect(!gates(penn: false))
        #expect(!gates(flag: false))
        #expect(!gates(reminders: false))
        #expect(!gates(sweeper: false))
        #expect(!gates(token: false))
        #expect(!gates(fixture: true))
        #expect(!gates(foreground: false))
    }

    @Test("a first send, a changed plan, and a send after the throttle go; a repeat inside it does not")
    func throttle() {
        #expect(SweeperWakeRules.shouldSend(now: now, lastSent: nil, planHash: "a", lastHash: nil))
        #expect(SweeperWakeRules.shouldSend(now: now, lastSent: now.addingTimeInterval(-5), planHash: "b", lastHash: "a"))
        #expect(!SweeperWakeRules.shouldSend(now: now, lastSent: now.addingTimeInterval(-599), planHash: "a", lastHash: "a"))
        #expect(SweeperWakeRules.shouldSend(now: now, lastSent: now.addingTimeInterval(-600), planHash: "a", lastHash: "a"))
        // A clock that moved back does not freeze the pass.
        #expect(SweeperWakeRules.shouldSend(now: now, lastSent: now.addingTimeInterval(60), planHash: "a", lastHash: "a"))
        // No remembered hash (a new token clears it): send.
        #expect(SweeperWakeRules.shouldSend(now: now, lastSent: now.addingTimeInterval(-1), planHash: "a", lastHash: nil))
    }

    @Test("the server is told to forget only after a send, and only when a switch is off")
    func withdraw() {
        #expect(SweeperWakeRules.shouldWithdraw(everSent: true, installOK: true, remindersOn: false, sweeperOn: true))
        #expect(SweeperWakeRules.shouldWithdraw(everSent: true, installOK: true, remindersOn: true, sweeperOn: false))
        #expect(!SweeperWakeRules.shouldWithdraw(everSent: false, installOK: true, remindersOn: false, sweeperOn: false))
        #expect(!SweeperWakeRules.shouldWithdraw(everSent: true, installOK: true, remindersOn: true, sweeperOn: true))
        #expect(!SweeperWakeRules.shouldWithdraw(everSent: true, installOK: false, remindersOn: false, sweeperOn: false))
    }
}
