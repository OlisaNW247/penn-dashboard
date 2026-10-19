import Foundation
import UserNotifications
import LowHangingFruitKit

/// What a tap on one of the loud alert's two buttons asks the app to do,
/// already read out of the notification and reduced to plain values.
///
/// `Sendable` on purpose: the delegate callback builds one of these on
/// whatever queue iOS calls it from and hands it to the main actor, and a
/// value that carries only a string and a `URL` is the one thing that can
/// make that trip without the callback ever touching main-actor state.
enum LoudAlertAction: Equatable, Sendable {
    /// "turned in": the `Assignment.id` of the item the alert was about.
    case turnedIn(String)
    /// "open in canvas" / "open in gradescope": the page to open.
    case open(URL)
}

/// An action with the moment the app received it, so a stale one can be told
/// from a fresh one when the dashboard finally gets to it
/// (`LoudAlertActions.unexpired`).
struct PendingLoudAlertAction: Equatable, Sendable {
    let action: LoudAlertAction
    let arrivedAt: Date
}

/// What the dashboard does with a `LoudAlertAction`, decided against the items
/// it is showing right now. See `LoudAlertActions.disposition`.
enum LoudAlertDisposition: Equatable {
    /// Do nothing at all (preview mode).
    case drop
    /// Run the swipe's own calls on this item, then clear its delivered
    /// alerts and re-plan.
    case complete(DashItem)
    /// The item is not on the dashboard or is already done: complete nothing,
    /// but still clear its delivered alerts and re-plan.
    case clearOnly(String)
    /// Open this page.
    case open(URL)

    /// Whether carrying this out calls for a re-plan of the reminders: a
    /// "turned in" does, whether or not there was a card to tick. A batch
    /// re-plans once at the end if any of its dispositions says so.
    var needsReplan: Bool {
        switch self {
        case .complete, .clearOnly: return true
        case .drop, .open: return false
        }
    }
}

/// The loud alert's buttons: their identifiers and labels, which item gets
/// which, how a tap is read back, and what the dashboard does about it.
///
/// Everything here is pure and `nonisolated`, so the whole rule set is tested
/// without a notification center (an unbundled test binary traps on
/// `UNUserNotificationCenter.current()`) and so the delegate callback, which
/// iOS runs on its own queue, can call it without an actor hop. A string rule
/// has no business inheriting an actor (CLAUDE.md, the `decidedText` trap).
enum LoudAlertActions {

    // MARK: Identifiers and labels

    /// Three categories rather than one, because a category's buttons are
    /// fixed when it is registered and cannot be edited per notification: an
    /// item with no Canvas page must not be offered "open in canvas", and one
    /// that is on Gradescope alone should say "open in gradescope", the card's
    /// own label for it. The choice is made per item by `buttons(for:)`.
    nonisolated static let canvasCategoryID = "loud.canvas"
    nonisolated static let gradescopeCategoryID = "loud.gradescope"
    nonisolated static let turnedInOnlyCategoryID = "loud.turnedin"

    nonisolated static let turnedInActionID = "loud.action.turnedin"
    nonisolated static let openActionID = "loud.action.open"

    /// The two `userInfo` keys a loud request carries.
    nonisolated static let assignmentIDKey = "loudAssignmentID"
    nonisolated static let linkURLKey = "loudLinkURL"

    /// Lowercase, in the app's voice. The two "open" labels are the card's own
    /// (`SourceLink`), reused rather than restated so a button can never say
    /// something different from the link it stands for.
    nonisolated static let turnedInTitle = "turned in"
    nonisolated static let openCanvasTitle = SourceLink.canvasLabel
    nonisolated static let openGradescopeTitle = SourceLink.gradescopeLabel

    // MARK: Categories

    /// The categories to register with the notification center, once, at
    /// launch (`NotificationResponseRouter.install`).
    ///
    /// **Why these exist at all.** The owner's request (2026-10-19): the loud
    /// alert "goes berserk and forces you to notice and either fix it or do
    /// something about it". Three notifications that can only be dismissed
    /// make you notice; these two buttons are the "do something about it",
    /// reachable from the lock screen without finding the card first.
    ///
    /// **Why every action is `.foreground`.** Both buttons open the app. The
    /// tempting alternative is to handle "turned in" in the background,
    /// without opening anything, since it is only a tick. That runs app code
    /// while the app is not on screen, which is the path that has crashed on
    /// every wake in this project (main-actor isolation enforced at run time,
    /// CLAUDE.md, "Every background refresh has crashed") and has never been
    /// shown to work on a phone. A foreground action also lets the swipe's
    /// real code run on the dashboard the student can see, rather than a
    /// second copy of it that only a notification ever exercises.
    ///
    /// **Why the registration happens at launch and not when the first alert
    /// is scheduled.** A tap on a button can cold-launch the app, and iOS
    /// delivers that response only to a delegate and categories that were in
    /// place before launch finished. Registering lazily, as the scheduler's
    /// own notification-center access is, would lose the very tap that
    /// started the app.
    nonisolated static func categories() -> Set<UNNotificationCategory> {
        func action(_ identifier: String, _ title: String) -> UNNotificationAction {
            UNNotificationAction(identifier: identifier, title: title, options: [.foreground])
        }
        func category(_ identifier: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: identifier, actions: actions,
                                   intentIdentifiers: [], options: [])
        }
        let turnedIn = action(turnedInActionID, turnedInTitle)
        return [
            category(canvasCategoryID, [turnedIn, action(openActionID, openCanvasTitle)]),
            category(gradescopeCategoryID, [turnedIn, action(openActionID, openGradescopeTitle)]),
            category(turnedInOnlyCategoryID, [turnedIn]),
        ]
    }

    // MARK: Which item gets which

    /// The category a loud alert for `assignment` uses, and the page its
    /// "open" button leads to (nil when it has none).
    ///
    /// Taken from `Assignment.sourceLinks`, the very list the card's "open in
    /// canvas" reads, so the button opens exactly what the card would. A
    /// Canvas link wins, which also settles a Canvas+Gradescope pair (the card
    /// lists Canvas first); a Gradescope link alone gives "open in
    /// gradescope"; manual work has neither and is offered "turned in" only.
    ///
    /// Matched on the link's label, not on the item's source: a task found in
    /// an announcement carries a Canvas link or an Ed one depending on where
    /// it was found (`sourceLinks`), and the label is what says which. An Ed
    /// link has no button here, by design: the owner asked for exactly three
    /// labels, and the item falls through to "turned in" alone.
    ///
    /// The URL is the assignment's own page, never the Canvas calendar feed
    /// address, which embeds a per-user token and is a bearer credential
    /// (CLAUDE.md, "Credentials never go in defaults"). `sourceLinks` is built
    /// from the item's own stored page URL, and the feed address lives only in
    /// the Keychain (`ICSFeedURLStore`), so it never reaches this function; a
    /// notification's `userInfo` is stored by the system, which is why that
    /// matters.
    nonisolated static func buttons(for assignment: Assignment) -> (categoryID: String, url: URL?) {
        let links = assignment.sourceLinks
        if let canvas = links.first(where: { $0.label == SourceLink.canvasLabel }) {
            return (canvasCategoryID, canvas.url)
        }
        if let gradescope = links.first(where: { $0.label == SourceLink.gradescopeLabel }) {
            return (gradescopeCategoryID, gradescope.url)
        }
        return (turnedInOnlyCategoryID, nil)
    }

    /// The `userInfo` of one loud request: which item it is about, and the
    /// page its "open" button leads to when there is one.
    nonisolated static func userInfo(assignmentID: String, url: URL?) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [assignmentIDKey: assignmentID]
        if let url { info[linkURLKey] = url.absoluteString }
        return info
    }

    // MARK: Reading a tap

    /// Reads a notification response back into an action, or nil when it is
    /// not one of ours to act on.
    ///
    /// The default tap (`UNNotificationDefaultActionIdentifier`: the student
    /// tapped the banner itself) and the dismiss action are deliberately nil:
    /// a plain tap just opens the app, as it always has, and a dismissal is
    /// not a request. So is an identifier this build does not know, a
    /// payload with the item's id missing or not a string, and a link that
    /// is not an https URL with a host: whatever a damaged or foreign payload
    /// says, the system is never handed a `javascript:`, `file:` or plain
    /// `http` address to open. https only, the rule `Assignment.sourceLinks`
    /// applies when it produces the link in the first place.
    nonisolated static func action(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> LoudAlertAction? {
        switch actionIdentifier {
        case turnedInActionID:
            guard let id = userInfo[assignmentIDKey] as? String, !id.isEmpty else { return nil }
            return .turnedIn(id)

        case openActionID:
            guard let raw = userInfo[linkURLKey] as? String,
                  let url = URL(string: raw),
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty
            else { return nil }
            return .open(url)

        default:
            return nil
        }
    }

    // MARK: What the dashboard does with it

    /// Decides what the dashboard does with `action`, given the items it is
    /// showing and whether it is in preview mode.
    ///
    /// - Preview mode drops everything: its sample data is not the student's
    ///   work, and a tap must neither tick a sample card nor open a page for
    ///   an alert the preview never scheduled.
    /// - "turned in" completes the item only when it is found and not already
    ///   done. An id the dashboard does not know (the item was deleted, or
    ///   this is a different install) must neither crash nor tick something
    ///   else, and an item already done needs no second tick; both still
    ///   clear the delivered alerts and re-plan, because the student asked
    ///   for the noise to stop.
    /// - "open" opens the page.
    nonisolated static func disposition(
        for action: LoudAlertAction,
        items: [DashItem],
        isPreviewMode: Bool
    ) -> LoudAlertDisposition {
        guard !isPreviewMode else { return .drop }
        switch action {
        case .turnedIn(let id):
            if let item = items.first(where: { $0.assignment.id == id }), !item.isCompleted {
                return .complete(item)
            }
            return .clearOnly(id)
        case .open(let url):
            return .open(url)
        }
    }

    /// `disposition` for a whole batch, in arrival order.
    ///
    /// Two "turned in" taps for one item (it is the same stack of three
    /// buzzes) must tick it once: the second is judged against the dashboard
    /// as the first leaves it, so it comes out as `.clearOnly`, not as a
    /// second completion of a card the first already finished.
    nonisolated static func dispositions(
        for actions: [LoudAlertAction],
        items: [DashItem],
        isPreviewMode: Bool
    ) -> [LoudAlertDisposition] {
        var items = items
        return actions.map { action in
            let result = disposition(for: action, items: items, isPreviewMode: isPreviewMode)
            if case .complete(let item) = result,
               let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].isCompleted = true
            }
            return result
        }
    }

    // MARK: Staleness

    /// How long an "open" tap stays worth acting on, in seconds.
    nonisolated static let openLifetime: TimeInterval = 120

    /// The actions in `queue` that are still worth doing at `now`, in the
    /// order they arrived.
    ///
    /// **A stale "open" expires; a stale "turned in" does not.** Taps wait in
    /// the inbox until the dashboard is on screen, and on a Mac that can be
    /// days: the menu-bar extra keeps the app alive with its window closed, so
    /// a page opened when the window finally returns would be one the student
    /// asked for last week. A "turned in" is different in kind: it is the
    /// student's own explicit claim that they handed the work in, and dropping
    /// it would lose something they did (the card would stay open and the app
    /// would go on warning them about finished work), so it is kept until it is
    /// consumed, however old. `now` is a parameter so the rule is testable
    /// without waiting.
    nonisolated static func unexpired(_ queue: [PendingLoudAlertAction], now: Date) -> [LoudAlertAction] {
        queue.compactMap { pending in
            if case .open = pending.action, now.timeIntervalSince(pending.arrivedAt) > openLifetime {
                return nil
            }
            return pending.action
        }
    }

    // MARK: Silencing at the tap

    /// The notification identifiers to pull from the notification center at the
    /// instant of a tap, before the app has even opened: all of the item's
    /// loud alert for "turned in", nothing for anything else.
    ///
    /// The three buzzes are 3 seconds apart, and a Face ID unlock plus a cold
    /// launch takes longer than that, so waiting for the dashboard to complete
    /// the item and re-plan would let the second and third buzz go off in the
    /// student's hand after they said it was handed in. Not done for "open":
    /// that item is not done, and the re-plan the app's next activation runs
    /// would put those buzzes back anyway.
    nonisolated static func identifiersToSilence(for action: LoudAlertAction) -> [String] {
        switch action {
        case .turnedIn(let id): return NotificationScheduler.loudIdentifiers(forAssignmentID: id)
        case .open: return []
        }
    }
}
