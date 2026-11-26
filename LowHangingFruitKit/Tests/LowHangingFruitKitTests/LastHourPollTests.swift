import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Last-hour poll cadence")
struct LastHourPollTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func t(_ s: TimeInterval) -> Date { now.addingTimeInterval(s) }

    @Test("Idle with no ring, a ring beyond the hour, or one already past")
    func idle() {
        #expect(LastHourPoll.cadence(now: now, nextRing: nil, lastPoll: nil, backedOffUntil: nil) == .idle)
        #expect(LastHourPoll.cadence(now: now, nextRing: t(3601), lastPoll: nil, backedOffUntil: nil) == .idle)
        #expect(LastHourPoll.cadence(now: now, nextRing: t(-30), lastPoll: nil, backedOffUntil: nil) == .idle)
        #expect(LastHourPoll.cadence(now: now, nextRing: now, lastPoll: nil, backedOffUntil: nil) == .idle)
    }

    @Test("Polls at once inside the hour with no earlier poll")
    func firstPoll() {
        #expect(LastHourPoll.cadence(now: now, nextRing: t(3600), lastPoll: nil, backedOffUntil: nil) == .poll)
        #expect(LastHourPoll.cadence(now: now, nextRing: t(5), lastPoll: nil, backedOffUntil: nil) == .poll)
    }

    @Test("Waits under a minute since the last poll, polls after it")
    func interval() {
        #expect(LastHourPoll.cadence(now: now, nextRing: t(600), lastPoll: t(-59), backedOffUntil: nil) == .wait(until: t(1)))
        #expect(LastHourPoll.cadence(now: now, nextRing: t(600), lastPoll: t(-60), backedOffUntil: nil) == .poll)
        #expect(LastHourPoll.cadence(now: now, nextRing: t(600), lastPoll: t(-600), backedOffUntil: nil) == .poll)
    }

    @Test("A back-off is honoured, and expires")
    func backOff() {
        #expect(LastHourPoll.cadence(now: now, nextRing: t(600), lastPoll: nil, backedOffUntil: t(120)) == .wait(until: t(120)))
        #expect(LastHourPoll.cadence(now: now, nextRing: t(600), lastPoll: nil, backedOffUntil: t(0)) == .poll)
        #expect(LastHourPoll.cadence(now: now, nextRing: t(600), lastPoll: nil, backedOffUntil: t(-5)) == .poll)
    }

    @Test("The window is an hour back to two hours ahead")
    func window() {
        let w = LastHourPoll.window(now: now)
        #expect(w.start == t(-3600))
        #expect(w.end == t(7200))
    }
}
