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
                            await state.syncIfConfigured()
                            await AutoSyncCoordinator.syncConnectedServices(state: state)
                        }
                }
            }
            .frame(minWidth: 720, minHeight: 480)
        }
    }
}
