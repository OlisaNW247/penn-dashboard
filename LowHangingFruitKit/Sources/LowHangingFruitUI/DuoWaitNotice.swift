import Foundation
import UserNotifications
import LowHangingFruitKit

/// The one local notification for a missed Duo push.
///
/// When the silent sign-in reaches Duo, Duo sends a push, and nobody
/// approves it, the app latches `autoLoginAwaitingDuo` and shows "duo needs
/// you" on the dashboard. A student whose phone is closed never sees that
/// line, so an hour after the latch this posts one notice, once per latch
/// (the owner's phone, 2026-11-21, was signed out for hours without a word).
///
/// Foreground refreshes and the background refresh wake post it
/// (`AppState.postDuoWaitNoticeIfDue`); the push wake never does
/// (`PushWakeTests` pins that). It is a plain notification: default sound,
/// not time sensitive, no buttons. Nothing leaves the phone.
///
/// The wrong fixes: posting the moment the latch is set (Duo's own push is
/// usually still on the screen then, and approving it clears the latch with
/// nothing left to say), and posting on every refresh while the latch holds
/// (one per five minutes). The date the notice was posted for is what makes
/// it once per latch: a new latch has a new date.
enum DuoWaitNotice {
    static let identifierPrefix = "duo:"
    static let identifier = "duo:wait"
    static let title = "Smooth"
    static let body = "sign in to canvas to keep smooth updated"
    /// `UserDefaults.lhf`: the latch date the notice was last posted for.
    static let postedForLatchKey = "duoWaitNoticePostedForLatchV1"

    nonisolated static func isDuoIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    /// Pure rule. True when Duo is awaited over an expired session, the
    /// latch is at least `after` old (and not in the future), and no notice
    /// was posted for this very latch. Never under fixture data.
    nonisolated static func shouldPost(
        awaitingDuo: Bool,
        sessionExpired: Bool,
        latchedAt: Date?,
        now: Date,
        postedForLatchAt: Date?,
        fixtureData: Bool,
        after: TimeInterval = 3600
    ) -> Bool {
        guard !fixtureData, awaitingDuo, sessionExpired, let latchedAt else { return false }
        let age = now.timeIntervalSince(latchedAt)
        guard age >= 0, age >= after else { return false }
        return postedForLatchAt != latchedAt
    }

    /// The request, delivered at once. The identifier is fixed so a second
    /// post replaces the first instead of stacking.
    nonisolated static func request() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    nonisolated static func postedForLatch() -> Date? {
        (UserDefaults.lhf.object(forKey: postedForLatchKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
    }

    nonisolated static func recordPosted(forLatch date: Date) {
        UserDefaults.lhf.set(date.timeIntervalSince1970, forKey: postedForLatchKey)
    }

    /// The latch cleared (a renewal, a sign-in, a disconnect): forget the
    /// post and take the notice back, pending or delivered. Skipped under the
    /// test runner, where the notification center traps.
    nonisolated static func latchCleared() {
        UserDefaults.lhf.removeObject(forKey: postedForLatchKey)
        guard !SharedDefaults.isTestRunner else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}

/// Where a tap on the notice waits for the dashboard, the shape of
/// `AmbassadorModel.pendingOpen`: a cold launch from the tap raises the flag
/// before `ContentView` exists, so the view reads it at appearance too.
@MainActor
final class DuoWaitNoticeInbox: ObservableObject {
    static let shared = DuoWaitNoticeInbox()
    @Published private(set) var pendingOpen = false

    func noteTapped() { pendingOpen = true }
    func consume() { pendingOpen = false }
}

extension AppState {
    /// Posts the notice when `DuoWaitNotice.shouldPost` says so, and
    /// remembers the latch it was posted for only once the scheduler
    /// actually posted it (reminders off or notifications refused: not yet).
    func postDuoWaitNoticeIfDue(scheduler: NotificationScheduler, now: Date = Date()) async {
        guard let latch = autoLoginAwaitingDuoSince,
              DuoWaitNotice.shouldPost(
                awaitingDuo: autoLoginAwaitingDuo,
                sessionExpired: canvasSessionExpired,
                latchedAt: latch,
                now: now,
                postedForLatchAt: DuoWaitNotice.postedForLatch(),
                fixtureData: isUsingFixtureData
              ) else { return }
        // Recorded before the await so a second pass that starts while the
        // post is in flight (a refresh and a wake) cannot post it twice;
        // rolled back if nothing was posted, so a later pass tries again.
        let previous = DuoWaitNotice.postedForLatch()
        DuoWaitNotice.recordPosted(forLatch: latch)
        if await !scheduler.postDuoWaitNotification() {
            if let previous {
                DuoWaitNotice.recordPosted(forLatch: previous)
            } else {
                UserDefaults.lhf.removeObject(forKey: DuoWaitNotice.postedForLatchKey)
            }
        }
    }
}
