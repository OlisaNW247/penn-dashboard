import SwiftUI

@main
struct PennDashboardApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Penn Dashboard") {
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
