import Foundation

/// When the student last changed each thing that syncs, and this install's id
/// in the sync (docs/CHROME_EXTENSION.md, "The snapshot (format 1)").
///
/// The merge needs a per-record "last changed" time (`at`), and the ledger
/// cannot supply it. `StoredAssignment.completedAt` is legitimately nil for old
/// completions and says nothing about an un-tick; a due edit has no time at
/// all; a removed manual task is a deleted row. The tempting fix is to add a
/// `changedAt` column to `StoredAssignment`. It is wrong on this codebase: a
/// schema change makes an older build fall back to an empty in-memory ledger
/// (CLAUDE.md, Traps), which would show a student their work gone because they
/// opened the app on a phone that had not updated yet. So the times live here,
/// in `UserDefaults.lhf` (`syncChangeTimesV1`), beside `dueDateEditsV1` and for
/// the same reason that key's comment gives. Losing them costs nothing that
/// matters: a record with no time sorts below any real change
/// (`SyncSnapshotBuilder`).
///
/// Keyed as the snapshot is, by kind and then the record's own id
/// (`Assignment.id` for completions and due edits, the manual task's id for
/// manual tasks), so the entry for a thing is always the entry the snapshot
/// reads. An entry is never removed when the thing it describes goes away: the
/// time of an un-tick or of a removal is the only trace of it, and the
/// snapshot's `done: false` and tombstone records are built from exactly that.
/// `clear()` is for the day the student unpairs everything.
///
/// Times are rounded to the millisecond on the way in, because that is all the
/// wire carries; a time that survived the round trip differently from the one
/// held here would make "did the remote win?" depend on sub-millisecond noise.
///
/// Neither key is mirrored to iCloud (`CloudPrefsMirror.mirroredKeys`) and
/// neither is in `SharedDefaultsMigration.legacyKeys`: the device id exists to
/// tell installs apart, and the change times describe this install's own taps.
/// A device restored from another's backup does inherit the id; that retires
/// the old phone's blob slot to the new one, which is what a restore means.
public struct SyncChangeLog {
    public enum Kind: String, Sendable, CaseIterable {
        case completion
        case dueEdit
        case manual
    }

    public static let changeTimesKey = "syncChangeTimesV1"
    public static let deviceIDKey = "syncDeviceIDV1"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: Change times

    /// Notes that `id` changed at `at`, replacing any earlier time. A newer
    /// change always replaces an older one, and applying a remote change passes
    /// the remote's own `at`, never now: stamping a remote change with the
    /// local clock would let an old edit overtake a newer one on the next
    /// merge.
    public func record(kind: Kind, id: String, at: Date) {
        var all = load()
        all[Self.entryKey(kind, id)] = Self.rounded(at)
        defaults.set(all, forKey: Self.changeTimesKey)
    }

    public func time(kind: Kind, id: String) -> Date? {
        load()[Self.entryKey(kind, id)]
    }

    /// Every recorded time of one kind, by record id. The snapshot builder
    /// needs the ids too (an un-ticked item is no longer in the ledger as done,
    /// so the log is the only place that remembers it).
    public func times(kind: Kind) -> [String: Date] {
        let prefix = kind.rawValue + ":"
        var out: [String: Date] = [:]
        for (key, date) in load() where key.hasPrefix(prefix) {
            out[String(key.dropFirst(prefix.count))] = date
        }
        return out
    }

    /// Forgets every change time. Not the device id.
    public func clear() {
        defaults.removeObject(forKey: Self.changeTimesKey)
    }

    // MARK: Device id

    /// This install's id in the sync, made once. It is the `deviceId` in the
    /// snapshot (merge ties go to the larger id) and the key of this phone's
    /// blob on the server, so it must match the server's
    /// `^[A-Za-z0-9_-]{8,64}$`; a stored value that does not (a hand-edited
    /// plist) is replaced rather than sent and refused with a 400 every time.
    public func deviceID() -> String {
        if let existing = defaults.string(forKey: Self.deviceIDKey), Self.isValidDeviceID(existing) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: Self.deviceIDKey)
        return fresh
    }

    public static func isValidDeviceID(_ text: String) -> Bool {
        guard (8...64).contains(text.utf8.count) else { return false }
        return text.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A)
                || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
        }
    }

    // MARK: Storage

    static func entryKey(_ kind: Kind, _ id: String) -> String { kind.rawValue + ":" + id }

    static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// An entry that is not a `Date` is skipped, as `DueDateEditStore.load`
    /// does: a damaged value costs that one record its time, not the rest.
    private func load() -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: Self.changeTimesKey) else { return [:] }
        var out: [String: Date] = [:]
        for (key, value) in raw {
            if let date = value as? Date { out[key] = date }
        }
        return out
    }
}
