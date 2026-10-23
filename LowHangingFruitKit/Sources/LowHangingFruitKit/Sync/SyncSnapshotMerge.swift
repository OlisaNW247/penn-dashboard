import Foundation

/// Merges the snapshots of every device into one view of what the student did.
///
/// The rule is the ledger invariant from the spec: nothing is ever lost. Per
/// key, the later `at` wins; a tie goes to the lexicographically larger
/// `deviceId`, compared by Unicode scalar (JS compares by code point, so a
/// plain Swift `String <` on grapheme clusters would disagree on exotic ids).
/// A completion and an un-completion are both changes, so a later
/// `done == false` beats an earlier tick. A removed manual task is a
/// tombstone judged by the same rule as any edit: a later edit revives it,
/// a later removal buries it, and it is never purged. A due edit with a nil
/// `dueAt` is a real value ("edit cleared") and wins like any other.
///
/// The change times live outside the SwiftData ledger (the spec explains:
/// `completedAt` is nil for old completions and a schema change makes an
/// older build fall back to an empty ledger), so this layer knows nothing of
/// the ledger and is pure: no clock, no I/O. Picking the maximum under a
/// total order also makes the result independent of input order.
public enum SyncSnapshotMerge {
    public struct Merged: Sendable {
        /// The local snapshot's own `deviceId`, `writtenAt` and `workList`,
        /// carrying the merged records.
        public var snapshot: SyncSnapshot
        /// Each remote device's own dashboard, read-only, never merged, in
        /// the order the remotes were given.
        public var remoteWorkLists: [(deviceId: String, workList: [SyncSnapshot.WorkItem])]
    }

    /// One pass over every snapshot at once, not pairwise: a merged snapshot
    /// no longer remembers which device won each tie, so folding would
    /// change answers.
    public static func merge(local: SyncSnapshot, remotes: [SyncSnapshot]) -> Merged {
        let all = [local] + remotes
        var snapshot = local
        snapshot.completions = pick(all, \.completions, at: \.at)
        snapshot.dueEdits = pick(all, \.dueEdits, at: \.at)
        snapshot.manual = pick(all, \.manual, at: \.at)
        return Merged(snapshot: snapshot,
                      remoteWorkLists: remotes.map { ($0.deviceId, $0.workList) })
    }

    private static func pick<V>(
        _ snapshots: [SyncSnapshot],
        _ dict: KeyPath<SyncSnapshot, [String: V]>,
        at time: KeyPath<V, Date>
    ) -> [String: V] {
        var best: [String: (value: V, device: String)] = [:]
        for s in snapshots {
            for (key, value) in s[keyPath: dict] {
                if let cur = best[key] {
                    let a = value[keyPath: time], b = cur.value[keyPath: time]
                    let wins = a > b || (a == b && s.deviceId.unicodeScalars
                        .lexicographicallyPrecedes(cur.device.unicodeScalars) == false
                        && s.deviceId != cur.device)
                    if !wins { continue }
                }
                best[key] = (value, s.deviceId)
            }
        }
        return best.mapValues(\.value)
    }
}
