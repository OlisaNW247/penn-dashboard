#if canImport(BackgroundTasks)
import Foundation
// `@preconcurrency`: BackgroundTasks' ObjC-bridged types (`BGTask`,
// `BGAppRefreshTask`, `BGTaskScheduler`) predate Swift 6's Sendable audits.
// Without this, capturing a `BGAppRefreshTask` across the actor hop below
// (nonisolated launch-handler closure -> `Task { @MainActor in ... }`) risks
// a hard "capture of non-Sendable type" error depending on SDK version; with
// it, an un-audited framework type degrades to a warning instead, which is
// the right trade for a type we only ever touch on the thread the framework
// itself calls us back on.
@preconcurrency import BackgroundTasks

/// Best-effort background refresh (docs/BACKGROUND_REFRESH_PLAN.md, Option A).
/// iOS wakes the app for a short budget at times of its own choosing; when it
/// does, this runs the same sync/notify work `RootView`'s foreground path
/// runs, so "Turned in ✓" and widget freshness aren't gated on the app being
/// opened.
///
/// Public because the App target (which owns `@main`) can only see public API
/// of this module — `AppState`, `NotificationScheduler`, and
/// `AutoSyncCoordinator` are all `internal`, so this enum is the one thing
/// exposed across that boundary. It lives in this module (not the App
/// target) specifically so it CAN reach those internal types directly.
///
/// Entirely behind `#if canImport(BackgroundTasks)`: the macOS slice
/// `swift test` compiles has no BackgroundTasks framework available to the
/// SwiftPM build, so this whole file compiles to nothing there.
public enum LHFBackgroundRefresh {
    /// Must match `project.yml`'s app-target
    /// `BGTaskSchedulerPermittedIdentifiers` entry exactly, or registration
    /// and submission silently fail against each other.
    public static let taskID = "com.lhf.lowhangingfruit.refresh"

    /// Registers the background-refresh handler. Must be called BEFORE the
    /// app finishes launching (Apple's hard requirement — a call from
    /// `sceneDidBecomeActive` or later is a no-op), so `LHFApp.init()` is the
    /// only correct call site.
    ///
    /// `@MainActor` because `register()` itself is only ever called from
    /// `LHFApp.init()` on the main actor; the launch-handler closure passed
    /// to `BGTaskScheduler` below is a separate, ordinary (non-isolated)
    /// closure — the system can invoke it on a background queue, so actor
    /// hops for the real work happen explicitly inside `handle(_:)`, not by
    /// relying on this function's own isolation.
    @MainActor
    public static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    /// Submits the next background-refresh request. Idempotent: submitting
    /// again for the same identifier before a previous request has fired
    /// simply replaces it (the latest submission wins), so calling this from
    /// `LHFApp.init()`, every backgrounding, AND every background wake is
    /// harmless rather than something that needs de-duplicating by hand.
    /// `earliestBeginDate` is a floor, not a promise — iOS may run this much
    /// later than 15 minutes, or, on an infrequently-used app, not at all.
    public static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs one background wake. Not actor-isolated itself — the system may
    /// invoke the launch handler (and thus this) on a background queue — so
    /// all actor-isolated work is wrapped in an explicit `Task { @MainActor
    /// in ... }` rather than relying on inferred isolation.
    ///
    /// Apple's contract is that `setTaskCompleted` is called EXACTLY once
    /// per task, from both the success path and `expirationHandler`.
    /// `didComplete` guards against calling it twice if expiration fires
    /// while (or just after) the work finishes. It's `nonisolated(unsafe)`
    /// because both places that touch it — the `Task`'s body below and
    /// `expirationHandler` — are themselves hopped onto the main actor, so
    /// they can't run concurrently with each other even though the compiler,
    /// looking only at this non-isolated function, can't see that; the
    /// annotation says "trust the construction below," not "ignore the
    /// race."
    private static func handle(_ task: BGAppRefreshTask) {
        nonisolated(unsafe) var didComplete = false

        let work = Task { @MainActor in
            // Schedule the NEXT wake first, before doing any work. If the
            // process crashes or is killed mid-refresh, the chain of future
            // wakes survives that crash instead of silently dying with it.
            scheduleNext()
            await run()
            if !didComplete {
                didComplete = true
                task.setTaskCompleted(success: true)
            }
        }

        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in
                if !didComplete {
                    didComplete = true
                    task.setTaskCompleted(success: false)
                }
            }
        }
    }

    /// The actual refresh, mirroring `ContentView`'s foreground
    /// `announceTurnedIn` drain plus the same sync calls `RootView`'s
    /// `AppState`/`AutoSyncCoordinator` make on launch/activation.
    ///
    /// Builds a FRESH `AppState` and `NotificationScheduler` rather than
    /// reaching for the live UI's instances, for three reasons:
    /// 1. A background launch has no live view hierarchy — `RootView`
    ///    (which owns both as `@StateObject`) may not even exist yet, so
    ///    there is no "the" scheduler to reuse the way the foreground
    ///    convention (a view-owned `NotificationScheduler`) assumes.
    /// 2. `NotificationScheduler` carries no cross-instance state worth
    ///    sharing: its stored properties are UserDefaults-backed
    ///    preferences (re-read on every `init`) plus a live
    ///    authorization-status check (`refreshAuthStatus()`, run per-post)
    ///    — a fresh instance observes exactly what a long-lived one would.
    /// 3. `AppState` hydrates its in-memory pools from the on-disk ledger
    ///    and defaults in `init()`, so a fresh instance here starts from
    ///    the same durable truth the UI's instance did. If the UI's
    ///    `AppState` happens to be alive concurrently (app suspended
    ///    mid-refresh), both are `@MainActor`-isolated and thus serialized
    ///    with respect to each other — never torn — and by existing design
    ///    the UI re-syncs its own instance from the ledger on next
    ///    foreground activation anyway, so it picks up whatever this
    ///    background pass wrote.
    @MainActor
    private static func run() async {
        let state = AppState()
        let scheduler = NotificationScheduler()

        // Fixture/demo/preview data must never trigger real network activity
        // — the foreground path relies on the same guard inside individual
        // `AppState` methods; made explicit here since this entry point has
        // no `ContentView`/`RootView` wrapping it.
        guard !state.isUsingFixtureData else { return }

        await state.syncIfConfigured()
        await AutoSyncCoordinator.syncConnectedServices(state: state)
        await AutoSyncCoordinator.refreshCanvasGrades(state: state)

        // Mirrors `ContentView.announceTurnedIn`: clear-then-post, so a
        // notice can't be posted twice even if this pass were somehow
        // re-entered.
        let notices = state.pendingTurnedInNotices
        guard !notices.isEmpty else { return }
        state.pendingTurnedInNotices = []
        await scheduler.postTurnedInNotifications(notices)
    }
}
#endif
