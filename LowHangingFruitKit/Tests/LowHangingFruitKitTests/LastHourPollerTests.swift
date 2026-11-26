import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `LastHourPoller.tick`, driven with a fixed clock and a fake read: no timer,
/// no network, no sleep.
@MainActor
@Suite("Last-hour poller")
struct LastHourPollerTests {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func make() -> (LastHourPoller, Clock, UserDefaults, String) {
        let clock = Clock()
        let suite = "LastHourPollerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (LastHourPoller(clock: { clock.now }, countsDefaults: defaults), clock, defaults, suite)
    }

    @Test("Outside the hour nothing is fetched")
    func outside() async {
        let (poller, clock, _, suite) = make()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var fetches = 0
        for ring in [nil, clock.now.addingTimeInterval(3601), clock.now.addingTimeInterval(-10)] as [Date?] {
            let d = await poller.tick(nextRing: ring) { _ in fetches += 1; return nil }
            #expect(d == .idle)
        }
        #expect(fetches == 0)
    }

    @Test("Inside the hour, one fetch per minute")
    func oncePerMinute() async {
        let (poller, clock, _, suite) = make()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ring = clock.now.addingTimeInterval(1800)
        var fetches = 0
        let ok: @MainActor (Date?) async -> PlannerWindowResult? = { _ in
            fetches += 1
            return PlannerWindowResult(items: [], completed: true, remaining: 700)
        }
        #expect(await poller.tick(nextRing: ring, poll: ok) == .poll)
        clock.now.addTimeInterval(30)
        if case .wait = await poller.tick(nextRing: ring, poll: ok) {} else { Issue.record("expected a wait") }
        #expect(fetches == 1)
        clock.now.addTimeInterval(31)
        #expect(await poller.tick(nextRing: ring, poll: ok) == .poll)
        #expect(fetches == 2)
    }

    @Test("A rate limit or a low bucket backs off for five minutes and is counted")
    func backOff() async {
        for answer in [
            PlannerWindowResult(items: [], completed: false, rateLimited: true),
            PlannerWindowResult(items: [], completed: true, remaining: 99),
        ] {
            let (poller, clock, defaults, suite) = make()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let ring = clock.now.addingTimeInterval(3000)
            var fetches = 0
            let poll: @MainActor (Date?) async -> PlannerWindowResult? = { _ in fetches += 1; return answer }
            await poller.tick(nextRing: ring, poll: poll)
            #expect(SweeperCounts.snapshot(defaults: defaults)[SweeperCounts.pollsBackedOff] == 1)

            clock.now.addTimeInterval(200)
            if case .wait = await poller.tick(nextRing: ring, poll: poll) {} else { Issue.record("expected a wait") }
            #expect(fetches == 1, "no read while backed off")

            clock.now.addTimeInterval(101)
            #expect(await poller.tick(nextRing: ring, poll: poll) == .poll)
            #expect(fetches == 2)
        }
    }

    @Test("A healthy bucket does not back off; no session backs off without a count")
    func healthyAndNoSession() async {
        let (poller, clock, defaults, suite) = make()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let ring = clock.now.addingTimeInterval(3000)
        await poller.tick(nextRing: ring) { _ in PlannerWindowResult(items: [], completed: true, remaining: 100) }
        #expect(poller.backedOffUntil == nil)
        clock.now.addTimeInterval(61)
        await poller.tick(nextRing: ring) { _ in nil }
        #expect(poller.backedOffUntil != nil)
        #expect(SweeperCounts.snapshot(defaults: defaults)[SweeperCounts.pollsBackedOff] == nil)
    }

    @Test("start is idempotent and stop ends the loop")
    func startStop() async {
        let (poller, _, _, suite) = make()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        poller.start(nextRing: { nil }, poll: { _ in nil })
        poller.start(nextRing: { nil }, poll: { _ in nil })
        #expect(poller.isRunning)
        poller.stop()
        #expect(!poller.isRunning)
    }
}
