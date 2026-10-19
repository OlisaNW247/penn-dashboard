import Foundation
import UserNotifications

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
@MainActor
final class NotificationActionInbox: ObservableObject {
    /// The one inbox the app uses. Tests build their own.
    static let shared = NotificationActionInbox()

    @Published private(set) var queue: [PendingLoudAlertAction] = []

    init() {}

    /// Appends `action`, stamped with when the app received it. The nonisolated
    /// delegate callback reaches this with a plain `await`, which hops to the
    /// main actor without the callback ever forming a main-actor closure of its
    /// own.
    func deposit(_ action: LoudAlertAction, arrivedAt: Date) {
        queue.append(PendingLoudAlertAction(action: action, arrivedAt: arrivedAt))
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
        Self.foregroundPresentation
    }

    /// A tap on a notification or one of its buttons.
    ///
    /// **`nonisolated`, and nothing here touches the main actor until the
    /// last line.** iOS calls this on its own queue. A main-actor-isolated
    /// witness, or a closure that inherits main-actor isolation, is checked
    /// at run time under Swift 6 and kills the process on entry
    /// (`_dispatch_assert_queue_fail`): the same trap that crashed every
    /// background refresh (CLAUDE.md, "Every background refresh has crashed")
    /// and `GradeCourseCardView.decidedText`. So the response is read into a
    /// plain `Sendable` value here, with pure `nonisolated` code, and only
    /// that value crosses to the main actor, by an `await` on a
    /// `@MainActor` method rather than by any closure written in this
    /// method. The wrong fix would be to call `NotificationActionInbox`
    /// directly from here, or to act on the tap (complete the item, reschedule)
    /// in this callback.
    ///
    /// The default tap and the dismiss action parse to nil and are ignored: a
    /// plain tap opens the app, as it always has.
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
                                            didReceive response: UNNotificationResponse) async {
        guard let action = LoudAlertActions.action(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        ) else { return }

        let silenced = LoudAlertActions.identifiersToSilence(for: action)
        if !silenced.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: silenced)
            center.removeDeliveredNotifications(withIdentifiers: silenced)
        }

        // Stamped here, at the tap, not when the main actor gets to it.
        await NotificationActionInbox.shared.deposit(action, arrivedAt: Date())
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
}
