import Foundation

/// Where the student's hand-edited due dates are kept: one dictionary,
/// `[assignment id: Date]`, under `SharedDefaults.dueDateEditsKey`.
///
/// See that key's comment for why this is defaults and not the ledger (a new
/// `StoredAssignment` field is a schema migration this release should not
/// take). This type is only the read and the write; what an edit means (which
/// ids it covers, when it counts as "no edit", when an entry is stale) is
/// `AppState`'s, in `AppState+DueDateEdits.swift`.
///
/// The `UserDefaults` is injected, as for `SignupBacklogStore`. Production uses
/// `UserDefaults.lhf`; tests use a scratch suite, because a value written to the
/// shared domain is read by the `AppState.init` of every suite running alongside
/// (the shared-defaults trap in `CLAUDE.md`).
///
/// Values are stored as `Date`, which a property list keeps as a double-precision
/// absolute time, so a date comes back bit-for-bit and an edit compared with the
/// feed's own due date after a relaunch is the same comparison as before it.
public struct DueDateEditStore {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Everything stored. An entry that is not a `Date` is skipped rather than
    /// failing the read: a damaged value costs that one edit (the item shows its
    /// feed date again), never the other edits beside it.
    public func load() -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: SharedDefaults.dueDateEditsKey) else { return [:] }
        var edits: [String: Date] = [:]
        for (id, value) in raw {
            if let date = value as? Date { edits[id] = date }
        }
        return edits
    }

    /// Replaces what is stored. An empty dictionary removes the key, so a
    /// student who has reset every edit leaves nothing behind.
    public func save(_ edits: [String: Date]) {
        if edits.isEmpty {
            defaults.removeObject(forKey: SharedDefaults.dueDateEditsKey)
        } else {
            defaults.set(edits, forKey: SharedDefaults.dueDateEditsKey)
        }
    }
}
