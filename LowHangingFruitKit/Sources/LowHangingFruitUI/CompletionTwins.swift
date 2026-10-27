import Foundation

/// The two pure rules behind "un-ticking a card un-ticks everything it stands
/// in for" (hardening plan B4, DAT-03).
///
/// A dashboard card is often one of several ledger ids: a section-override
/// duplicate, a Modules copy of a Canvas assignment, an announcement's copy of
/// a real task. `rebuildDashboardItems` hides all but one (the survivor) and
/// `carryCompletion` copies a tick from a hidden id onto the survivor so the
/// student's work is never lost by a presentation collapse. That carry runs on
/// EVERY rebuild, so un-ticking the survivor alone was undone by the very next
/// rebuild (`markActive` ends with one): the hidden twin still held the old
/// completion and the carry ticked the card again. Two rules fix it, and
/// neither is enough alone.
enum CompletionTwins {

    /// `ids` plus every hidden id that stood in for any of them, followed
    /// transitively: a find whose real twin is itself the survivor of an
    /// override collapse stands behind two hops. `twins` is
    /// `[survivor id: hidden ids]` as the last rebuild recorded it.
    ///
    /// This is what `markActive` clears. The wrong fix is clearing only the
    /// tapped id and hoping the carry notices, which is the bug.
    nonisolated static func closure(of ids: Set<String>, twins: [String: Set<String>]) -> Set<String> {
        var result = ids
        var frontier = Array(ids)
        while let next = frontier.popLast() {
            for hidden in twins[next] ?? [] where result.insert(hidden).inserted {
                frontier.append(hidden)
            }
        }
        return result
    }

    /// Names one carry: this tick, on this hidden id, onto this survivor. A
    /// carry fires once per key (`AppState.carriedCompletions`).
    ///
    /// The completion time is part of the key on purpose. Without it "once per
    /// pair" would also swallow a legitimate second carry: the student ticks
    /// the hidden copy again later (a new completion, a new time) and expects
    /// the card to follow, as it did the first time. The same tick, seen again
    /// by a later rebuild after the survivor was deliberately un-ticked, has
    /// the same time and the same key, and is not carried again. A completion
    /// with no recorded time (carried over from a build that predates
    /// timestamps) keys on "none", which is stable as well.
    nonisolated static func carryKey(hiddenID: String, survivorID: String, completedAt: Date?) -> String {
        let stamp = completedAt.map { String($0.timeIntervalSinceReferenceDate) } ?? "none"
        return "\(hiddenID)\u{1F}\(survivorID)\u{1F}\(stamp)"
    }
}
