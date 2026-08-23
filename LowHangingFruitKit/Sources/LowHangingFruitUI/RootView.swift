import SwiftUI

/// The app's three top-level destinations.
///
/// Named cases rather than integer tags so the tab bar, the DEBUG screenshot
/// seam, `ContentView`'s header and the tests all refer to the same thing;
/// `String`-backed so a tag that stops matching shows up as an obviously wrong
/// name in a debugger rather than as a silently inert `2`.
///
/// Grades and the per-course grade report are deliberately **not** here. They
/// are drill-downs from the dashboard — you arrive at them from a specific
/// course or a specific week and you expect a back button — so they stay
/// pushed routes on the dashboard's own stack (`ContentView.DashRoute`).
/// A destination earns a tab when you'd want to jump to it from anywhere;
/// neither of those does.
enum MainTab: String, Hashable, CaseIterable {
    case dashboard
    case profile
    case settings
}

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
            MainTabView()
                .environmentObject(state)
                .environmentObject(scheduler)
        }
    }
}

/// The tab bar, and the only place the app's top-level structure is decided.
///
/// Until v4 the whole app was a single `NavigationStack` and Settings was a
/// push behind a gear icon. That was fine while Settings was the only
/// destination, but Profile — "what classes am I taking, which do I want to
/// see, and how do I want to hear about each one" — is something a student
/// opens on purpose, repeatedly, in the first week of a semester. Burying it
/// one level down behind an icon that reads as "preferences" would be the
/// wrong shape for the most-used setup screen in the app.
///
/// **Every tab gets its own `NavigationStack`.** This is not stylistic. A
/// single stack shared across tabs keeps one `path`, so a push made while the
/// Dashboard tab was showing is still on the stack when you switch to Settings
/// — you get somebody else's screen, and Back takes you somewhere you never
/// were. Three stacks means three independent histories, which is what a tab
/// bar promises. `ContentView` already owns its own stack (it has since the
/// dashboard was the whole app), so it is placed here *unwrapped*; wrapping it
/// again would nest two stacks and break `DashRoute` pushes entirely.
struct MainTabView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler

    /// Lives here rather than in `AppState` on purpose: which tab is showing is
    /// view state for one session, not a user preference worth persisting to
    /// disk and migrating forever. Launching on the dashboard is right every
    /// time — it's the screen that answers "what do I owe today".
    @State private var selection: MainTab = .dashboard

    var body: some View {
        TabView(selection: $selection) {
            // Unwrapped: ContentView brings its own NavigationStack. See the
            // type's doc comment.
            ContentView(selectedTab: $selection)
                .tabItem { Label("Dashboard", systemImage: "checklist") }
                .tag(MainTab.dashboard)

            NavigationStack {
                ProfileView()
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(MainTab.profile)

            NavigationStack {
                SettingsPage()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(MainTab.settings)
        }
        // The tab bar is chrome the system draws, so it takes the system tint
        // unless told otherwise; the rest of the app tints controls with the
        // v2 blue (see `SheetTheme`) and a stock iOS blue underneath a warm
        // greige app reads as somebody else's UI.
        //
        // Deliberately no height, padding or font override anywhere in here.
        // A tab bar is one of the few pieces of chrome that resizes itself
        // correctly for accessibility text sizes — at the largest ones iOS
        // drops the labels and shows the icons alone — and every hardcoded
        // dimension is a way to take that away.
        .tint(Color.v2SpineBlue)
        .task {
            // Canvas-only: refresh the assignment list from the (cookieless,
            // self-authenticating) calendar feed. Lives on the tab container
            // rather than on the dashboard tab so it fires once at the
            // onboarding -> app handoff, not again every time the student
            // comes back to the dashboard from Profile.
            await state.syncIfConfigured()
        }
    }
}
