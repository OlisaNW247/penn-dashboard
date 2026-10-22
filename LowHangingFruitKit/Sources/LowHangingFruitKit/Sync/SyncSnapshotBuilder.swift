import Foundation

/// Builds this phone's own `SyncSnapshot` from plain inputs. Pure: the caller
/// reads the ledger, the due-edit store, the manual and recurring task lists and
/// `SyncChangeLog`, and hands over values; nothing here touches any of them, so
/// the rules below are tested without a ledger.
///
/// **A record with no known change time sorts below every real change.** The
/// snapshot has to speak for everything the student has already done (a
/// completion ticked months ago, a task added before this feature existed), or
/// the other device would never hear of it. But those records have no recorded
/// time, and the one that is tempting to give them is "now, when the snapshot
/// was built". That is wrong: every old completion would then look like a fresh
/// tap and beat a genuine un-tick the student made on the laptop an hour ago,
/// quietly resurrecting work they had deliberately put back, and a stale due
/// date would overwrite a newer one. So a completion falls back to its
/// ledger `completedAt` (a real time, the tick) and, if that is nil too (old
/// rows legitimately have none), to the Unix epoch; a due edit or a manual task
/// with no recorded time gets the epoch. Any change made anywhere afterwards
/// has a later time and wins, which is the direction a merge that must never
/// lose the student's action should err in.
///
/// Every date is rounded to the millisecond, the wire's precision, so the
/// snapshot compared in `SyncApplyPlan` is the snapshot a peer would decode.
public enum SyncSnapshotBuilder {
    /// The "unknown time" floor.
    public static let epoch = Date(timeIntervalSince1970: 0)

    public struct CompletionFact: Sendable, Equatable {
        public var id: String
        public var done: Bool
        /// The ledger's `completedAt`, if the row has one.
        public var completedAt: Date?
        /// From `SyncChangeLog`, if recorded.
        public var changedAt: Date?
        public init(id: String, done: Bool, completedAt: Date? = nil, changedAt: Date? = nil) {
            self.id = id; self.done = done; self.completedAt = completedAt; self.changedAt = changedAt
        }
    }

    public struct DueEditFact: Sendable, Equatable {
        public var id: String
        /// nil: the edit was cleared (a real value on the wire).
        public var dueAt: Date?
        public var changedAt: Date?
        public init(id: String, dueAt: Date?, changedAt: Date? = nil) {
            self.id = id; self.dueAt = dueAt; self.changedAt = changedAt
        }
    }

    public struct ManualFact: Sendable, Equatable {
        public var id: String
        public var title: String
        public var course: String
        public var dueAt: Date?
        public var kind: Assignment.Kind
        public var repeatsWeekly: Bool
        public var removed: Bool
        public var changedAt: Date?
        public init(id: String, title: String, course: String, dueAt: Date?,
                    kind: Assignment.Kind = .assignment, repeatsWeekly: Bool,
                    removed: Bool = false, changedAt: Date? = nil) {
            self.id = id; self.title = title; self.course = course; self.dueAt = dueAt
            self.kind = kind; self.repeatsWeekly = repeatsWeekly
            self.removed = removed; self.changedAt = changedAt
        }
    }

    public static func build(
        deviceID: String,
        now: Date,
        completions: [CompletionFact],
        dueEdits: [DueEditFact],
        manual: [ManualFact],
        workList: [SyncSnapshot.WorkItem]
    ) -> SyncSnapshot {
        var c: [String: SyncSnapshot.Completion] = [:]
        for f in completions {
            let at = f.changedAt ?? (f.done ? f.completedAt : nil) ?? epoch
            c[f.id] = SyncSnapshot.Completion(done: f.done, at: Self.rounded(at))
        }
        var d: [String: SyncSnapshot.DueEdit] = [:]
        for f in dueEdits {
            d[f.id] = SyncSnapshot.DueEdit(dueAt: f.dueAt.map(Self.rounded), at: Self.rounded(f.changedAt ?? epoch))
        }
        var m: [String: SyncSnapshot.ManualTask] = [:]
        for f in manual {
            m[f.id] = SyncSnapshot.ManualTask(
                title: f.title, course: f.course, dueAt: f.dueAt.map(Self.rounded),
                kind: f.kind, repeatsWeekly: f.repeatsWeekly, removed: f.removed,
                at: Self.rounded(f.changedAt ?? epoch))
        }
        let items = workList.map { item -> SyncSnapshot.WorkItem in
            var copy = item
            copy.dueAt = item.dueAt.map(Self.rounded)
            return copy
        }
        return SyncSnapshot(deviceId: deviceID, writtenAt: Self.rounded(now), completions: c,
                            dueEdits: d, manual: m, workList: items)
    }

    // MARK: Turning the phone's stores into facts

    /// One fact per id that is done now OR has a recorded change time. The
    /// second half matters: an item the student ticked and then un-ticked is no
    /// longer done anywhere in the ledger (un-ticking a completion-only row
    /// deletes it), so without its logged time the un-tick would never be
    /// written as `done: false` and the other device would keep the tick.
    public static func completionFacts(
        doneIDs: Set<String>,
        completedAt: [String: Date],
        changeTimes: [String: Date]
    ) -> [CompletionFact] {
        doneIDs.union(changeTimes.keys).sorted().map { id in
            CompletionFact(id: id, done: doneIDs.contains(id),
                           completedAt: completedAt[id], changedAt: changeTimes[id])
        }
    }

    /// One fact per current edit, plus one "cleared" fact (`dueAt: nil`) per id
    /// with a logged time and no current edit.
    public static func dueEditFacts(
        edits: [String: Date],
        changeTimes: [String: Date]
    ) -> [DueEditFact] {
        Set(edits.keys).union(changeTimes.keys).sorted().map { id in
            DueEditFact(id: id, dueAt: edits[id], changedAt: changeTimes[id])
        }
    }

    /// The live tasks with their logged times, plus a tombstone for every id
    /// that has a logged time but is no longer live (the student removed it, or
    /// a removal arrived from another device). A tombstone's other fields are
    /// blank on purpose: a removed record's content is never read, and the
    /// phone does not keep the title of something deleted.
    public static func manualFacts(
        live: [ManualFact],
        changeTimes: [String: Date]
    ) -> [ManualFact] {
        var out = live.map { fact -> ManualFact in
            var f = fact
            f.removed = false
            f.changedAt = fact.changedAt ?? changeTimes[fact.id]
            return f
        }
        let liveIDs = Set(live.map(\.id))
        for (id, at) in changeTimes.sorted(by: { $0.key < $1.key }) where !liveIDs.contains(id) {
            out.append(ManualFact(id: id, title: "", course: "", dueAt: nil, kind: .assignment,
                                  repeatsWeekly: false, removed: true, changedAt: at))
        }
        return out
    }

    private static func rounded(_ date: Date) -> Date { SyncChangeLog.rounded(date) }
}
