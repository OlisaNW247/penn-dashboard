import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Sweeper wake plan")
struct SweeperWakePlanTests {
    /// 2027-01-15 12:00:00 UTC, a whole minute.
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fire(minutes: Double, seconds: Double = 0) -> Date {
        now.addingTimeInterval(minutes * 60 + seconds)
    }

    @Test("one alarm makes a pair: fire minus 15 and minus 3 minutes")
    func pair() {
        let moments = SweeperWakePlan.moments(fromFireDates: [fire(minutes: 120)], now: now)
        #expect(moments == [fire(minutes: 105), fire(minutes: 117)])
    }

    @Test("two alarms in the same minute make one pair")
    func sameMinute() {
        let moments = SweeperWakePlan.moments(
            fromFireDates: [fire(minutes: 120, seconds: 5), fire(minutes: 120, seconds: 40)], now: now)
        #expect(moments.count == 2)
    }

    @Test("moments are cut at 48 hours")
    func horizon() {
        let inside = fire(minutes: 48 * 60 + 15)   // fire - 15 = exactly 48 h
        let outside = fire(minutes: 48 * 60 + 16)
        let moments = SweeperWakePlan.moments(fromFireDates: [inside, outside], now: now)
        #expect(moments.contains(now.addingTimeInterval(48 * 3600)))
        #expect(moments.allSatisfy { $0 <= now.addingTimeInterval(48 * 3600) })
        #expect(!moments.contains(now.addingTimeInterval(48 * 3600 + 60)))
    }

    @Test("at most 24 are kept and they are the nearest")
    func cap() {
        let fires = (1...20).map { fire(minutes: Double(30 * $0)) }   // 40 candidate moments
        let moments = SweeperWakePlan.moments(fromFireDates: fires, now: now)
        #expect(moments.count == 24)
        #expect(moments == moments.sorted())
        let all = SweeperWakePlan.moments(fromFireDates: fires, now: now, cap: 100)
        #expect(Array(all.prefix(24)) == moments)
    }

    @Test("past moments are dropped, and so is one exactly now")
    func past() {
        // Fires in 10 minutes: the -15 is past, the -3 is 7 minutes away.
        let one = SweeperWakePlan.moments(fromFireDates: [fire(minutes: 10)], now: now)
        #expect(one == [fire(minutes: 7)])
        let atNow = SweeperWakePlan.moments(fromFireDates: [fire(minutes: 3)], now: now)
        #expect(atNow.isEmpty)
        #expect(SweeperWakePlan.moments(fromFireDates: [fire(minutes: -60)], now: now).isEmpty)
    }

    @Test("moments are truncated down to the minute, in UTC")
    func truncation() {
        let moments = SweeperWakePlan.moments(fromFireDates: [fire(minutes: 120, seconds: 59.9)], now: now)
        #expect(moments == [fire(minutes: 105), fire(minutes: 117)])
        for moment in moments {
            #expect(Int64(moment.timeIntervalSince1970) % 60 == 0)
        }
    }

    @Test("the output holds dates and the wire form is whole-minute ISO UTC")
    func wireForm() {
        let moments = SweeperWakePlan.moments(fromFireDates: [fire(minutes: 120)], now: now)
        let wire = moments.map(SweeperWakePlan.iso)
        for text in wire {
            #expect(text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$"#, options: .regularExpression) != nil)
        }
        #expect(SweeperWakePlan.iso(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
    }

    @Test("the hash is 16 lowercase hex, stable, order-free and changes with one moment")
    func hash() {
        let a = [fire(minutes: 105), fire(minutes: 117)]
        let h = SweeperWakePlan.planHash(a)
        #expect(h.count == 16)
        #expect(h.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil)
        #expect(h == SweeperWakePlan.planHash(a))
        #expect(h == SweeperWakePlan.planHash(a.reversed()))
        #expect(h != SweeperWakePlan.planHash([fire(minutes: 105), fire(minutes: 118)]))
        #expect(h != SweeperWakePlan.planHash([fire(minutes: 105)]))
    }

    @Test("the empty plan hashes the empty string (sha256, first 16 hex)")
    func emptyHash() {
        #expect(SweeperWakePlan.planHash([]) == "e3b0c44298fc1c14")
    }
}
