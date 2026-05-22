import SwiftUI

@main
struct PennDashboardApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Penn Dashboard") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 480)
                .task {
                    await state.syncIfConfigured()
                    await AutoSyncCoordinator.syncConnectedServices(state: state)
                }
        }
    }
}
