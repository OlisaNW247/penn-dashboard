import WidgetKit
import SwiftUI
import ActivityKit
import AlarmKit
import LowHangingFruitKit

// Berserk mode's Live Activity: what the lock screen and the Dynamic Island
// show while a Berserk alarm is ringing, drawn as Smooth and not as Apple's
// default alarm card.
//
// The alarm itself (the full-screen alert with its "Stop" and "turned in"
// buttons) is the system's and is scheduled by the app
// (`BerserkAlarmScheduler`). This file only skins the Live Activity that
// AlarmKit starts alongside it. It has no buttons and no tap URL of its own
// on purpose: the two App Intents live in the App target, which a widget
// extension cannot reach, and the system alert already carries both buttons.
// A tap on the activity opens the app, which is the default.
//
// The attributes type is `AlarmAttributes<BerserkAlarmMetadata>`, and
// `BerserkAlarmMetadata` is defined in the Kit (not the UI module, which this
// target does not link) so the app and this extension decode the same thing.
//
// iOS 26 only, like AlarmKit; the extension's deployment target is iOS 17, so
// every declaration here carries the availability and the bundle adds the
// activity under an `#available` check.

/// Smooth's tomato, #F07256. Mirrors `Color.smoothTomato` in the UI module,
/// which the widget extension cannot import; keep the two in step by hand.
/// `Color(hex:)` is the widget's own duplicate in `NextDueWidgetViews.swift`.
private let berserkTomato = Color(hex: 0xF07256)

@available(iOS 26.0, *)
struct BerserkAlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<BerserkAlarmMetadata>.self) { context in
            // Lock screen and banner presentation.
            BerserkAlarmBanner(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(berserkTomato)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let metadata = BerserkAlarmContent.metadata(of: context.attributes)
            let soon = BerserkAlarmContent.isSoon(context.state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BerserkAlarmHeading(attributes: context.attributes, lineLimit: 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BerserkAlarmCountdown(dueAt: metadata?.dueAt, soon: soon)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                }
            } compactLeading: {
                Image(systemName: "bell.fill")
                    .foregroundStyle(berserkTomato)
            } compactTrailing: {
                BerserkAlarmCountdown(dueAt: metadata?.dueAt, soon: soon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(berserkTomato)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "bell.fill")
                    .foregroundStyle(berserkTomato)
            }
        }
    }
}

/// What the views read out of an alarm's attributes and state.
@available(iOS 26.0, *)
private enum BerserkAlarmContent {
    // Two overloads, on purpose. The SDK's `AlarmAttributes.metadata` may be
    // declared as `Metadata?` or as `Metadata` and this file cannot be
    // compiled where it was written; overload resolution picks whichever
    // matches the declaration, so the file builds either way.
    private static func unwrap(_ metadata: BerserkAlarmMetadata) -> BerserkAlarmMetadata? { metadata }
    private static func unwrap(_ metadata: BerserkAlarmMetadata?) -> BerserkAlarmMetadata? { metadata }

    static func metadata(of attributes: AlarmAttributes<BerserkAlarmMetadata>) -> BerserkAlarmMetadata? {
        unwrap(attributes.metadata)
    }

    /// Our alarms are fixed-time alerts with no countdown or paused state, so
    /// the alert is the one that is ever seen. The other two modes still draw
    /// the same card, with "soon" where the timer would be. Payload-less
    /// patterns, so this compiles whether or not a case carries a value.
    static func isSoon(_ state: AlarmPresentationState) -> Bool {
        switch state.mode {
        case .countdown: return true
        case .paused: return true
        default: return false
        }
    }
}

/// The live countdown to the due moment; "due now" once it has passed, and
/// "soon" for the modes a fixed alarm never reaches, or when the metadata did
/// not decode.
@available(iOS 26.0, *)
private struct BerserkAlarmCountdown: View {
    let dueAt: Date?
    let soon: Bool

    var body: some View {
        if let dueAt, !soon {
            if dueAt > Date.now {
                Text(timerInterval: Date.now...dueAt, countsDown: true)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
            } else {
                Text("due now")
            }
        } else {
            Text("soon")
        }
    }
}

/// The class (secondary) over the assignment's name (bold). When the metadata
/// did not decode, only the alert's own title, which is the assignment's name.
@available(iOS 26.0, *)
private struct BerserkAlarmHeading: View {
    let attributes: AlarmAttributes<BerserkAlarmMetadata>
    let lineLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let metadata = BerserkAlarmContent.metadata(of: attributes) {
                Text(metadata.course)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Text(metadata.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(lineLimit)
            } else {
                Text(attributes.presentation.alert.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(lineLimit)
            }
        }
    }
}

/// The lock screen card: a small "Smooth Sweeper" label, the class and the
/// assignment, and the countdown large on the right.
@available(iOS 26.0, *)
private struct BerserkAlarmBanner: View {
    let attributes: AlarmAttributes<BerserkAlarmMetadata>
    let state: AlarmPresentationState

    var body: some View {
        let metadata = BerserkAlarmContent.metadata(of: attributes)
        VStack(alignment: .leading, spacing: 6) {
            Text("Smooth Sweeper")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.8))
            HStack(alignment: .center, spacing: 12) {
                BerserkAlarmHeading(attributes: attributes, lineLimit: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                BerserkAlarmCountdown(dueAt: metadata?.dueAt, soon: BerserkAlarmContent.isSoon(state))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
        }
        .padding(16)
    }
}
