import Foundation
import LowHangingFruitKit

// MARK: – The student's edited due dates
//
// "edit date" on a card used to live and die in `DashboardViewModel.items`: a
// view model's in-memory array, rebuilt from `AppState` on every `reload`, so an
// edit survived a feed refresh (the view model carried it across) and nothing
// else. Not a relaunch, not the app being evicted in the background, and not
// any reader that does not go through the view model: the widget snapshot and
// ask's two pools read `Assignment.dueAt` straight off `AppState`'s arrays, so
// they went on reporting the feed's date for work the student had moved.
//
// `AppState` owns the edits now, as `[assignment id: Date]`, persisted
// (`DueDateEditStore`, `SharedDefaults.dueDateEditsKey`; that key's comment says
// why this is defaults and not the ledger). Every reader ON THE PHONE asks
// `AppState` for the date:
//
//  - the dashboard: `DashboardViewModel.reload` fills `DashItem.dueOverride`,
//    and its sections, the card, the prev tab's placement and reminders (which
//    plan from `vm.items`' `due`) all follow it;
//  - the widget snapshot: `widgetNextDueItems()`;
//  - ask, on-device: `assistantWorkItems()`.
//
// One reader deliberately does NOT: `assistantContextDocument()`, the document
// ask sends to the backend, keeps the feed's date. docs/PRIVACY.md promises
// that due-date edits never leave the device, and quoting the edit there would
// upload it. So the on-device answerer and the server path can disagree about a
// date the student moved; that is the price of the promise.
//
// The wrong fix would have been to persist the view model's array, or to write
// the edit onto `canvasItems` itself: the feed overwrites those on every sync
// (`StoredAssignment.refresh(from:now:)` copies `dueAt` from the feed), which
// would hand the student's edit back to Canvas on the next refresh. The edit is
// kept beside the pool and applied at read time, so the feed's own date is never
// touched and "reset to original due date" always has something to reset to.
//
// None of this is in `sync()`, `syncGradescope` or `connectCanvas`; the only
// line in `rebuildDashboardItems` is the `pruneDueDateEdits` call at its end.

extension AppState {
    /// The date the student edited this item to, if they did.
    func editedDueDate(for assignment: Assignment) -> Date? {
        dueDateEdits[assignment.id]
    }

    /// The date this item is due as far as the student is concerned: their edit
    /// if they made one, the feed's otherwise. If the feed later moves the item
    /// the edit still wins, which is what the in-memory edit always did: the
    /// student looked at the date and chose a different one.
    func effectiveDueDate(for assignment: Assignment) -> Date? {
        dueDateEdits[assignment.id] ?? assignment.dueAt
    }

    /// Records (or, with `nil`, clears) the student's edited due date for an
    /// item, and persists it.
    ///
    /// A cross-posted item (`linkedID`: the same assignment on Canvas and on
    /// Gradescope, collapsed into one card by `AssignmentDeduplicator`) is
    /// recorded under both ids, the way completion marks both. The card carries
    /// one of them; the on-device ask pool is built from the raw feeds and
    /// lists both copies, so keying only the card's id would leave ask quoting
    /// the unedited date for the twin.
    ///
    /// An edit equal to the item's own date is not an edit: it clears the entry
    /// rather than storing a no-op that would later read as "edited" on a card
    /// whose feed date had since moved.
    ///
    /// Preview and demo mode never write: the items there are bundled fixtures
    /// whose ids mean nothing on a real install, and a reviewer's taps must not
    /// leave anything in the defaults the real app reads. (`DashboardViewModel`
    /// keeps such an edit for the session on the card, as it always did.)
    func setDueDateEdit(_ date: Date?, for assignment: Assignment) {
        guard !isUsingFixtureData else { return }

        var ids = [assignment.id]
        if let linked = assignment.linkedID { ids.append(linked) }

        var next = dueDateEdits
        if let date, date != assignment.dueAt {
            for id in ids { next[id] = date }
        } else {
            for id in ids { next.removeValue(forKey: id) }
        }
        guard next != dueDateEdits else { return }

        dueDateEdits = next
        dueDateEditStore?.save(next)
        // The widget is a separate process and only knows what the last
        // snapshot said; without this the home screen would show the old date
        // until the next sync or completion happened to rebuild the dashboard.
        publishWidgetSnapshot()
    }

    /// Forgets every edited due date belonging to one recurring task's
    /// occurrences: called when the task is removed (`removeRecurringTask`).
    ///
    /// By key rather than by occurrence, because the task no longer has
    /// occurrences to ask: `upcomingAssignments` only mints the coming weeks, and
    /// an edit on one that has since passed is still stored under its id. An id
    /// belongs to the task when it is in the recurring family and its occurrence
    /// id names the task. Another task's edits, and every other family's, stay.
    func clearDueDateEdits(forRecurringTask taskID: UUID) {
        guard !isUsingFixtureData else { return }
        let kept = dueDateEdits.filter { entry in
            guard EditSourceFamily(id: entry.key) == .recurring,
                  let colon = entry.key.firstIndex(of: ":")
            else { return true }
            let sourceID = String(entry.key[entry.key.index(after: colon)...])
            return RecurringTask.occurrenceTaskID(fromSourceID: sourceID) != taskID
        }
        guard kept.count != dueDateEdits.count else { return }
        dueDateEdits = kept
        dueDateEditStore?.save(kept)
    }

    /// Drops an edit only when there is positive evidence its item is gone: the
    /// item's own source loaded in this rebuild, and the id is not among what it
    /// loaded.
    ///
    /// `pool` is every raw source the dashboard is built from, before any
    /// display filter, so an item the dashboard is merely hiding (archived,
    /// withheld by the sign-up rule, held for a submission check, in a class the
    /// student unticked, finished) keeps its edit for the day it comes back. Only
    /// an item that has left the ledger altogether (aged out, or its source was
    /// disconnected and purged) loses it, and an edit for work that no longer
    /// exists is the one thing safe to forget.
    ///
    /// "Loaded" is decided per source family (`EditSourceFamily`), and that is
    /// the whole point of the rule. The first version only asked that the pool
    /// be non-empty, and a pool is never empty for a student with one manual task
    /// or a recurring reading, both of which come from defaults, not the ledger.
    /// A launch whose ledger came up empty (it fell back to memory, or has not
    /// finished opening) would then read "Canvas is missing" as "every Canvas
    /// item vanished" and erase every edit the student had made. So an id is
    /// pruned only when its family has at least one item in this pool and the id
    /// is not among them: an edit on a Canvas item goes only when Canvas items
    /// are present and that one is not, and the same for Gradescope, modules,
    /// announcements, manual tasks and recurring occurrences. An id whose family
    /// cannot be told from the id alone (an unknown source prefix, a `.manual`
    /// id that is neither of ours) is kept, since forgetting it would be a guess.
    ///
    /// The cost is a little residue: the edits of a family that is entirely gone
    /// (every Gradescope item after disconnecting Gradescope, say) stay until
    /// that family has items again, and then go. Ids and dates only, never
    /// shown anywhere. The other guards stand: nothing is pruned in fixture
    /// mode, where the pool is the bundled samples rather than the student's
    /// work, or from an empty pool.
    func pruneDueDateEdits(against pool: [Assignment]) {
        guard !isUsingFixtureData, !pool.isEmpty, !dueDateEdits.isEmpty else { return }
        let present = Set(pool.map(\.id))
        let loaded = Set(pool.compactMap { EditSourceFamily(source: $0.source, sourceID: $0.sourceID) })
        let kept = dueDateEdits.filter { entry in
            guard let family = EditSourceFamily(id: entry.key), loaded.contains(family) else {
                return true
            }
            return present.contains(entry.key)
        }
        guard kept.count != dueDateEdits.count else { return }
        dueDateEdits = kept
        dueDateEditStore?.save(kept)
    }
}

/// Which loader an assignment id belongs to, for `pruneDueDateEdits`: the unit
/// in which "this source loaded" is decided.
///
/// Mostly `Assignment.Source`, with the two sources that more than one loader
/// shares split apart. `.manual` is both a student's own task
/// (`ManualAssignment`, `"manual-<UUID>"`) and a recurring task's generated
/// occurrence (`"<UUID>-<epoch>"`), and the two come from different places, so
/// the presence of one is no evidence about the other. `.canvasSuggestion` is
/// minted only by `RecurringTask`, so it is `.recurring` outright (see the note
/// above `RecurringTask.occurrenceSourceID`). An id carries its source as the
/// text before the first `:` (`Assignment.id`), and nothing about its source
/// beyond that, which is why the shape of a `.manual` id is the only thing read
/// from the rest of it.
private enum EditSourceFamily: Hashable {
    case canvas, gradescope, canvasModules, canvasAnnouncement, manual, recurring

    /// Nil when the family cannot be told, which the pruner treats as "keep".
    init?(source: Assignment.Source, sourceID: String) {
        switch source {
        case .canvas:             self = .canvas
        case .gradescope:         self = .gradescope
        case .canvasModules:      self = .canvasModules
        case .canvasAnnouncement: self = .canvasAnnouncement
        case .canvasSuggestion:   self = .recurring
        case .manual:
            if RecurringTask.occurrenceTaskID(fromSourceID: sourceID) != nil {
                self = .recurring
            } else if sourceID.hasPrefix(ManualAssignment.sourceIDPrefix) {
                self = .manual
            } else {
                return nil
            }
        }
    }

    /// From a stored id, `"<source raw value>:<sourceID>"`. Nil for an id with no
    /// `:` or a source this build does not know (an edit written by a newer
    /// build, say), so such an edit is always kept.
    init?(id: String) {
        guard let colon = id.firstIndex(of: ":"),
              let source = Assignment.Source(rawValue: String(id[..<colon]))
        else { return nil }
        self.init(source: source, sourceID: String(id[id.index(after: colon)...]))
    }
}
