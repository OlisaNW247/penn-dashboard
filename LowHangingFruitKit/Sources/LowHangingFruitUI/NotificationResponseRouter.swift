import Foundation
import UserNotifications
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Where taps on a loud alert's buttons wait for the dashboard.
///
/// The delegate callback cannot act on a tap itself: the work (tick the card,
/// re-plan reminders, open a page) belongs to `ContentView`, which owns the
/// view model, and on a cold launch it does not exist yet when the response
/// arrives. So the callback parks the parsed action here, on the main actor,
/// and `ContentView` drains the inbox once its view model is bound and again
/// whenever something new arrives.
///
/// **A queue, not a slot.** A second tap must never overwrite the first: the
/// student who taps "turned in" on two different alerts before the dashboard
/// is up has made two claims, and losing one would leave a finished card open
/// and warning them. Actions are handled in the order they arrived, and a
/// drained action is gone, which is what keeps a re-appearing dashboard from
/// ticking the same card twice.
///
/// **A "turned in" survives the process that received it.** The queue used to
/// live only in memory, so a tap that arrived and was not drained before the
/// process died (a launch that crashed before the dashboard bound, an alarm
/// button pressed in a background launch that iOS then suspended, the app
/// killed on the lock screen) was simply gone: the card stayed open and the
/// buzzing resumed for work the student had said was handed in (hardening plan
/// 2026-10-25, B10: NOT-09, DAT-18). Every "turned in" is now written to
/// `UserDefaults.lhf` as it arrives and removed when the dashboard drains it,
/// and a new inbox starts from whatever a previous process left (launch), and
/// looks again whenever the app becomes active (foreground).
///
/// Only "turned in" is kept. An "open this page" is a ten-second courtesy
/// (`LoudAlertActions.unexpired` drops it past that), so one that outlived its
/// process would be dropped on the next launch anyway, and it carries a page
/// URL that has no business sitting in defaults. What is stored is the item's
/// id, the same kind of identifier the completion record is keyed by.
///
/// The wrong fix is to write the tap when the dashboard drains it: by then the
/// tap has already survived the only moment it was at risk. The write has to
/// happen at deposit.
@MainActor
final class NotificationActionInbox: ObservableObject {
    /// The one inbox the app uses. Tests build their own. It persists to the
    /// shared defaults outside the test runner, where an inbox that wrote the
    /// shared domain would leave a pending tap for another suite's inbox.
    static let shared = NotificationActionInbox(
        defaults: SharedDefaults.isTestRunner ? nil : .lhf,
        observesForeground: !SharedDefaults.isTestRunner
    )

    /// Where "turned in" taps wait. A JSON array of `PersistedTap`.
    static let persistedTapsKey = "pendingTurnedInTapsV1"

    /// One stored "turned in": the item and the moment of the tap.
    private struct PersistedTap: Codable, Equatable {
        let assignmentID: String
        let arrivedAt: Date
    }

    @Published private(set) var queue: [PendingLoudAlertAction] = []

    /// Where "turned in" taps are kept until drained; nil keeps everything in
    /// memory, which is what a throwaway test inbox wants.
    private let defaults: UserDefaults?

    /// Held for the life of the inbox, which for `shared` is the life of the
    /// process, so it is never removed.
    private var foregroundObserver: (any NSObjectProtocol)?

    /// - Parameters:
    ///   - defaults: Where to keep "turned in" taps between processes. Taps a
    ///     previous process left there are in `queue` from the first moment.
    ///   - observesForeground: Look in `defaults` again whenever the app
    ///     becomes active, for a tap another process wrote while this one
    ///     slept. Off for a test inbox.
    init(defaults: UserDefaults? = nil, observesForeground: Bool = false) {
        self.defaults = defaults
        self.queue = Self.persistedTaps(in: defaults)
            .map { PendingLoudAlertAction(action: .turnedIn($0.assignmentID), arrivedAt: $0.arrivedAt) }
        if observesForeground, defaults != nil { observeForeground() }
    }

    /// Appends `action`, stamped with when the app received it. The nonisolated
    /// delegate callback reaches this with a plain `await`, which hops to the
    /// main actor without the callback ever forming a main-actor closure of its
    /// own. A "turned in" is written to disk before this returns.
    func deposit(_ action: LoudAlertAction, arrivedAt: Date) {
        queue.append(PendingLoudAlertAction(action: action, arrivedAt: arrivedAt))
        persist()
    }

    /// Takes in what the persisted list holds that this inbox does not: a tap a
    /// previous process left, or another process wrote while this one was
    /// asleep. Never removes anything, and never duplicates a tap already
    /// queued. Called when the app becomes active, and by a test.
    func refreshFromDisk() {
        let known = queue
        let fresh = Self.persistedTaps(in: defaults)
            .map { PendingLoudAlertAction(action: .turnedIn($0.assignmentID), arrivedAt: $0.arrivedAt) }
            .filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        // Arrival order, ties kept in the order they were found.
        queue = (known + fresh).enumerated()
            .sorted { ($0.element.arrivedAt, $0.offset) < ($1.element.arrivedAt, $1.offset) }
            .map(\.element)
    }

    private func observeForeground() {
        #if canImport(UIKit)
        let name = UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        let name = NSApplication.didBecomeActiveNotification
        #endif
        #if canImport(UIKit) || canImport(AppKit)
        // Delivered on the main queue, so assuming main-actor isolation is a
        // statement of fact; the closure itself is not main-actor isolated,
        // which is what keeps it clear of the run-time isolation check
        // (CLAUDE.md, "Every background refresh has crashed").
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromDisk() }
        }
        #endif
    }

    private static func persistedTaps(in defaults: UserDefaults?) -> [PersistedTap] {
        guard let data = defaults?.data(forKey: persistedTapsKey),
              let taps = try? JSONDecoder().decode([PersistedTap].self, from: data)
        else { return [] }
        return taps
    }

    /// Writes the "turned in" taps now in `queue`, or removes the key when
    /// there are none, so a drained inbox leaves nothing behind.
    private func persist() {
        guard let defaults else { return }
        let taps = queue.compactMap { pending -> PersistedTap? in
            guard case .turnedIn(let id) = pending.action else { return nil }
            return PersistedTap(assignmentID: id, arrivedAt: pending.arrivedAt)
        }
        guard !taps.isEmpty, let data = try? JSONEncoder().encode(taps) else {
            defaults.removeObject(forKey: Self.persistedTapsKey)
            return
        }
        defaults.set(data, forKey: Self.persistedTapsKey)
    }

    /// Hands over everything still worth doing, oldest first, and empties the
    /// queue (`LoudAlertActions.unexpired` drops a stale "open").
    ///
    /// **Takes nothing until the dashboard is bound.** `ContentView` calls this
    /// from `.onChange` as well as from `.onAppear`, and a tap that lands
    /// between the view's first render and the `vm.bind(to:)` in `.onAppear`
    /// would otherwise be drained against an empty `vm.items`. That reads as
    /// "no such item", completes nothing, and then re-plans the reminders from
    /// an empty list, cancelling every one of them: the tap is lost and so is
    /// everything else that was scheduled. Until bound the queue is left
    /// exactly as it is, and the `.onAppear` call that follows the bind
    /// drains whatever is waiting.
    func drain(isDashboardBound: Bool, now: Date) -> [LoudAlertAction] {
        guard isDashboardBound else { return [] }
        let waiting = queue
        queue = []
        // Cleared with the queue, in the same turn the dashboard acts on what
        // this returns, so a drained tap is gone from disk exactly when it is
        // gone from memory and a re-appearing dashboard cannot tick it twice.
        persist()
        return LoudAlertActions.unexpired(waiting, now: now)
    }
}

/// The process-wide notification-center delegate: shows banners while the app
/// is open, and hands a loud alert's button taps to `NotificationActionInbox`.
///
/// **One object, assigned everywhere.** This replaces the private
/// `ForegroundPresentationDelegate` that `NotificationScheduler` used to
/// create and assign lazily, in `requestAuthorization` and in `reschedule`.
/// A delegate assigned there is too late for a button tap that launches the
/// app (see `LoudAlertActions.categories`), and two delegate objects would
/// let the later assignment silently replace the one that routes taps. So
/// `NotificationResponseRouter.install()` assigns this at launch, and the
/// scheduler assigns the same instance wherever it used to assign its own.
///
/// Stateless, so `@unchecked Sendable` is a statement of fact and lets it sit
/// in a `static let`.
final class NotificationResponseDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationResponseDelegate()

    /// How a notification is shown while the app is in the foreground: a
    /// banner, the sound, and a place in Notification Center. Exactly what the
    /// old private delegate returned; the loud alert's wording, sound and
    /// interruption level are untouched by anything in this file. A constant
    /// so a test can pin it without a notification center.
    nonisolated static let foregroundPresentation: UNNotificationPresentationOptions = [.banner, .sound, .list]

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // A loud buzz landing while the app is open is a Berserk takeover.
        // Pure parsing here, then one `await` hop to the main actor: no
        // main-actor closure is formed in this callback (see `didReceive`).
        // This one stays the async form: only `didReceive`'s completion reaches
        // UIKit's snapshot path, which is why `didReceive` is the one with the
        // completion-handler form.
        let content = notification.request.content
        if let assignmentID = LoudAlertActions.berserkSignalAssignmentID(
            categoryID: content.categoryIdentifier, userInfo: content.userInfo) {
            await BerserkTakeoverModel.shared.note(.buzz(assignmentID), at: Date())
        }
        return Self.foregroundPresentation
    }

    /// A tap on a notification or one of its buttons.
    ///
    /// **The completion-handler form, not the async one, and the handler is
    /// called on the main thread.** With the async form, the Swift-generated
    /// Objective-C thunk calls iOS's completion handler on whatever thread the
    /// async body finishes on, which is a Swift concurrency cooperative-pool
    /// thread. That handler runs UIKit's
    /// `-[UIApplication _updateSnapshotAndStateRestorationWithAction:windowScene:]`,
    /// which asserts it is on the main thread, throws, and aborts the process.
    /// Every tap on a Smooth notification (a reminder, a loud buzz, one of its
    /// buttons) killed the app: five reports off Marco's phone, builds 12 to 14,
    /// 2026-10-19 to 10-26. The tell is an `.ips` with `SIGABRT` (not
    /// `EXC_BREAKPOINT`), whose triggered thread is
    /// `com.apple.root.user-initiated-qos.cooperative`, with
    /// `@objc closure #1 in NotificationResponseDelegate.userNotificationCenter(_:didReceive:)`
    /// above `_updateSnapshotAndStateRestorationWithAction`. The wrong fixes:
    /// marking this method `@MainActor` (iOS calls it off the main thread, so
    /// Swift 6 kills the process on entry, the trap below), and keeping the
    /// async form while hopping to the main actor inside it (the thunk's own
    /// completion still runs on the cooperative thread afterwards). So
    /// `completionHandler()` is called exactly once on every path, from the
    /// end of one explicitly isolated `Task { @MainActor in }`.
    ///
    /// **`nonisolated`, and nothing here touches the main actor except that one
    /// task.** iOS calls this on its own queue. A main-actor-isolated witness,
    /// or a closure that *inherits* main-actor isolation, is checked at run
    /// time under Swift 6 and kills the process on entry
    /// (`_dispatch_assert_queue_fail`): the same trap that crashed every
    /// background refresh (CLAUDE.md, "Every background refresh has crashed")
    /// and `GradeCourseCardView.decidedText`. So the response is read into plain
    /// `Sendable` values here, with pure `nonisolated` code, and only those
    /// values (never `response` or `center`) are captured by a task whose
    /// `@MainActor` isolation is written out. The wrong fix would be to call
    /// `NotificationActionInbox` directly from here, or to act on the tap
    /// (complete the item, reschedule) in this callback.
    ///
    /// The default tap and the dismiss action parse to nil and are ignored by
    /// the button handling below: a plain tap opens the app, as it always has.
    /// A default tap on a *loud* buzz additionally raises the Berserk takeover
    /// (`BerserkTakeoverModel`), in the same task.
    ///
    /// **"turned in" silences the item at the tap itself.** Before anything is
    /// deposited, the item's pending and delivered loud notifications are
    /// removed through the `center` this method was handed. That is thread-safe
    /// notification-center API with no actor hop and no main-actor code, so it
    /// is as safe here as the rest of the method. It cannot wait for the
    /// dashboard: the buzzes are 3 seconds apart, and a Face ID unlock plus a
    /// cold launch takes longer, so the second and third would go off in the
    /// student's hand after they said the work was handed in. The completing
    /// and re-planning still happen only in the dashboard, against a matching
    /// active item. "open" does not do this (`identifiersToSilence`).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // Stamped here, at the tap, not when the main actor gets to it.
        let arrivedAt = Date()
        var buzzID: String?
        var deposit: LoudAlertAction?

        // A tap on a loud buzz's body opens the app as it always has, and now
        // also raises the takeover. A tap on one of its buttons does not: the
        // student has already chosen, and the action below carries it out.
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let content = response.notification.request.content
            buzzID = LoudAlertActions.berserkSignalAssignmentID(
                categoryID: content.categoryIdentifier, userInfo: content.userInfo)
        } else if let action = LoudAlertActions.action(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        ) {
            let silenced = LoudAlertActions.identifiersToSilence(for: action)
            if !silenced.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: silenced)
                center.removeDeliveredNotifications(withIdentifiers: silenced)
            }
            deposit = action
        }

        let takeoverID = buzzID
        let pendingAction = deposit
        // iOS hands the handler over as non-Sendable; it is documented as
        // callable once from any thread and is called here exactly once.
        nonisolated(unsafe) let done = completionHandler
        Task { @MainActor in
            if let takeoverID {
                BerserkTakeoverModel.shared.note(.buzz(takeoverID), at: arrivedAt)
            }
            if let pendingAction {
                NotificationActionInbox.shared.deposit(pendingAction, arrivedAt: arrivedAt)
            }
            done()
        }
    }
}

/// The one thing the App target can see of all this: the launch-time hook.
///
/// Public because `App/LHFApp.swift` can only reach public API of this
/// module, the same reason `LHFBackgroundRefresh` is.
public enum NotificationResponseRouter {
    /// Makes the shared delegate the notification center's and registers the
    /// loud alert's button categories. Call it from `LHFApp.init()`, before
    /// the app finishes launching: a tap on a button can be the thing that
    /// launches the app, and iOS delivers that response only to a delegate and
    /// categories already in place by then.
    ///
    /// Not `@MainActor`: it only touches the thread-safe notification center
    /// and a stateless delegate, so it can be called from anywhere.
    ///
    /// Nothing in the tests calls this. `UNUserNotificationCenter.current()`
    /// traps in an unbundled test binary, so the scheduler keeps its own use of
    /// it lazy, and so does this: it runs only when the app calls it.
    public static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationResponseDelegate.shared
        center.setNotificationCategories(LoudAlertActions.categories())
    }

    /// Where a press on one of a Berserk alarm's two buttons arrives
    /// (`BerserkAlarmPlan`): the App target's intents call this, after
    /// stopping their own alarm, and the press is queued in the same inbox the
    /// notification buttons use, so the dashboard handles it by the same code
    /// (`ContentView.takeLoudAlertActions`) and the same rules.
    ///
    /// - `.stop` queues "open this page" if `url` is an https URL with a
    ///   host, and queues nothing otherwise.
    /// - `.turnedIn` queues "turned in" for `assignmentID`. That is the only
    ///   thing in the alarm feature that can mark work done, and even then
    ///   only when the dashboard finds a matching active item. Never reached
    ///   from `.stop`, whatever it is given: AlarmKit may run the stop intent
    ///   when the alarm is swiped away or the side button is pressed.
    ///
    /// The URL is checked again here, by the notification parser's own rule,
    /// rather than trusted because the alarm was ours: it travelled through
    /// an intent parameter, as a string, and an intent can be invoked by
    /// something other than our alarm. The stamp is taken now, at the press,
    /// so a stale "open" expires like a notification's does.
    ///
    /// `@MainActor` because the inbox is; the intent's `perform()` is too.
    @MainActor
    public static func receiveAlarmAction(
        _ button: BerserkAlarmButton,
        assignmentID: String,
        url: String
    ) {
        receiveAlarmAction(button, assignmentID: assignmentID, url: url,
                           into: NotificationActionInbox.shared, at: Date())
    }

    /// As above into a given inbox at a given moment, so a test builds its own
    /// and never touches the shared one. Returns whether anything was queued.
    @MainActor
    @discardableResult
    static func receiveAlarmAction(
        _ button: BerserkAlarmButton,
        assignmentID: String,
        url: String,
        into inbox: NotificationActionInbox,
        at now: Date
    ) -> Bool {
        guard let action = BerserkAlarmPlan.action(for: button, assignmentID: assignmentID, url: url)
        else { return false }
        inbox.deposit(action, arrivedAt: now)
        return true
    }
}
