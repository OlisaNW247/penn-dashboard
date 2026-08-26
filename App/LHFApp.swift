import SwiftUI
import LowHangingFruitUI

/// The shippable iOS/macOS app entry point. All UI lives in the
/// `LowHangingFruitUI` Swift package; this target just owns `@main`.
///
/// Background refresh (docs/BACKGROUND_REFRESH_PLAN.md, Option A) is wired
/// up here: `BGTaskScheduler` registration must happen before the app
/// finishes launching, and a fresh request must be queued every time the
/// app leaves the foreground (submitted requests don't persist forever).
/// `BackgroundTasks` isn't available to macOS, so every call into
/// `LHFBackgroundRefresh` sits behind `#if canImport(BackgroundTasks) && os(iOS)` —
/// `scenePhase` itself is fine unguarded on both platforms.
@main
struct LHFApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if canImport(BackgroundTasks) && os(iOS)
        LHFBackgroundRefresh.register()
        LHFBackgroundRefresh.scheduleNext()
        #endif
    }

    var body: some Scene {
        // `LHFScenes` (docs/LAPTOP_INTEGRATION_PLAN.md Tier 1) owns the main
        // `WindowGroup` plus, on macOS, the menu-bar extra — both sharing one
        // `AppState`/`NotificationScheduler` pair. The scenePhase wiring below
        // is unchanged from when this modifier lived on `RootView()` itself;
        // `.onChange(of:)` on a `Scene` behaves the same way and now covers
        // every scene `LHFScenes` contains.
        LHFScenes()
            .onChange(of: scenePhase) { _, newPhase in
                #if canImport(BackgroundTasks) && os(iOS)
                if newPhase == .background {
                    LHFBackgroundRefresh.scheduleNext()
                }
                #endif
            }
    }
}
