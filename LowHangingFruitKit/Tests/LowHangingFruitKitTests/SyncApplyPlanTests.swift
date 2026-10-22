import Foundation
import Testing
@testable import LowHangingFruitKit

/// What the phone must do after a merge. The merge itself is
/// `SyncSnapshotTests`; these drive it for real so the plan is judged on what
/// the merge actually returns.
@Suite struct SyncApplyPlanTests {
    static func t(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: 1_792_670_400 + Double(minute) * 60)
    }

    static func snap(_ device: String,
                     completions: [String: SyncSnapshot.Completion] = [:],
                     dueEdits: [String: SyncSnapshot.DueEdit] = [:],
                     manual: [String: SyncSnapshot.ManualTask] = [:]) -> SyncSnapshot {
        SyncSnapshot(deviceId: device, writtenAt: t(0), completions: completions,
                     dueEdits: dueEdits, manual: manual)
    }

    static func task(_ title: String = "read", due: Int? = nil, weekly: Bool = false,
                     removed: Bool = false, at: Int) -> SyncSnapshot.ManualTask {
        .init(title: title, course: "CIS 1200", dueAt: due.map(t), kind: .assignment,
              repeatsWeekly: weekly, removed: removed, at: t(at))
    }

    static func plan(local: SyncSnapshot, remotes: [SyncSnapshot]) -> SyncApplyPlan.Plan {
        SyncApplyPlan.plan(local: local, merged: SyncSnapshotMerge.merge(local: local, remotes: remotes).snapshot)
    }

    // MARK: completions

    @Test func aNewerRemoteTickCompletesAtTheRemoteTime() {
        let local = Self.snap("phone-0001", completions: ["canvas:1": .init(done: false, at: Self.t(1))])
        let remote = Self.snap("laptop-001", completions: ["canvas:1": .init(done: true, at: Self.t(5))])
        let p = Self.plan(local: local, remotes: [remote])
        #expect(p.actions == [.complete(id: "canvas:1", at: Self.t(5))])
        #expect(p.adoptedTimes == [.init(kind: .completion, id: "canvas:1", at: Self.t(5))])
    }

    @Test func aNewerRemoteUntickUncompletes() {
        let local = Self.snap("phone-0001", completions: ["canvas:1": .init(done: true, at: Self.t(1))])
        let remote = Self.snap("laptop-001", completions: ["canvas:1": .init(done: false, at: Self.t(5))])
        #expect(Self.plan(local: local, remotes: [remote]).actions == [.uncomplete(id: "canvas:1")])
    }

    @Test func aRemoteOlderThanTheLocalChangeChangesNothing() {
        let local = Self.snap("phone-0001",
                              completions: ["canvas:1": .init(done: false, at: Self.t(9))],
                              dueEdits: ["canvas:1": .init(dueAt: Self.t(70), at: Self.t(9))],
                              manual: ["m": Self.task("new title", at: 9)])
        let remote = Self.snap("laptop-001",
                               completions: ["canvas:1": .init(done: true, at: Self.t(2))],
                               dueEdits: ["canvas:1": .init(dueAt: Self.t(40), at: Self.t(2))],
                               manual: ["m": Self.task("old title", at: 2)])
        #expect(Self.plan(local: local, remotes: [remote]).isEmpty)
    }

    @Test func anIdThePhoneHasNeverSeenIsCompletedAnyway() {
        // The plan cannot know whether a row exists; the action is the same and
        // the store writes a completion-only row when none does.
        let local = Self.snap("phone-0001")
        let remote = Self.snap("laptop-001", completions: ["canvas:never-synced": .init(done: true, at: Self.t(5))])
        #expect(Self.plan(local: local, remotes: [remote]).actions
                == [.complete(id: "canvas:never-synced", at: Self.t(5))])
    }

    @Test func aRemoteUntickOfAnUnknownIdIsOnlyRemembered() {
        let local = Self.snap("phone-0001")
        let remote = Self.snap("laptop-001", completions: ["canvas:x": .init(done: false, at: Self.t(5))])
        let p = Self.plan(local: local, remotes: [remote])
        #expect(p.actions.isEmpty)
        #expect(p.adoptedTimes == [.init(kind: .completion, id: "canvas:x", at: Self.t(5))])
    }

    @Test func aNewerRemoteWithTheSameStateOnlyAdoptsItsTime() {
        let local = Self.snap("phone-0001", completions: ["canvas:1": .init(done: true, at: Self.t(1))])
        let remote = Self.snap("laptop-001", completions: ["canvas:1": .init(done: true, at: Self.t(5))])
        let p = Self.plan(local: local, remotes: [remote])
        #expect(p.actions.isEmpty)
        #expect(p.adoptedTimes.count == 1)
    }

    @Test func identicalSnapshotsPlanNothing() {
        let s = Self.snap("phone-0001", completions: ["canvas:1": .init(done: true, at: Self.t(1))],
                          manual: ["m": Self.task(at: 1)])
        var other = s
        other.deviceId = "laptop-001"
        #expect(Self.plan(local: s, remotes: [other]).isEmpty)
    }

    @Test func aRecordOnlyTheLocalSnapshotHasPlansNothing() {
        let local = Self.snap("phone-0001", completions: ["canvas:1": .init(done: true, at: Self.t(1))])
        #expect(Self.plan(local: local, remotes: [Self.snap("laptop-001")]).isEmpty)
    }

    @Test func aTieGoesToTheLargerDeviceIDAndThePlanFollowsIt() {
        let local = Self.snap("phone-0001", completions: ["canvas:1": .init(done: true, at: Self.t(5))])
        let remote = Self.snap("zzzz-laptop", completions: ["canvas:1": .init(done: false, at: Self.t(5))])
        #expect(Self.plan(local: local, remotes: [remote]).actions == [.uncomplete(id: "canvas:1")])
    }

    // MARK: due edits

    @Test func aRemoteDueEditIsSetAndAClearedOneClears() {
        let local = Self.snap("phone-0001", dueEdits: ["b": .init(dueAt: Self.t(30), at: Self.t(1))])
        let remote = Self.snap("laptop-001", dueEdits: [
            "a": .init(dueAt: Self.t(50), at: Self.t(4)),
            "b": .init(dueAt: nil, at: Self.t(4)),
        ])
        let p = Self.plan(local: local, remotes: [remote])
        #expect(p.actions == [.setDueEdit(id: "a", dueAt: Self.t(50)), .setDueEdit(id: "b", dueAt: nil)])
    }

    @Test func aRemoteClearedEditWhereThePhoneHasNoneOnlyAdoptsItsTime() {
        let local = Self.snap("phone-0001")
        let remote = Self.snap("laptop-001", dueEdits: ["a": .init(dueAt: nil, at: Self.t(4))])
        let p = Self.plan(local: local, remotes: [remote])
        #expect(p.actions.isEmpty)
        #expect(p.adoptedTimes == [.init(kind: .dueEdit, id: "a", at: Self.t(4))])
    }

    // MARK: manual tasks

    @Test func aNewRemoteTaskIsAdded() {
        let remote = Self.snap("laptop-001", manual: ["m": Self.task(due: 90, weekly: true, at: 3)])
        let p = Self.plan(local: Self.snap("phone-0001"), remotes: [remote])
        #expect(p.actions == [.addManual(id: "m", task: Self.task(due: 90, weekly: true, at: 3))])
    }

    @Test func aChangedRemoteTaskIsUpdated() {
        let local = Self.snap("phone-0001", manual: ["m": Self.task("a", at: 1)])
        let remote = Self.snap("laptop-001", manual: ["m": Self.task("b", at: 4)])
        #expect(Self.plan(local: local, remotes: [remote]).actions == [.updateManual(id: "m", task: Self.task("b", at: 4))])
    }

    @Test func aRemoteTombstoneRemovesALiveTask() {
        let local = Self.snap("phone-0001", manual: ["m": Self.task(at: 1)])
        let remote = Self.snap("laptop-001", manual: ["m": Self.task(removed: true, at: 4)])
        #expect(Self.plan(local: local, remotes: [remote]).actions == [.removeManual(id: "m")])
    }

    @Test func aRemoteTombstoneForATaskThePhoneNeverHadDoesNothing() {
        let remote = Self.snap("laptop-001", manual: ["m": Self.task(removed: true, at: 4)])
        let p = Self.plan(local: Self.snap("phone-0001"), remotes: [remote])
        #expect(p.actions.isEmpty)
        #expect(p.adoptedTimes.count == 1)
    }

    @Test func aLaterEditRevivesATaskThePhoneRemoved() {
        let local = Self.snap("phone-0001", manual: ["m": Self.task(removed: true, at: 2)])
        let remote = Self.snap("laptop-001", manual: ["m": Self.task("again", at: 6)])
        #expect(Self.plan(local: local, remotes: [remote]).actions == [.addManual(id: "m", task: Self.task("again", at: 6))])
    }

    @Test func aStaleRemoteCannotResurrectATaskThePhoneRemoved() {
        let local = Self.snap("phone-0001", manual: ["m": Self.task(removed: true, at: 6)])
        let remote = Self.snap("laptop-001", manual: ["m": Self.task("old", at: 2)])
        #expect(Self.plan(local: local, remotes: [remote]).isEmpty)
    }

    // MARK: the ledger is never the target

    @Test func noActionDeletesAFeedRow() {
        // The action set has no case that removes an assignment; the only
        // removal names a manual task. Drive every kind of remote win and
        // check that nothing but those cases appears.
        let local = Self.snap("phone-0001",
                              completions: ["canvas:1": .init(done: true, at: Self.t(1))],
                              manual: ["m": Self.task(at: 1)])
        let remote = Self.snap("laptop-001",
                               completions: ["canvas:1": .init(done: false, at: Self.t(5)),
                                             "canvas:2": .init(done: true, at: Self.t(5))],
                               dueEdits: ["canvas:1": .init(dueAt: nil, at: Self.t(5))],
                               manual: ["m": Self.task(removed: true, at: 5)])
        for action in Self.plan(local: local, remotes: [remote]).actions {
            switch action {
            case .complete, .uncomplete, .setDueEdit, .addManual, .updateManual, .removeManual: break
            }
        }
        #expect(Self.plan(local: local, remotes: [remote]).actions.count == 3)
    }

    @Test func actionsComeInAFixedOrder() {
        let remote = Self.snap("laptop-001",
                               completions: ["b": .init(done: true, at: Self.t(5)), "a": .init(done: true, at: Self.t(5))],
                               dueEdits: ["z": .init(dueAt: Self.t(9), at: Self.t(5))],
                               manual: ["m": Self.task(at: 5)])
        let p = Self.plan(local: Self.snap("phone-0001"), remotes: [remote])
        #expect(p.actions.map { String(describing: $0).prefix(8) } == ["complete", "complete", "setDueEd", "addManua"])
        #expect(p.actions.first == .complete(id: "a", at: Self.t(5)))
    }
}
