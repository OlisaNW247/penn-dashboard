import SwiftUI
import LowHangingFruitKit

@main
struct LowHangingFruitApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Low Hanging Fruit") {
            Group {
                if showOnboarding {
                    OnboardingView()
                        .environmentObject(state)
                } else {
                    ContentView()
                        .environmentObject(state)
                        .task {
                            await state.syncIfConfigured()
                            await AutoSyncCoordinator.syncConnectedServices(state: state)
                        }
                }
            }
#if os(macOS)
            .frame(minWidth: 480, minHeight: 600)
#endif
        }
    }

    /// In DEBUG builds with no real data yet, skip straight to the dashboard so
    /// the redesigned UI is visible immediately on the bundled sample data.
    /// Release builds always honor onboarding.
    private var showOnboarding: Bool {
        #if DEBUG
        if !state.isCanvasConnected && !state.isGradescopeConnected { return false }
        #endif
        return state.needsOnboarding
    }
}
