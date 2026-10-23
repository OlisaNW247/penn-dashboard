import Foundation
import Testing
@testable import LowHangingFruitKit

/// The sync change times and device id live in `UserDefaults.lhf`, never on the
/// ledger (a schema change makes an older build lose the ledger). Every test
/// uses its own throwaway suite; none touches `.lhf`.
@Suite struct SyncChangeLogTests {
    private func makeLog() -> (SyncChangeLog, UserDefaults, String) {
        let name = "SyncChangeLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (SyncChangeLog(defaults: defaults), defaults, name)
    }

    private let t0 = Date(timeIntervalSince1970: 1_792_670_400)

    @Test func recordsAndReadsATime() {
        let (log, _, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        #expect(log.time(kind: .completion, id: "canvas:1") == nil)
        log.record(kind: .completion, id: "canvas:1", at: t0)
        #expect(log.time(kind: .completion, id: "canvas:1") == t0)
    }

    @Test func aNewerChangeReplacesTheOlder() {
        let (log, _, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        log.record(kind: .dueEdit, id: "canvas:1", at: t0)
        log.record(kind: .dueEdit, id: "canvas:1", at: t0.addingTimeInterval(60))
        #expect(log.time(kind: .dueEdit, id: "canvas:1") == t0.addingTimeInterval(60))
    }

    @Test func kindsAreSeparateNamespaces() {
        let (log, _, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        log.record(kind: .completion, id: "x", at: t0)
        #expect(log.time(kind: .dueEdit, id: "x") == nil)
        #expect(log.time(kind: .manual, id: "x") == nil)
    }

    @Test func roundsToTheMillisecondTheWireCarries() {
        let (log, _, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        log.record(kind: .completion, id: "a", at: Date(timeIntervalSince1970: 1_792_670_400.0004))
        log.record(kind: .completion, id: "b", at: Date(timeIntervalSince1970: 1_792_670_400.0006))
        #expect(log.time(kind: .completion, id: "a") == t0)
        #expect(log.time(kind: .completion, id: "b") == Date(timeIntervalSince1970: 1_792_670_400.001))
    }

    @Test func idsWithColonsSurviveAndTimesListsOnlyOneKind() {
        let (log, _, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        log.record(kind: .completion, id: "canvas:user_1:2", at: t0)
        log.record(kind: .dueEdit, id: "gradescope:9", at: t0)
        #expect(log.times(kind: .completion) == ["canvas:user_1:2": t0])
        #expect(log.times(kind: .dueEdit) == ["gradescope:9": t0])
        #expect(log.times(kind: .manual).isEmpty)
    }

    @Test func persistsAcrossInstancesAndClearForgetsOnlyTheTimes() {
        let (log, defaults, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        log.record(kind: .manual, id: "m", at: t0)
        let id = log.deviceID()
        let again = SyncChangeLog(defaults: defaults)
        #expect(again.time(kind: .manual, id: "m") == t0)
        again.clear()
        #expect(again.time(kind: .manual, id: "m") == nil)
        #expect(again.deviceID() == id)
    }

    @Test func aDamagedEntryCostsOnlyItself() {
        let (log, defaults, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(["completion:good": t0, "completion:bad": "nope"] as [String: Any], forKey: SyncChangeLog.changeTimesKey)
        #expect(log.time(kind: .completion, id: "good") == t0)
        #expect(log.time(kind: .completion, id: "bad") == nil)
    }

    @Test func usesTheDocumentedKeys() {
        #expect(SyncChangeLog.changeTimesKey == "syncChangeTimesV1")
        #expect(SyncChangeLog.deviceIDKey == "syncDeviceIDV1")
    }

    // MARK: device id

    @Test func deviceIDIsMadeOnceAndMatchesTheServersPattern() {
        let (log, defaults, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let first = log.deviceID()
        #expect(SyncChangeLog.isValidDeviceID(first))
        #expect(log.deviceID() == first)
        #expect(SyncChangeLog(defaults: defaults).deviceID() == first)
    }

    @Test func aStoredIDThatTheServerWouldRefuseIsReplaced() {
        let (log, defaults, name) = makeLog()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set("bad id!", forKey: SyncChangeLog.deviceIDKey)
        let id = log.deviceID()
        #expect(id != "bad id!")
        #expect(SyncChangeLog.isValidDeviceID(id))
        #expect(log.deviceID() == id)
    }

    @Test func deviceIDPattern() {
        #expect(SyncChangeLog.isValidDeviceID("abcdefgh"))
        #expect(SyncChangeLog.isValidDeviceID("A_b-9" + String(repeating: "x", count: 3)))
        #expect(SyncChangeLog.isValidDeviceID(String(repeating: "a", count: 64)))
        #expect(!SyncChangeLog.isValidDeviceID("abcdefg"))
        #expect(!SyncChangeLog.isValidDeviceID(String(repeating: "a", count: 65)))
        #expect(!SyncChangeLog.isValidDeviceID("abcdefg."))
        #expect(!SyncChangeLog.isValidDeviceID("abcdefgé"))
        #expect(!SyncChangeLog.isValidDeviceID(""))
    }
}
