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
}
