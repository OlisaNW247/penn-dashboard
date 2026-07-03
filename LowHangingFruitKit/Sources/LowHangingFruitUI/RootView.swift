import SwiftUI

/// The app's root view. The `@main` entry point lives in the Xcode app target
/// (which owns the `WindowGroup`) and simply presents `RootView()`. Keeping the
/// UI in a library lets a real, shippable app target import it.
public struct RootView: View {
    @StateObject private var state = AppState()
    @StateObject private var scheduler = NotificationScheduler()

    public init() {}

    public var body: some View {
        Group {
            if state.needsOnboarding {
                OnboardingView()
                    .environmentObject(state)
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
#if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
#endif
    }
}
