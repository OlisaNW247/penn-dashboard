import SwiftUI
import LowHangingFruitKit

/// Compatibility name for callers and previews that still refer to ProfileView.
/// Profile and Settings were merged into one compact destination; SettingsPage
/// owns that form so the old settings screenshot route lands on the same screen.
struct ProfileView: View {
    var body: some View {
        SettingsPage()
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ProfileView()
            .environmentObject(AppState())
            .environmentObject(NotificationScheduler())
    }
}
#endif
