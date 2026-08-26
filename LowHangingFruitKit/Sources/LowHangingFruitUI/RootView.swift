import SwiftUI

/// The app's root view. The `@main` entry point lives in the Xcode app target
/// (which owns the `WindowGroup`) and simply presents `RootView()`. Keeping the
/// UI in a library lets a real, shippable app target import it.
public struct RootView: View {
    @StateObject private var state = AppState()
    @StateObject private var scheduler = NotificationScheduler()
    @State private var showSplash: Bool

    public init() {
        // Skip the splash in demo/screenshot mode so captures land on the app.
        var skip = false
        #if DEBUG
        skip = ProcessInfo.processInfo.arguments.contains("-LHFDemoData")
        #endif
        _showSplash = State(initialValue: !skip)
    }

    public var body: some View {
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
                    // Canvas-only: refresh from the cookieless calendar feed.
                    // Fires once at the onboarding -> app handoff.
                    await state.syncIfConfigured()
                }
        }
    }
}
