import Foundation
import LowHangingFruitKit

/// When the dashboard tells the student that nothing is being saved.
///
/// The ledger (`AssignmentStore`) is the student's own record of their work:
/// assignments, completions, grades, manual tasks. It has two quiet ways to
/// stop persisting, and neither shows anywhere on a normal-looking screen:
///
/// - It opened as the in-memory fallback (`isPersistent == false`): the App
///   Group container was missing or the on-disk store would not open, so
///   everything lives until the app quits.
/// - It is on disk but its most recent write failed (`lastSaveError != nil`):
///   a full disk, or protected data not yet available. The store clears that
///   error on the next save that lands, so this reads "failing now", not
///   "failed once this session".
///
/// Either way the student's ticked-off work is gone on relaunch while the
/// list looks fine, which is the worst kind of failure for an app whose whole
/// promise is that nothing the student did is ever lost. A "storage" section
/// in Settings used to show this; it dropped out in a Settings merge, so
/// nothing warned anyone (CLAUDE.md, Known gaps).
///
/// Pure and `nonisolated` so a test can walk the truth table without a
/// store, and so no actor is inherited by a rule that is only booleans
/// (CLAUDE.md, the `decidedText` trap).
enum StorageHealth {
    /// - Parameters:
    ///   - isFixtureData: Preview mode (the App Review path) or the DEBUG
    ///     `-LHFDemoData` seam. Both run on bundled sample data against a
    ///     throwaway ledger by design, so "not saving" would be true and would
    ///     be noise, and a reviewer must never be shown it.
    ///   - isPersistent: `AssignmentStore.isPersistent`.
    ///   - lastSaveFailed: `AssignmentStore.lastSaveError != nil`.
    nonisolated static func showsNotSavingBanner(isFixtureData: Bool,
                                                 isPersistent: Bool,
                                                 lastSaveFailed: Bool) -> Bool {
        guard !isFixtureData else { return false }
        return !isPersistent || lastSaveFailed
    }

    /// How many times each store failed this session, by direction.
    ///
    /// The banner above is a verdict about writing: nothing is being kept. A
    /// ledger that cannot be *read* is a different fact, and it used to leave no
    /// trace at all, because the store answered a failed fetch as an empty one
    /// (hardening plan 2026-10-25, B6). This is the read-side counterpart, kept
    /// as counts rather than a second verdict. Whether a failed read should also
    /// raise the banner is a product decision that was not made here: its text
    /// says "not saving", which is not what a failed read means, and no new
    /// words were allowed.
    ///
    /// Plain `Sendable` values so a test can build one and a rule over it needs
    /// no store and no actor (CLAUDE.md, the `decidedText` trap).
    struct Failures: Sendable, Equatable {
        var ledgerReads = 0
        var ledgerSaves = 0
        /// Grade history (`GradeHistoryStore`). A history file that could not
        /// be opened at launch counts as one failed read: the store then runs
        /// in memory, which is the load failing, not a fetch failing.
        var historyReads = 0
        var historySaves = 0

        /// Failed fetches across every store.
        nonisolated var reads: Int { ledgerReads + historyReads }
        /// Failed writes across every store.
        nonisolated var saves: Int { ledgerSaves + historySaves }
        nonisolated var isClean: Bool { reads == 0 && saves == 0 }
    }
}

extension AppState {
    /// Whether the dashboard shows "not saving on this phone". See
    /// `StorageHealth`. A missing ledger (`assignmentStore == nil`, only if
    /// even the in-memory store could not be built) reads false: that path
    /// degrades to the pre-ledger defaults persistence, which does save.
    ///
    /// Read from the dashboard's `body`, so it refreshes whenever the screen
    /// re-renders (every sync, every completion, every return from another
    /// screen) rather than the instant a write fails; the store is not
    /// observable and this does not pretend otherwise.
    var showsNotSavingBanner: Bool {
        guard let store = assignmentStore else { return false }
        return StorageHealth.showsNotSavingBanner(isFixtureData: isUsingFixtureData,
                                                  isPersistent: store.isPersistent,
                                                  lastSaveFailed: store.lastSaveError != nil)
    }

    /// What the stores have failed to read or write this session. See
    /// `StorageHealth.Failures`. Session counts, not "failing now": a read that
    /// failed once and then succeeded still shows, which is the point of
    /// counting. Nothing reads it in a release build yet.
    var storageFailures: StorageHealth.Failures {
        let history = gradeHistoryStore
        return StorageHealth.Failures(
            ledgerReads: assignmentStore?.failedReadCount ?? 0,
            ledgerSaves: assignmentStore?.failedSaveCount ?? 0,
            historyReads: (history?.failedReadCount ?? 0) + (history?.storageFailureReason == nil ? 0 : 1),
            historySaves: history?.failedSaveCount ?? 0)
    }
}
