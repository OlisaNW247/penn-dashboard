import WidgetKit
import SwiftUI

@main
struct LHFWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextDueWidget()
        // Berserk mode's alarm Live Activity (iOS 26 only; the extension's
        // deployment target is iOS 17). `WidgetBundleBuilder` accepts an
        // availability check.
        if #available(iOS 26.0, *) {
            BerserkAlarmActivity()
        }
    }
}
