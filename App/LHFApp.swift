import SwiftUI
import LowHangingFruitUI
#if canImport(AlarmKit) && os(iOS)
import AlarmKit
import AppIntents
#endif

/// The shippable iOS/macOS app entry point. All UI lives in the
/// `LowHangingFruitUI` Swift package; this target just owns `@main`.
///
/// Background refresh (docs/BACKGROUND_REFRESH_PLAN.md, Option A) is wired
/// up here: `BGTaskScheduler` registration must happen before the app
/// finishes launching, and a fresh request must be queued every time the
/// app leaves the foreground (submitted requests don't persist forever).
/// `BackgroundTasks` isn't available to macOS, so every call into
/// `LHFBackgroundRefresh` sits behind `#if canImport(BackgroundTasks) && os(iOS)` —
/// `scenePhase` itself is fine unguarded on both platforms.
@main
struct LHFApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // On both platforms, and here rather than from a view or the
        // scheduler: a tap on a loud alert's button can be what launches the
        // app, and iOS delivers that response only to a delegate (and
        // categories) in place before launch finishes. See
        // `LoudAlertActions.categories`.
        NotificationResponseRouter.install()
        #if canImport(AlarmKit) && os(iOS)
        // Berserk mode: hand the package the two intents below, which only
        // this target can define (see `BerserkAlarmIntents`). Without this
        // the loud alert stays the three buzzes.
        if #available(iOS 26.0, *) {
            BerserkAlarmIntents.factory = { button, alarmID, assignmentID, url in
                switch button {
                case .stop:
                    return BerserkStopAlarmIntent(alarmID: alarmID.uuidString,
                                                  assignmentID: assignmentID,
                                                  url: url?.absoluteString ?? "")
                case .turnedIn:
                    return BerserkTurnedInAlarmIntent(alarmID: alarmID.uuidString,
                                                      assignmentID: assignmentID)
                }
            }
        }
        #endif
        #if canImport(BackgroundTasks) && os(iOS)
        LHFBackgroundRefresh.register()
        LHFBackgroundRefresh.scheduleNext()
        #endif
    }

    var body: some Scene {
        // `LHFScenes` (docs/LAPTOP_INTEGRATION_PLAN.md Tier 1) owns the main
        // `WindowGroup` plus, on macOS, the menu-bar extra — both sharing one
        // `AppState`/`NotificationScheduler` pair. The scenePhase wiring below
        // is unchanged from when this modifier lived on `RootView()` itself;
        // `.onChange(of:)` on a `Scene` behaves the same way and now covers
        // every scene `LHFScenes` contains.
        LHFScenes()
            .onChange(of: scenePhase) { _, newPhase in
                #if canImport(BackgroundTasks) && os(iOS)
                if newPhase == .background {
                    LHFBackgroundRefresh.scheduleNext()
                }
                #endif
            }
    }
}

#if canImport(AlarmKit) && os(iOS)

// MARK: - Berserk alarm buttons
//
// The loud 10-minute alert on iOS 26 is an AlarmKit alarm with two buttons,
// and these are what they run (`BerserkAlarmPlan` has the rules and the
// tests). They live here, in the App target, and not in the package: an App
// Intent has to be in a target the build extracts App Intents metadata from,
// and a static Swift package linked into the app may not get that, in which
// case the system could not run the intent when a button is pressed.
//
// **The mapping is deliberate: stop is never "turned in".** AlarmKit's FAQ says
// the stop intent also runs when the alarm is swiped away or the side button
// is pressed, so stop cannot mean something the student might not have chosen.
// If it marked work done, silencing an alarm would mark unsubmitted work done.
// Stop opens the item's page; only the secondary button, labelled "turned in",
// reports the work handed in, and even then the dashboard ticks it only against
// a matching active item (`LoudAlertActions.disposition`).
//
// Both open the app (`supportedModes`, not the deprecated `openAppWhenRun`) so
// the dashboard, which the student can see, does the work, and both stop their
// own alarm first, since a custom button does not stop it by itself.

/// The stop button of an alarm whose item has a page: stops the alarm and
/// opens the page. An alarm for an item with no page is given no stop intent
/// at all, so stopping it only stops it.
@available(iOS 26.0, *)
struct BerserkStopAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String
    @Parameter(title: "Assignment")
    var assignmentID: String
    @Parameter(title: "Page")
    var url: String

    init() {
        alarmID = ""
        assignmentID = ""
        url = ""
    }

    init(alarmID: String, assignmentID: String, url: String) {
        self.alarmID = alarmID
        self.assignmentID = assignmentID
        self.url = url
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        NotificationResponseRouter.receiveAlarmAction(.stop, assignmentID: assignmentID, url: url)
        return .result()
    }
}

/// The secondary button, "turned in": stops the alarm and reports the work
/// handed in. The only path in the alarm feature that can mark anything done.
@available(iOS 26.0, *)
struct BerserkTurnedInAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Turned in"
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String
    @Parameter(title: "Assignment")
    var assignmentID: String

    init() {
        alarmID = ""
        assignmentID = ""
    }

    init(alarmID: String, assignmentID: String) {
        self.alarmID = alarmID
        self.assignmentID = assignmentID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) { try? AlarmManager.shared.stop(id: id) }
        NotificationResponseRouter.receiveAlarmAction(.turnedIn, assignmentID: assignmentID, url: "")
        return .result()
    }
}

#endif
