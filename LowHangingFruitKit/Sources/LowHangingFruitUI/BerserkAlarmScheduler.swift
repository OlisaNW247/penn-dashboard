#if canImport(AlarmKit) && os(iOS)
import Foundation
import SwiftUI
import ActivityKit
import AlarmKit
import AppIntents
import LowHangingFruitKit

// Berserk mode, the AlarmKit half. iOS 26 only, and not compiled at all for the
// macOS slice `swift test` builds: every AlarmKit, ActivityKit and
// `LiveActivityIntent` reference in this module sits inside this conditional and
// behind `@available(iOS 26.0, *)`. The deployment target is iOS 17.
//
// The rules (which alarms, what ids, the diff, the delivery decision) are in
// `BerserkAlarmPlan.swift` and tested there. Nothing in this file is exercised
// by `swift test`: it needs a device on iOS 26 with the alarm permission given.

/// What the module needs from the App target to build an alarm's buttons.
///
/// **Why a hook and not intents defined here.** An App Intent has to be in a
/// target the build extracts App Intents metadata from, and a static Swift
/// package linked into the app may not get that treatment; the system then
/// cannot run the intent when a button is pressed. So the two intent types are
/// defined in `App/LHFApp.swift`, and the App target hands this module a
/// factory that makes them (`LHFApp.init`). While it is nil, alarms are not
/// offered at all (`BerserkAlarmScheduler.isReady`) and the loud alert stays
/// the three buzzes.
@available(iOS 26.0, *)
public enum BerserkAlarmIntents {
    /// Makes the intent for one button of one alarm: which button, the alarm's
    /// own id (so the intent can stop it), the item's `Assignment.id`, and the
    /// page the stop button opens (nil when the item has none).
    public typealias Factory = @MainActor (
        _ button: BerserkAlarmButton,
        _ alarmID: UUID,
        _ assignmentID: String,
        _ url: URL?
    ) -> any LiveActivityIntent

    @MainActor public static var factory: Factory?
}

enum BerserkAlarmError: Error {
    /// `BerserkAlarmIntents.factory` is nil, so the buttons cannot be made.
    case noIntentFactory
}

/// The loud alert's alarms, through `AlarmManager`.
///
/// A thin layer on purpose: it is the real `BerserkAlarmStore` (four calls)
/// plus authorization, and every decision about what to do with the store is in
/// `BerserkAlarmEngine`, where a test can reach it.
///
/// **Alert presentation only.** The alarm has no countdown and no paused
/// state. Since 2026-10-20 the widget extension does supply a Live Activity
/// for it (`LHFWidget/BerserkAlarmActivity.swift`): not because AlarmKit
/// requires one for an alert-only alarm (it requires one only for the
/// countdown presentation), but so the Dynamic Island and the lock screen
/// card look like Smooth while it rings. The metadata it draws from is
/// `BerserkAlarmMetadata`, in the Kit, which both targets import.
@available(iOS 26.0, *)
@MainActor
final class BerserkAlarmScheduler: BerserkAlarmBackend, BerserkAlarmStore {
    static let shared = BerserkAlarmScheduler()
    private init() {}

    var isReady: Bool { BerserkAlarmIntents.factory != nil }

    // MARK: Authorization

    var authorization: BerserkAlarmAuthorization { Self.map(AlarmManager.shared.authorizationState) }

    func requestAuthorization() async -> BerserkAlarmAuthorization {
        do {
            return Self.map(try await AlarmManager.shared.requestAuthorization())
        } catch {
            return .failed
        }
    }

    private static func map(_ state: AlarmManager.AuthorizationState) -> BerserkAlarmAuthorization {
        switch state {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .failed
        }
    }

    // MARK: BerserkAlarmBackend (the decisions are the engine's)

    func reconcile(_ plan: [PlannedAlarm]) async throws {
        try await BerserkAlarmEngine.reconcile(plan, in: self)
    }

    func cancelIdle() { BerserkAlarmEngine.cancelIdle(in: self) }

    func cancelAll() { BerserkAlarmEngine.cancelAll(in: self) }

    func stopRinging(among finished: Set<UUID>) {
        BerserkAlarmEngine.stopRinging(among: finished, in: self)
    }

    // MARK: BerserkAlarmStore (AlarmKit, one call each)

    func storedAlarms() throws -> [StoredAlarm] {
        try AlarmManager.shared.alarms.map { StoredAlarm(id: $0.id, isRinging: $0.state == .alerting) }
    }

    func cancel(id: UUID) throws {
        try AlarmManager.shared.cancel(id: id)
    }

    func stop(id: UUID) throws {
        try AlarmManager.shared.stop(id: id)
    }

    func schedule(_ planned: PlannedAlarm) async throws {
        let configuration = try configuration(for: planned)
        _ = try await AlarmManager.shared.schedule(id: planned.id, configuration: configuration)
    }

    // MARK: One alarm

    /// `sending`: the configuration is built from plain values and handed to
    /// `AlarmManager.schedule`, which is not main-actor isolated. Without the
    /// keyword Swift 6 takes a value returned by a main-actor method to belong
    /// to the main actor and refuses to pass it on.
    private func configuration(
        for planned: PlannedAlarm
    ) throws -> sending AlarmManager.AlarmConfiguration<BerserkAlarmMetadata> {
        guard let factory = BerserkAlarmIntents.factory else { throw BerserkAlarmError.noIntentFactory }

        let attributes = AlarmAttributes(
            presentation: presentation(for: planned),
            metadata: BerserkAlarmMetadata(assignmentID: planned.assignmentID,
                                           course: planned.course,
                                           title: planned.title,
                                           dueAt: planned.dueAt,
                                           url: planned.link?.url.absoluteString),
            tintColor: Color.smoothTomato)

        // Stop opens the item's page, and for an item with no page there is
        // nothing to open: no intent at all, so stopping only stops, and
        // never brings the app up for a button that has nothing to show.
        let stopIntent = planned.link.map {
            factory(.stop, planned.id, planned.assignmentID, $0.url)
        }
        let secondaryIntent = factory(.turnedIn, planned.id, planned.assignmentID, planned.link?.url)

        return .alarm(
            schedule: .fixed(planned.fireDate),
            attributes: attributes,
            stopIntent: stopIntent,
            secondaryIntent: secondaryIntent,
            sound: Self.sound())
    }

    /// The owner's custom sound when its file is in the main bundle, the
    /// system alarm sound otherwise (`BerserkAlarmPlan.alarmSoundName` has the
    /// reasoning, including why this is the main bundle and why the file must
    /// not ship without a licence).
    private static func sound() -> AlertConfiguration.AlertSound {
        let file = Bundle.main.url(forResource: BerserkAlarmPlan.alarmSoundResource,
                                   withExtension: BerserkAlarmPlan.alarmSoundExtension)
        if let name = BerserkAlarmPlan.alarmSoundName(fileExists: file != nil) {
            return .named(name)
        }
        return .default
    }

    /// The alert, with no countdown and no paused presentation.
    ///
    /// **The stop button's own text is only honoured on iOS 26.0.** From 26.1
    /// the system draws its own stop control and the SDK says the `stopButton`
    /// argument "will no longer be used", so there the student sees the
    /// system's "Stop" and the label this plan computes (`stopLabel`) never
    /// appears; the stop intent still runs. On 26.0 the label is shown as
    /// planned. The secondary button's text is honoured on both.
    private func presentation(for planned: PlannedAlarm) -> AlarmPresentation {
        let title = Self.resource(planned.title)
        let secondary = AlarmButton(
            text: Self.resource(planned.secondaryLabel),
            textColor: .white,
            systemImageName: "checkmark.circle")

        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(
                title: title,
                secondaryButton: secondary,
                secondaryButtonBehavior: .custom)
        } else {
            let stop = AlarmButton(
                text: Self.resource(planned.stopLabel),
                textColor: .white,
                systemImageName: planned.link == nil ? "stop.fill" : "arrow.up.right")
            alert = AlarmPresentation.Alert(
                title: title,
                stopButton: stop,
                secondaryButton: secondary,
                secondaryButtonBehavior: .custom)
        }
        return AlarmPresentation(alert: alert)
    }

    /// A runtime string as a `LocalizedStringResource`, taken verbatim. Through
    /// an interpolation so the text is an argument and not a lookup key: an
    /// assignment called "100% of grade" must not be read as a format string.
    private static func resource(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource("\(text)")
    }
}
#endif
