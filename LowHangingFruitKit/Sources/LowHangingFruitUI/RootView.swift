import SwiftUI

/// The shared root content: splash, onboarding/intro, or the dashboard,
/// depending on `state`. Extracted out of `RootView` so `LHFScenes` (the
/// macOS-aware `@main` entry, see `LHFScenes.swift`) can hand it an
/// `AppState`/`NotificationScheduler` pair that lives at the *Scene* level —
/// above any individual `WindowGroup` — rather than one scoped to a single
/// window. That's what lets the menu-bar extra and the main window share one
/// `AppState` instead of each spinning up its own.
///
/// `state`/`scheduler` are `@ObservedObject` here (not owned) precisely so
/// this view has no opinion about who creates them or how long they live —
/// see `OwnedRootView` below and `LHFScenes` for the two current owners.
struct RootCore: View {
    @ObservedObject var state: AppState
    @ObservedObject var scheduler: NotificationScheduler

    /// Skip the splash in demo/screenshot mode so captures land on the app.
    /// A default expression (rather than a custom `init`) keeps this struct's
    /// memberwise initializer intact for callers that only care about
    /// `state`/`scheduler`.
    @State private var showSplash: Bool = {
        var skip = false
        #if DEBUG
        skip = ProcessInfo.processInfo.arguments.contains("-LHFDemoData")
        #endif
        return !skip
    }()

    var body: some View {
        ZStack {
            mainContent

            if showSplash {
                // isDarkMode is read straight from `state.appearanceMode`
                // (already loaded from UserDefaults in `AppState.init()`),
                // not from `@Environment(\.colorScheme)` — see
                // `SplashView.isDarkMode`'s doc comment for why: this
                // environment key isn't safely readable at the splash's own
                // first render.
                SplashView(isDarkMode: state.appearanceMode == .dark) {
                    // Handoff fade, sped up to match the clip (0.45 / 1.4).
                    withAnimation(.easeOut(duration: 0.32)) { showSplash = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // Applied at the root so both the dashboard and the splash (which
        // lives in this same ZStack, ahead of onboarding/dashboard) pick up
        // the user's Light/Dark choice. Sheets are a separate presentation
        // context that doesn't inherit this automatically — see
        // `SheetTheme.swift`, which re-applies it there.
        .preferredColorScheme(state.appearanceMode.colorScheme)
#if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
#endif
    }

    @ViewBuilder
    private var mainContent: some View {
        if state.needsOnboarding {
            // The mission panes come first on a true first run, then the
            // connect checklist. Nested rather than a sibling `else if` on
            // purpose: the intro is only ever reachable *inside* onboarding, so
            // a Settings reconnect (which clears `hasCompletedOnboarding` but
            // not `hasSeenIntro`) lands on the checklist, not the pitch.
            if state.needsIntro {
                IntroView()
                    .environmentObject(state)
            } else {
                OnboardingView()
                    .environmentObject(state)
            }
        } else {
            ContentView()
                .environmentObject(state)
                .environmentObject(scheduler)
                .task {
                    // Canvas-only: refresh the assignment list from the
                    // (cookieless, self-authenticating) calendar feed.
                    await state.syncIfConfigured()
                }
        }
    }
}

/// The app's root view. The `@main` entry point lives in the Xcode app target
/// (which owns the `WindowGroup`) and simply presents `RootView()`. Keeping the
/// UI in a library lets a real, shippable app target import it.
///
/// This is now a thin compatibility wrapper: the shipping app (`App/LHFApp
/// .swift`) uses `LHFScenes` directly, whose `AppState`/`NotificationScheduler`
/// live at the Scene level so the menu-bar extra can share them with the main
/// window. `RootView` still owns its own pair via `OwnedRootView` below, so
/// previews and any other caller that only wants a single window keep
/// compiling unchanged.
public struct RootView: View {
    public init() {}

    public var body: some View {
        OwnedRootView()
    }
}

/// Owns the `AppState`/`NotificationScheduler` for a standalone `RootView()`.
/// Split out so `RootView` itself can stay a trivial, stable wrapper type.
private struct OwnedRootView: View {
    @StateObject private var state = AppState()
    @StateObject private var scheduler = NotificationScheduler()

    var body: some View {
        RootCore(state: state, scheduler: scheduler)
    }
}
