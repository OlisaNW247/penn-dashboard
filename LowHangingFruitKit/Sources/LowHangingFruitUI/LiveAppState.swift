import Foundation

/// Which `AppState` the running process already owns, for code that has no
/// view hierarchy to reach it through: the background wake.
///
/// **Why it exists (hardening plan B13, DAT-04, UCR-6, SYN-11).**
/// `AppState.init` opens the SwiftData ledger (`AssignmentStore`), and the
/// ledger is a `ModelContainer` on one file in the App Group container. The
/// scene (`LHFScenes`) opens it once at launch. A background wake in a process
/// that is already running, which is what iOS does to an app that was only
/// suspended, used to build a second `AppState` and so a second container on
/// the same file, inside the same process, with both able to write. Nothing in
/// the app is written for two writers on one store: `reconcile` upserts from
/// each one's own in-memory picture of the ledger, so a completion one of them
/// recorded can be overwritten by the other's next save. In a warm process the
/// wake now works on the scene's own `AppState` and so its own store. A second
/// one is opened only when the process has none, which is a cold launch by the
/// system for the wake alone, where there is no other writer to disagree with.
///
/// **Weak, deliberately.** The registry never keeps an `AppState` alive: the
/// scene owns it, and a registry that held it would outlive a scene that had
/// let it go and hand a wake an object nothing else was updating. When the
/// scene's is gone the registry reads as empty and the wake opens its own.
///
/// An instance, not a static, so a test builds its own and never sees another
/// test's `AppState`; the app uses `shared`.
@MainActor
final class LiveAppStateRegistry {
    static let shared = LiveAppStateRegistry()

    init() {}

    private weak var live: AppState?

    /// The scene's `AppState`, if the process has one.
    var current: AppState? { live }

    /// Records `state` as the process's live one.
    func register(_ state: AppState) { live = state }

    /// Builds the scene's `AppState` and records it. This is what
    /// `LHFScenes` and `OwnedRootView` hand to their `@StateObject`, so the
    /// registry is filled the moment the state exists, whether or not a window
    /// ever appears (a background launch builds the scene without one).
    /// `make` is a parameter so a test need not open a real store.
    func makeLive(_ make: () -> AppState = { AppState() }) -> AppState {
        let state = make()
        live = state
        return state
    }

    /// What `LHFBackgroundRefresh.run()` works on: the live `AppState` when
    /// there is one, otherwise one of its own from `makeOwn`, in either case
    /// already marked as a background context. Synchronous, and sets the
    /// context before returning, so nothing on the main actor can run between
    /// the state existing and its being marked (a renewal task a fresh
    /// `AppState.init` queued included): every renewal the wake makes is
    /// `.background` (no latching dead, no credential offer once Duo has
    /// asked, a short budget).
    func beginWake(makeOwn: () -> AppState = { AppState() }) -> Wake {
        let state = live ?? makeOwn()
        let wake = Wake(state: state, isShared: state === live, restoreContext: state.renewalContext)
        state.renewalContext = .background
        return wake
    }

    /// A wake's hold on an `AppState`.
    @MainActor
    struct Wake {
        let state: AppState
        /// True when `state` is the live app's own, so the wake opened no
        /// second ledger.
        let isShared: Bool
        fileprivate let restoreContext: AppState.RenewalContext

        /// Puts the context back as it was. **Required for a shared state**:
        /// it is the live app's, and left at `.background` it would refuse
        /// every foreground renewal and device sync from then on
        /// (`retrySilentRenewalIfDue`, `deviceSyncPass`). Harmless for the
        /// wake's own, which is dropped.
        func end() { state.renewalContext = restoreContext }
    }
}
