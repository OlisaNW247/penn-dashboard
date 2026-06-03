import SwiftUI

@main
struct LowHangingFruitApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Low Hanging Fruit") {
            Group {
                if state.needsOnboarding {
                    OnboardingView()
                        .environmentObject(state)
                } else {
                    ContentView()
                        .environmentObject(state)
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
}
