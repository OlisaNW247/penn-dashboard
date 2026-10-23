import Foundation
import CryptoKit
import LowHangingFruitKit

// Berserk mode, the pure half.
//
// The owner's decision (2026-10-19): on iOS 26, when the student has allowed
// AlarmKit, the loud 10-minute alert is ONE real alarm at due minus 10 minutes
// instead of three Time Sensitive notifications 3 seconds apart. It takes over
// the screen and rings through silent mode and Focus, which a notification
// cannot do. Below iOS 26, on a Mac, or when alarms are not allowed, the three
// buzzes stay exactly as they were.
//
// Everything in this file is plain values and `nonisolated` functions, so the
// whole rule set is tested on macOS without AlarmKit (an iOS 26 framework, and
// `AlarmManager` is off limits to a test binary anyway). The framework calls
// are in `BerserkAlarmScheduler.swift`, behind `#if canImport(AlarmKit)`.

/// The two buttons of an alarm. Public because `App/LHFApp.swift`, which owns
/// the App Intents (see `BerserkAlarmIntents`), has to say which one it was.
public enum BerserkAlarmButton: Equatable, Sendable {
    /// AlarmKit's stop button: opens the item's page, or only stops.
    case stop
    /// The secondary button, "turned in".
    case turnedIn
}

/// How the loud alert reaches the student on this reschedule.
enum LoudAlertDelivery: Equatable, Sendable {
    /// One AlarmKit alarm per item; no loud buzzes.
    case alarms
    /// Three Time Sensitive notifications per item, as before.
    case buzzes
}

/// What `AlarmManager` says about permission, plus the one outcome it has no
/// case for: the request itself failing.
enum BerserkAlarmAuthorization: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    /// `requestAuthorization()` threw. Treated like a refusal.
    case failed
}

/// One alarm the plan wants scheduled.
struct PlannedAlarm: Equatable, Sendable {
    /// Where the stop button leads, and what it says.
    struct Link: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case canvas
            case gradescope

            /// The card's own label, the one `LoudAlertActions.buttons(for:)`
            /// already reuses for the notification button.
            var label: String {
                switch self {
                case .canvas: return LoudAlertActions.openCanvasTitle
                case .gradescope: return LoudAlertActions.openGradescopeTitle
                }
            }
        }
        let kind: Kind
        let url: URL
    }

    /// Deterministic from (assignment id, fire date); see
    /// `BerserkAlarmPlan.alarmID`.
    let id: UUID
    /// `Assignment.id` of the item.
    let assignmentID: String
    /// Due minus the selected Sweeper lead time.
    let fireDate: Date
    /// The assignment's name, trimmed the way a reminder's body trims it.
    let title: String
    /// The class as the card shows it (`Assignment.displayCourse`, with the
    /// student's renames applied). Drawn by the alarm's Live Activity, which
    /// has no other way to learn it.
    let course: String
    var sound: SweeperSound = .smooth
    /// The Live Activity counts down to the assignment deadline.
    let dueAt: Date
    /// Nil for manual work and Ed finds, which have no page of their own.
    let link: Link?

    /// The stop button's text: the item's link label, or "stop" when it has
    /// no link. Never "turned in" (see `BerserkAlarmPlan`).
    var stopLabel: String { link?.kind.label ?? BerserkAlarmPlan.stopOnlyLabel }
    /// The secondary button's text. Always "turned in".
    var secondaryLabel: String { LoudAlertActions.turnedInTitle }
}

/// What a reconcile does to bring AlarmKit in line with the plan.
struct BerserkAlarmDiff: Equatable {
    var toCancel: [UUID]
    var toSchedule: [PlannedAlarm]
}

/// The Berserk alarm rules: which alarms, their ids, the reconcile diff, the
/// delivery decision, and what each button means.
enum BerserkAlarmPlan {

    // MARK: Buttons

    /// The stop button's text when the item has nothing to open.
    nonisolated static let stopOnlyLabel = "stop"

    /// **The button mapping, and why stop is never "turned in".**
    ///
    /// AlarmKit gives an alarm a stop button and one secondary button. Apple's
    /// AlarmKit FAQ says the stop intent also runs when the alarm is swiped
    /// away or the side button is pressed (developers report that it differs
    /// by OS version). So whatever the stop intent does can happen without the
    /// student ever choosing it: if stop meant "turned in", silencing an
    /// alarm, or just pressing the side button on it, would mark unsubmitted
    /// work done, and the app would then stop warning about it.
    ///
    /// - **Stop** opens the item's page (labelled "open in canvas" / "open in
    ///   gradescope" where the system shows our label) or, for an item with no
    ///   page, only stops. Opening a page is harmless however stop was
    ///   reached.
    /// - **Secondary** is "turned in", with `secondaryButtonBehavior: .custom`
    ///   so it runs our intent and does not start a countdown. It needs a
    ///   deliberate tap on a button that says what it does, and it is the only
    ///   path in this feature that can mark anything done.
    ///
    /// The wrong fix is to follow the notification's layout and make stop
    /// "turned in".
    ///
    /// Pure, so the mapping from a button press to the inbox action is
    /// testable without an App Intent: it goes through the notification
    /// parser (`LoudAlertActions.action`), so an alarm's URL is held to
    /// exactly the rule a notification's is (https with a host, nothing
    /// else), and "turned in" needs a non-empty item id.
    nonisolated static func action(
        for button: BerserkAlarmButton,
        assignmentID: String,
        url: String
    ) -> LoudAlertAction? {
        switch button {
        case .stop:
            return LoudAlertActions.action(
                actionIdentifier: LoudAlertActions.openActionID,
                userInfo: [LoudAlertActions.linkURLKey: url])
        case .turnedIn:
            return LoudAlertActions.action(
                actionIdentifier: LoudAlertActions.turnedInActionID,
                userInfo: [LoudAlertActions.assignmentIDKey: assignmentID])
        }
    }

    // MARK: Planning

    /// One alarm per item of `selection`, whose alarm time is still ahead.
    ///
    /// `selection` is what `NotificationScheduler.loudAlerts` chose, in its
    /// order (see `plannedAlarms`); nothing here re-decides which work
    /// qualifies.
    ///
    /// **"Still ahead" is judged on the alarm time, due minus 10 minutes.**
    /// `loudAlerts` keeps an item for as long as one of its three buzzes is
    /// ahead, which is up to 6 seconds past the first. An alarm has no second
    /// and third: once its time has passed it has fired, and scheduling a
    /// fixed alarm in the past would fail or ring at once. Such an item gets
    /// no alarm now, and still no plain "10 minutes before" reminder
    /// (`plannedRequests` keys that off the selection, not off this).
    ///
    /// The title is the assignment's name with no lead phrase ("Due in 10
    /// minutes" is the alarm's whole meaning, and the screen says when it is),
    /// cut by the same rule a reminder's body uses
    /// (`NotificationScheduler.reminderName`). A blank name falls back to the
    /// class as the card shows it, existing wording, so the alarm is never
    /// untitled.
    nonisolated static func alarms(
        for selection: [DashItem],
        now: Date,
        nameOverrides: [String: String],
        lead: TimeInterval = NotificationScheduler.loudAlertLead,
        sound: SweeperSound = .smooth
    ) -> [PlannedAlarm] {
        selection.compactMap { item in
            guard let due = item.due else { return nil }
            let fire = due.addingTimeInterval(-lead)
            guard fire > now else { return nil }

            let assignment = item.assignment
            let name = NotificationScheduler.reminderName(assignment.title)
            let buttons = LoudAlertActions.buttons(for: assignment)
            let link: PlannedAlarm.Link?
            switch (buttons.categoryID, buttons.url) {
            case (LoudAlertActions.canvasCategoryID, let url?): link = .init(kind: .canvas, url: url)
            case (LoudAlertActions.gradescopeCategoryID, let url?): link = .init(kind: .gradescope, url: url)
            default: link = nil
            }
            return PlannedAlarm(
                id: alarmID(assignmentID: assignment.id, fireDate: fire, sound: sound),
                assignmentID: assignment.id,
                fireDate: fire,
                title: name.isEmpty ? assignment.displayCourse(overrides: nameOverrides) : name,
                course: assignment.displayCourse(overrides: nameOverrides),
                sound: sound,
                dueAt: due,
                link: link)
        }
    }

    // MARK: Identity

    /// A UUID derived from (assignment id, fire date), so planning the same
    /// alarm twice names it twice the same way.
    ///
    /// **Why derived and not random.** A reschedule runs every few minutes and
    /// must be idempotent: with a stable id the reconcile finds the alarm it
    /// scheduled last time and leaves it alone, and with a random one it would
    /// cancel and re-add every alarm on every pass. **Why the fire date is in
    /// it.** If the due date moves, the alarm must move, and the way to move a
    /// fixed alarm is a new one: the old id is no longer wanted, so the
    /// reconcile cancels it. The wrong fix is an id from the assignment alone,
    /// which would leave the old time standing.
    ///
    /// SHA-256 of a length-prefixed name (so no assignment id can run into the
    /// date), truncated to 16 bytes, with the version nibble set to 8 and the
    /// variant to RFC 4122's `10xx`. Version 8 is RFC 9562's "custom"; the
    /// name-based versions in RFC 4122 are 3 (MD5) and 5 (SHA-1), and labelling
    /// a SHA-256 value 5 would be a lie a UUID tool would believe. The date is
    /// taken at millisecond precision so floating-point noise in a parsed date
    /// cannot rename an alarm.
    ///
    /// **Why the namespace says `v2`.** Alarms persist in AlarmKit across app
    /// updates, with the attributes they were scheduled with. An alarm the
    /// previous build scheduled carries the old metadata type (assignment id
    /// and URL only) and would ring without the Live Activity, because the
    /// widget decodes `BerserkAlarmMetadata` with its course, title and due
    /// moment. A new namespace gives every alarm a new id, so the first
    /// reconcile after the update finds the old ids unwanted, cancels them, and
    /// schedules each alarm again once under the new attributes. The wrong fix
    /// is leaving `v1` and hoping the first ring after the update is not the
    /// one that matters: it is the one the student relies on, and it would be
    /// the plain Apple alert. Bump the number again whenever the metadata's
    /// shape changes.
    nonisolated static func alarmID(assignmentID: String, fireDate: Date, sound: SweeperSound = .smooth) -> UUID {
        let millis = Int64((fireDate.timeIntervalSince1970 * 1000).rounded())
        let name = "lhf.berserk-alarm.v2|\(assignmentID.utf8.count)|\(assignmentID)|\(millis)" + (sound == .smooth ? "" : "|\(sound.rawValue)")
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    // MARK: Reconcile

    /// What to cancel and what to schedule so that AlarmKit holds exactly
    /// `desired`.
    ///
    /// An existing alarm whose id the plan does not want is stale: its item was
    /// finished, stopped qualifying, or had its due date moved. A wanted alarm
    /// that already exists is left alone. Duplicates on either side collapse,
    /// and both lists keep their input order so the result is a function of its
    /// inputs.
    ///
    /// Takes ids rather than `Alarm` values because `Alarm` is an iOS 26 type;
    /// the glue decides which existing alarms are offered (it leaves a ringing
    /// one out, see `BerserkAlarmScheduler.reconcile`).
    nonisolated static func reconcile(desired: [PlannedAlarm], existingIDs: [UUID]) -> BerserkAlarmDiff {
        let wanted = Set(desired.map(\.id))
        let present = Set(existingIDs)

        var seenCancel = Set<UUID>()
        let toCancel = existingIDs.filter { !wanted.contains($0) && seenCancel.insert($0).inserted }

        var seenSchedule = Set<UUID>()
        let toSchedule = desired.filter { !present.contains($0.id) && seenSchedule.insert($0.id).inserted }

        return BerserkAlarmDiff(toCancel: toCancel, toSchedule: toSchedule)
    }

    // MARK: Delivery

    /// Alarms when AlarmKit is usable and allowed; the three buzzes in every
    /// other case, including "not asked yet" (the caller asks first, so a
    /// `notDetermined` that reaches here means the question was not or could
    /// not be put) and "the request failed".
    ///
    /// `alarmKitAvailable` means iOS 26 with the App target's intents
    /// registered (`BerserkAlarmIntents.factory`): without them an alarm's
    /// buttons would do nothing, so the buzzes' buttons are the better alert.
    nonisolated static func delivery(
        alarmKitAvailable: Bool,
        authorization: BerserkAlarmAuthorization
    ) -> LoudAlertDelivery {
        guard alarmKitAvailable, authorization == .authorized else { return .buzzes }
        return .alarms
    }

    // MARK: Sound

    /// The alarm's sound file, and the name and extension the main bundle is
    /// asked for it by. One definition for the glue and the tests.
    nonisolated static let alarmSoundFileName = "berserk-alarm.caf"
    nonisolated static let alarmSoundResource = "berserk-alarm"
    nonisolated static let alarmSoundExtension = "caf"

    /// The name to hand AlarmKit's `AlertSound.named(_:)`, or nil to use the
    /// system's default alarm sound: the custom one when its file is in the app
    /// bundle, nothing otherwise.
    ///
    /// **Why the main bundle.** Developer reports are that `named(_:)` finds a
    /// sound reliably in the app's main bundle and not in `Library/Sounds` or
    /// in a Swift package's resource bundle (`Bundle.module`, where
    /// `LowHangingFruitUI`'s own media lives). So the file sits in `App/`, is
    /// listed in the app target's Resources build phase, and the glue checks
    /// `Bundle.main` for it. That check is why this takes a Bool: a build
    /// without the file (a clean checkout, or the file removed before an App
    /// Store archive) falls back to the default sound and still rings, where
    /// naming a missing file might ring silently. Unverified on a device.
    ///
    /// **The sound is copyrighted music the owner chose for his own device
    /// build. It must not ship to the App Store without a licence.** The
    /// owner pushed it to the public repo on 2026-10-19, accepting the
    /// copyright risk himself. Listing it in the app target puts it in
    /// every build of that target, Release and the Mac build included, so it
    /// has to come out of `App/` and the project before an archive. The three
    /// buzz notifications keep the default notification sound.
    nonisolated static func alarmSoundName(fileExists: Bool) -> String? {
        fileExists ? alarmSoundFileName : nil
    }

    // MARK: Preview and demo

    /// Whether any alarm may be scheduled.
    ///
    /// **Preview mode and demo data never ring.** Preview mode is App Review's
    /// way in and shows bundled sample courses with due dates built around
    /// today; the DEBUG `-LHFDemoData` launch seeds the same. An alarm is the
    /// one alert a reviewer cannot dismiss by ignoring a banner, and it is for
    /// work that is not real.
    ///
    /// The input is `AppState.isUsingFixtureData`, the app's one answer to
    /// "is this the student's own data?" (preview mode, or the DEBUG demo
    /// launch argument). It is not a second copy of that logic here: two
    /// copies drift, and the day a third kind of fixture data appears this
    /// rule would silently keep ringing for it. Checked at every reschedule,
    /// and entering preview cancels what is scheduled (`ContentView`). The
    /// wrong fix is to leave the sample items out of the plan: the planner is
    /// handed whatever the dashboard shows.
    nonisolated static func alarmsAllowed(isUsingFixtureData: Bool) -> Bool {
        !isUsingFixtureData
    }

    // MARK: Settling a reschedule

    /// How a reschedule's loud-alert delivery turned out. The input to
    /// `settlement(for:)`.
    enum Outcome: Equatable, Sendable {
        /// Alarms were chosen and AlarmKit took the plan.
        case alarmsReconciled
        /// Alarms were chosen and AlarmKit threw.
        case alarmKitThrew
        /// Alarms were never chosen; the scope says which alarms to take back.
        case buzzes(CancelScope)
    }

    /// Which alarms to cancel when the loud alert is not an alarm.
    enum CancelScope: Equatable, Sendable {
        /// Only alarms that have not started ringing. Anything ringing is a
        /// student mid-decision and is theirs to stop. This is the scope for
        /// an AlarmKit error and for "alarms are not usable right now".
        case idleOnly
        /// Every alarm, ringing or not. Only for the student's own "off":
        /// the loud-alert switch, reminders or notifications off, preview mode,
        /// and alarm permission revoked.
        case everything
    }

    enum AlarmAction: Equatable, Sendable {
        /// The reconcile already did it; nothing more.
        case keep
        case cancelIdle
        case cancelAll
    }

    /// What a reschedule finally does, decided from how delivery turned out.
    struct Settlement: Equatable, Sendable {
        /// Whether the notifications are planned with the loud buzzes left out
        /// (`NotificationScheduler.plannedRequests(loudAlertsAsAlarms:)`).
        let loudAlertsAsAlarms: Bool
        /// What to do with AlarmKit's alarms.
        let alarmAction: AlarmAction
    }

    /// **The invariant: every item the loud alert covers ends up with exactly
    /// one of an alarm or the buzzes**, except when the student switched the
    /// loud alert off, when it ends up with neither. This function is where
    /// that is decided, and the only place: the buzzes are left out only when
    /// AlarmKit really took the alarms, so an AlarmKit error can never leave an
    /// item with neither, and they are put back whenever it did not, so a
    /// failed pass can never leave an item with both (the idle alarms are
    /// cancelled in the same breath).
    ///
    /// The wrong fix is to decide "alarms" up front and keep the buzzes out of
    /// the notifications for that reason alone: a reschedule that is told
    /// alarms are on, and then meets an error, would leave the student with no
    /// alert at all, with nothing to show it.
    nonisolated static func settlement(for outcome: Outcome) -> Settlement {
        switch outcome {
        case .alarmsReconciled:
            return Settlement(loudAlertsAsAlarms: true, alarmAction: .keep)
        case .alarmKitThrew:
            return Settlement(loudAlertsAsAlarms: false, alarmAction: .cancelIdle)
        case .buzzes(.idleOnly):
            return Settlement(loudAlertsAsAlarms: false, alarmAction: .cancelIdle)
        case .buzzes(.everything):
            return Settlement(loudAlertsAsAlarms: false, alarmAction: .cancelAll)
        }
    }

    // MARK: A ringing alarm and a finished item

    /// The ids of the alarms that belong to finished work: for each completed
    /// item with a due time, the id its alarm has (or had) under this plan,
    /// derived exactly as `alarms(for:now:nameOverrides:)` derives it from
    /// (assignment id, effective due date minus the lead).
    nonisolated static func finishedAlarmIDs(from items: [DashItem], lead: TimeInterval = NotificationScheduler.loudAlertLead, sound: SweeperSound = .smooth) -> Set<UUID> {
        Set(items.compactMap { item in
            guard item.isCompleted, let due = item.due else { return nil }
            return alarmID(assignmentID: item.assignment.id,
                           fireDate: due.addingTimeInterval(-lead), sound: sound)
        })
    }

    /// Which of the alarms ringing right now to stop: those whose id is in
    /// `finished`, and no others.
    ///
    /// A ringing alarm is a student mid-decision, and nothing may silence it
    /// but a reason the student gave: here, ticking the item off on the
    /// dashboard (or "turned in" on the alarm, which stops its own alarm). An
    /// alarm that is ringing for any other reason, including one for an item
    /// the plan no longer wants and one that AlarmKit just threw about, rings
    /// on.
    nonisolated static func alertingIDsToStop(alerting: [UUID], finished: Set<UUID>) -> [UUID] {
        var seen = Set<UUID>()
        return alerting.filter { finished.contains($0) && seen.insert($0).inserted }
    }
}
