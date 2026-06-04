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
                        // Concurrent so a slow Canvas fetch doesn't block Gradescope.
                        async let canvas: Void = state.syncIfConfigured()
                        async let services: Void = AutoSyncCoordinator.syncConnectedServices(state: state)
                        _ = await (canvas, services)
                    }
            }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
#endif
    }
}
