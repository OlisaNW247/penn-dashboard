import Foundation
import LowHangingFruitKit

/// Moves the ticks and edited due dates a student already made on recurring
/// occurrences from the ids the previous builds minted to the ids this build
/// mints, once.
///
/// **Why it is needed.** An occurrence's id ends in a number
/// (`RecurringTask.occurrenceStamp`). Builds before the zone fix wrote the
/// instant the occurrence's local date and time land on in the phone's zone;
/// this build writes the instant they would land on in Eastern time, so that
/// the id stops changing when the phone travels. For a phone in Eastern time
/// the two are the same number and this does nothing. For a phone in Pacific
/// or Central time every id changes once, and without this the ticks and
/// edited dates the student has on the coming weeks' readings would be filed
/// under ids that no longer exist: the readings come back as owed, the
/// "turned in" is gone, and the changed due date reverts to the original. The
/// note above `RecurringTask.occurrenceSourceID` is about exactly this.
///
/// **How an old id becomes a new one.** Both are functions of the same local
/// date and time. The old id carries the instant (`E`) in the phone's zone, so
/// reading `E` back in that zone gives the wall clock, and
/// `occurrenceStamp(due: E, zone:)` is the new number. It assumes the old ids
/// were minted in the zone the phone is in now; one minted in another zone
/// (a trip across the upgrade) maps to an id no occurrence has, which is a
/// tick that does not show, not a wrong one: the id names a different
/// weekday-and-time than any the task generates.
///
/// **Copy, never move.** The old row and the old edit are left where they are.
/// The ledger's rule is that nothing the student did is deleted, a stale
/// completion-only row is invisible, and the edit pruner already drops an edit
/// whose item is gone. What is added is the new id carrying the same date.
///
/// **Once.** A new id read as an old one would map to yet another id, so a
/// second run would chain a stray completion onto every id each launch. The
/// run is therefore gated by a flag, set only after the ledger was available
/// to read.
enum RecurringOccurrenceRekey {
    static let doneKey = "recurringOccurrenceIDsRekeyedV1"

    struct Outcome: Equatable {
        var completionsCopied = 0
        var editsCopied = 0
    }

    /// The id this build mints for the occurrence that `id` named in earlier
    /// builds, or nil when `id` is not an occurrence id or maps to itself (an
    /// Eastern-zone phone).
    static func newID(forLegacyID id: String, zone: TimeZone) -> String? {
        guard let colon = id.firstIndex(of: ":"),
              let source = Assignment.Source(rawValue: String(id[..<colon])),
              source == .manual || source == .canvasSuggestion
        else { return nil }
        let sourceID = String(id[id.index(after: colon)...])
        guard RecurringTask.occurrenceTaskID(fromSourceID: sourceID) != nil,
              let epoch = Int(sourceID.dropFirst(37))   // 36-character UUID, then "-"
        else { return nil }
        let stamp = RecurringTask.occurrenceStamp(due: Date(timeIntervalSince1970: TimeInterval(epoch)), zone: zone)
        guard stamp != epoch else { return nil }
        return "\(source.rawValue):\(sourceID.prefix(36))-\(stamp)"
    }

    /// Re-keys the ledger's completions and the stored due-date edits, unless
    /// that has been done. With no ledger to read, or one that is only in
    /// memory, it does nothing and does not set the flag, so a later launch
    /// with a real ledger still runs it.
    @MainActor
    @discardableResult
    static func runIfNeeded(
        assignmentStore: AssignmentStore?,
        dueDateEditStore: DueDateEditStore?,
        defaults: UserDefaults = .lhf,
        zone: TimeZone = .current
    ) -> Outcome {
        var outcome = Outcome()
        // A ledger that is only in memory (the fallback, a test) would lose the
        // copied ticks at quit and then never be re-keyed, because the flag
        // below would already be set.
        guard let assignmentStore, assignmentStore.isPersistent, !defaults.bool(forKey: doneKey) else { return outcome }

        // A tick keeps its own time. One with no time at all (from before the
        // ledger stamped completions) is skipped: it can only be on an
        // occurrence long past, which is no longer generated, and recording it
        // here would have to invent a time.
        let record = assignmentStore.completionRecord()
        var byDate: [Date: Set<String>] = [:]
        for id in record.ids {
            guard let new = newID(forLegacyID: id, zone: zone), !record.ids.contains(new),
                  let date = record.dates[id]
            else { continue }
            byDate[date, default: []].insert(new)
        }
        for (date, ids) in byDate {
            assignmentStore.setCompleted(ids: ids, at: date)
            outcome.completionsCopied += ids.count
        }

        if let dueDateEditStore {
            var edits = dueDateEditStore.load()
            var copied: [String: Date] = [:]
            for (id, date) in edits {
                if let new = newID(forLegacyID: id, zone: zone), edits[new] == nil { copied[new] = date }
            }
            if !copied.isEmpty {
                edits.merge(copied) { current, _ in current }
                dueDateEditStore.save(edits)
                outcome.editsCopied = copied.count
            }
        }

        defaults.set(true, forKey: doneKey)
        return outcome
    }
}
