import Foundation

/// What the phone must do to its own state after a merge: the difference
/// between the local snapshot and the merged result, restricted to records a
/// remote device won. Pure; the caller applies the actions through the same
/// paths a swipe, an edited date and the add sheet use, so reminders, the
/// widget and the Sweeper follow (docs/CHROME_EXTENSION.md).
///
/// "Came from a remote" needs no bookkeeping: `SyncSnapshotMerge` picks each
/// record whole from one of the snapshots, so a merged record that differs from
/// the local one can only be a remote's. Equal means the local one won (or the
/// remote said the same thing), and the phone already is what the record says.
/// A remote older than a local change therefore produces nothing.
///
/// **Nothing here deletes a ledger row of a feed.** There is no action that
/// removes an assignment, and `.uncomplete` clears a tick, it does not forget
/// the item. The one removal is `.removeManual`, the student's own one-off or
/// recurring task, deleted on another of their devices; that is their own
/// action, and the tombstone it came from is kept by the log forever.
///
/// Two things the caller must still do for every record in `adoptedTimes`,
/// whether or not an action came with it: store the remote's `at` in
/// `SyncChangeLog` (never the local clock; see `SyncChangeLog.record`), after
/// applying the actions, because applying one goes through the same code a tap
/// does and a tap stamps "now". Without it the phone would next write the
/// record back with a fresh time and win a tie it should have lost.
public enum SyncApplyPlan {
    public enum Action: Equatable, Sendable {
        /// Make `id` a completed item. `at` is when it was ticked on the other
        /// device; use it as `completedAt` rather than now, so the Done tab and
        /// the weekly ring place it where the student ticked it.
        ///
        /// The id may be one the phone has never seen (a Canvas item before its
        /// feed has been synced here, or a different source's id entirely). That
        /// is kept, not dropped: `AssignmentStore.setCompleted(ids:at:prototypes:)`
        /// writes it as a completion-only row
        /// (`StoredAssignment.completionOnly`, `isCompletionOnly == true`), which
        /// is hidden from every read of "assignments the app knows about" until
        /// a feed row with that id arrives and `refresh(from:now:)` promotes it
        /// in place with the tick intact.
        case complete(id: String, at: Date)
        /// Clear the student's tick on `id`. Only emitted where the phone's own
        /// snapshot said it was done.
        case uncomplete(id: String)
        /// Set (or, with nil, clear) the student's edited due date for `id`.
        case setDueEdit(id: String, dueAt: Date?)
        /// A live manual task the phone does not have (or had removed, and a
        /// later edit elsewhere revived). `task.repeatsWeekly` says whether it
        /// is a `RecurringTask` or a one-off `ManualAssignment`.
        case addManual(id: String, task: SyncSnapshot.ManualTask)
        /// A task the phone has, changed elsewhere. Only the fields in `task`
        /// that differ from the phone's matter; `repeatsWeekly` may differ too.
        case updateManual(id: String, task: SyncSnapshot.ManualTask)
        /// A task the student removed elsewhere, and the phone still has live.
        case removeManual(id: String)
    }

    /// A merged record that came from a remote, for `SyncChangeLog.record`.
    public struct AdoptedTime: Equatable, Sendable {
        public var kind: SyncChangeLog.Kind
        public var id: String
        public var at: Date
    }

    public struct Plan: Equatable, Sendable {
        public var actions: [Action] = []
        public var adoptedTimes: [AdoptedTime] = []
        public var isEmpty: Bool { actions.isEmpty && adoptedTimes.isEmpty }
    }

    /// `merged` is `SyncSnapshotMerge.merge(local:remotes:).snapshot`, merged
    /// from this same `local`. Output order is fixed (completions, due edits,
    /// manual tasks, each by id) so a run is reproducible.
    public static func plan(local: SyncSnapshot, merged: SyncSnapshot) -> Plan {
        var plan = Plan()

        for id in merged.completions.keys.sorted() {
            guard let m = merged.completions[id], m != local.completions[id] else { continue }
            plan.adoptedTimes.append(.init(kind: .completion, id: id, at: m.at))
            // No local record reads as "not done": the phone has no tick to clear.
            let localDone = local.completions[id]?.done ?? false
            if m.done && !localDone {
                plan.actions.append(.complete(id: id, at: m.at))
            } else if !m.done && localDone {
                plan.actions.append(.uncomplete(id: id))
            }
        }

        for id in merged.dueEdits.keys.sorted() {
            guard let m = merged.dueEdits[id], m != local.dueEdits[id] else { continue }
            plan.adoptedTimes.append(.init(kind: .dueEdit, id: id, at: m.at))
            if m.dueAt != local.dueEdits[id]?.dueAt {
                plan.actions.append(.setDueEdit(id: id, dueAt: m.dueAt))
            }
        }

        for id in merged.manual.keys.sorted() {
            guard let m = merged.manual[id], m != local.manual[id] else { continue }
            plan.adoptedTimes.append(.init(kind: .manual, id: id, at: m.at))
            let l = local.manual[id]
            let localLive = l.map { !$0.removed } ?? false
            if m.removed {
                if localLive { plan.actions.append(.removeManual(id: id)) }
            } else if !localLive {
                plan.actions.append(.addManual(id: id, task: m))
            } else if let l, !sameContent(l, m) {
                plan.actions.append(.updateManual(id: id, task: m))
            }
        }
        return plan
    }

    private static func sameContent(_ a: SyncSnapshot.ManualTask, _ b: SyncSnapshot.ManualTask) -> Bool {
        a.title == b.title && a.course == b.course && a.dueAt == b.dueAt
            && a.kind == b.kind && a.repeatsWeekly == b.repeatsWeekly
    }
}
