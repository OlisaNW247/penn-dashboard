import Foundation
import Testing
@testable import LowHangingFruitKit

/// Building the phone's own snapshot from plain facts, including what a record
/// with no recorded change time must say (see `SyncSnapshotBuilder`).
@Suite struct SyncSnapshotBuilderTests {
    static func t(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_792_670_400 + Double(minute) * 60)
    }

    static func build(completions: [SyncSnapshotBuilder.CompletionFact] = [],
                      dueEdits: [SyncSnapshotBuilder.DueEditFact] = [],
                      manual: [SyncSnapshotBuilder.ManualFact] = [],
                      workList: [SyncSnapshot.WorkItem] = []) -> SyncSnapshot {
        SyncSnapshotBuilder.build(deviceID: "phone-device-1", now: t(100), completions: completions,
                                  dueEdits: dueEdits, manual: manual, workList: workList)
    }

    // MARK: completions

    @Test func aRecordedChangeTimeIsUsed() {
        let s = Self.build(completions: [.init(id: "canvas:1", done: true,
                                               completedAt: Self.t(1), changedAt: Self.t(5))])
        #expect(s.completions["canvas:1"] == .init(done: true, at: Self.t(5)))
    }

    @Test func withoutARecordedTimeACompletionUsesItsCompletedAt() {
        let s = Self.build(completions: [.init(id: "canvas:1", done: true, completedAt: Self.t(3))])
        #expect(s.completions["canvas:1"]?.at == Self.t(3))
    }

    @Test func withNeitherTimeACompletionIsTheEpochNotNow() {
        let s = Self.build(completions: [.init(id: "canvas:1", done: true)])
        #expect(s.completions["canvas:1"]?.at == Date(timeIntervalSince1970: 0))
        #expect(s.completions["canvas:1"]?.at != s.writtenAt)
    }

    @Test func anUntickedFactNeverBorrowsACompletedAt() {
        let s = Self.build(completions: [.init(id: "a", done: false, completedAt: Self.t(3))])
        #expect(s.completions["a"] == .init(done: false, at: Date(timeIntervalSince1970: 0)))
    }

    @Test func anyRealChangeBeatsAnUntimedRecord() {
        let phone = Self.build(completions: [.init(id: "a", done: true)])
        var laptop = phone
        laptop.deviceId = "laptop-device"
        laptop.completions["a"] = .init(done: false, at: Self.t(-600))
        let merged = SyncSnapshotMerge.merge(local: phone, remotes: [laptop]).snapshot
        #expect(merged.completions["a"]?.done == false)
    }

    // MARK: due edits and manual tasks

    @Test func dueEditsKeepClearedAndUntimedEdits() {
        let s = Self.build(dueEdits: [
            .init(id: "a", dueAt: Self.t(50), changedAt: Self.t(4)),
            .init(id: "b", dueAt: nil, changedAt: Self.t(6)),
            .init(id: "c", dueAt: Self.t(60)),
        ])
        #expect(s.dueEdits["a"] == .init(dueAt: Self.t(50), at: Self.t(4)))
        #expect(s.dueEdits["b"] == .init(dueAt: nil, at: Self.t(6)))
        #expect(s.dueEdits["c"]?.at == Date(timeIntervalSince1970: 0))
    }

    @Test func manualTasksCarryEverythingAndTombstonesStay() {
        let s = Self.build(manual: [
            .init(id: "m1", title: "read", course: "CIS 1200", dueAt: Self.t(9), kind: .assignment,
                  repeatsWeekly: true, changedAt: Self.t(2)),
            .init(id: "m2", title: "", course: "", dueAt: nil, repeatsWeekly: false,
                  removed: true, changedAt: Self.t(7)),
        ])
        #expect(s.manual["m1"] == .init(title: "read", course: "CIS 1200", dueAt: Self.t(9), kind: .assignment,
                                        repeatsWeekly: true, removed: false, at: Self.t(2)))
        #expect(s.manual["m2"]?.removed == true)
        #expect(s.manual["m2"]?.at == Self.t(7))
    }

    // MARK: whole snapshot

    @Test func carriesDeviceNowAndWorkListAndRoundsToMilliseconds() {
        let item = SyncSnapshot.WorkItem(id: "canvas:1", course: "C", title: "t",
                                         dueAt: Date(timeIntervalSince1970: 1_792_670_400.0004),
                                         kind: .quiz, source: "canvas", url: nil, done: false)
        let s = SyncSnapshotBuilder.build(deviceID: "phone-device-1",
                                          now: Date(timeIntervalSince1970: 1_792_670_400.0004),
                                          completions: [], dueEdits: [], manual: [], workList: [item])
        #expect(s.deviceId == "phone-device-1")
        #expect(s.format == 1)
        #expect(s.writtenAt == Self.t(0))
        #expect(s.workList.count == 1)
        #expect(s.workList[0].dueAt == Self.t(0))
        #expect(s.workList[0].kind == .quiz)
    }

    @Test func theBuiltSnapshotSurvivesTheWireUnchanged() throws {
        let built = Self.build(
            completions: [.init(id: "canvas:1", done: true, completedAt: Self.t(1)),
                          .init(id: "gradescope:2", done: false, changedAt: Self.t(3))],
            dueEdits: [.init(id: "canvas:1", dueAt: nil, changedAt: Self.t(2))],
            manual: [.init(id: "m", title: "t \"q\"", course: "C", dueAt: nil, repeatsWeekly: false)])
        let decoded = try SyncSnapshot.decode(built.canonicalJSON())
        #expect(decoded == built)
    }

    // MARK: facts from the stores

    @Test func completionFactsIncludeAnUntickKnownOnlyFromTheLog() {
        let facts = SyncSnapshotBuilder.completionFacts(
            doneIDs: ["canvas:1", "canvas:2"],
            completedAt: ["canvas:1": Self.t(1)],
            changeTimes: ["canvas:2": Self.t(5), "canvas:3": Self.t(6)])
        #expect(facts == [
            .init(id: "canvas:1", done: true, completedAt: Self.t(1), changedAt: nil),
            .init(id: "canvas:2", done: true, completedAt: nil, changedAt: Self.t(5)),
            .init(id: "canvas:3", done: false, completedAt: nil, changedAt: Self.t(6)),
        ])
    }

    @Test func dueEditFactsMarkAClearedEditWithNil() {
        let facts = SyncSnapshotBuilder.dueEditFacts(
            edits: ["a": Self.t(10)], changeTimes: ["a": Self.t(1), "b": Self.t(2)])
        #expect(facts == [.init(id: "a", dueAt: Self.t(10), changedAt: Self.t(1)),
                          .init(id: "b", dueAt: nil, changedAt: Self.t(2))])
    }

    @Test func manualFactsAddTombstonesForLoggedIDsThatAreNoLongerLive() {
        let live = SyncSnapshotBuilder.ManualFact(id: "m1", title: "t", course: "C", dueAt: nil, repeatsWeekly: false)
        let facts = SyncSnapshotBuilder.manualFacts(live: [live], changeTimes: ["m1": Self.t(1), "gone": Self.t(2)])
        #expect(facts.count == 2)
        #expect(facts[0].id == "m1" && facts[0].removed == false && facts[0].changedAt == Self.t(1))
        #expect(facts[1].id == "gone" && facts[1].removed == true && facts[1].changedAt == Self.t(2))
    }

    @Test func aLiveManualTaskKeepsAnExplicitTimeOverTheLog() {
        let live = SyncSnapshotBuilder.ManualFact(id: "m1", title: "t", course: "C", dueAt: nil,
                                                  repeatsWeekly: false, changedAt: Self.t(9))
        let facts = SyncSnapshotBuilder.manualFacts(live: [live], changeTimes: ["m1": Self.t(1)])
        #expect(facts[0].changedAt == Self.t(9))
    }
}
