import SwiftUI
import LowHangingFruitUI

/// The shippable iOS/macOS app entry point. All UI lives in the
/// `LowHangingFruitUI` Swift package; this target just owns `@main`.
@main
struct LHFApp: App {
    var body: some Scene {
        WindowGroup("Low Hanging Fruit") {
            RootView()
        }
    }
}
