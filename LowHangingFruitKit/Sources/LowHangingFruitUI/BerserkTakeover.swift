import Foundation
import SwiftUI

// Berserk mode, the takeover screen: the pure half and the model.
//
// The owner's test (2026-10-20, iOS 26): the alarm rang full screen on the lock
// screen, but with the phone unlocked it is a small drop-in alert. iOS does not
// let an app take the screen while it is closed, and nothing here pretends
// otherwise. What the app can do is this: the moment Smooth is on screen while
// an alarm is ringing, or a loud buzz is tapped or lands while Smooth is open,
// Smooth covers its whole window with a tomato screen that names the class and
// the assignment, counts down to the due time, and offers three choices
// ("turned in", the item's page, "not yet").
//
// Everything that decides anything is in `BerserkTakeoverRules`: plain values
// and `nonisolated` functions, so it is tested on the Mac without AlarmKit or a
// notification center. `BerserkTakeoverModel` is the one small piece of state
// (what is waiting, what is showing); the view is `BerserkTakeoverView.swift`
// and the glue that listens to AlarmKit and the scheduler is
// `BerserkTakeoverHost.swift`.

/// Why a takeover might be due. Two kinds of evidence reach the app:
/// - an alarm that is ringing right now (`alarm`, by the id AlarmKit gives it),
/// - a loud buzz that was tapped on its body or delivered while the app is open
///   (`buzz`, by the `Assignment.id` the notification carries).
enum BerserkTakeoverSignal: Equatable, Hashable, Sendable {
    case alarm(UUID)
    case buzz(String)
}

/// A signal with the moment the app learned of it. Only a buzz is judged by
/// that moment (`BerserkTakeoverRules.buzzLifetime`); an alarm is judged by
/// whether it is still ringing.
struct PendingBerserkSignal: Equatable, Sendable {
    let signal: BerserkTakeoverSignal
    let arrivedAt: Date
}

/// What the takeover screen shows, already reduced to plain values.
struct BerserkTakeover: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Raised by a ringing alarm, whose id is what stopping it needs.
        case alarm(UUID)
        /// Raised by a buzz; there is no alarm to stop.
        case buzz
    }

    /// `Assignment.id` of the item, the key "turned in" is deposited under.
    let assignmentID: String
    /// The class as the card shows it (the student's rename applied).
    let course: String
    /// The assignment's name, trimmed as a reminder trims it.
    let title: String
    let due: Date?
    /// The page "open in canvas" / "open in gradescope" leads to, if any.
    let link: PlannedAlarm.Link?
    let source: Source
}

/// The three things the student can do on the takeover.
enum BerserkTakeoverChoice: Equatable, Sendable {
    case turnedIn
    case open
    case notYet
}

/// What a choice does, as a list the host runs in order. A value and not a
/// closure so a table of them can be tested without a scheduler.
enum BerserkTakeoverEffect: Equatable, Sendable {
    /// Stop (and cancel) one ringing alarm: the student's own stop.
    case stopAlarm(UUID)
    /// Pull the item's already-delivered loud notifications.
    case silenceBuzzes(String)
    /// Put an action in the inbox the notification buttons use.
    case deposit(LoudAlertAction)
    case openURL(URL)
    case dismiss
}

enum BerserkTakeoverRules {

    // MARK: Staleness

    /// How long a buzz stays worth a takeover, in seconds.
    ///
    /// The same two minutes as `LoudAlertActions.openLifetime`, for the same
    /// reason: the signal waits in memory until the window can show it, and on a
    /// Mac the menu-bar extra keeps the app alive with its window closed, so a
    /// buzz noted on Monday must not take over the screen on Thursday when the
    /// window finally opens. An alarm needs no such clock; it is judged by
    /// whether AlarmKit still says it is ringing.
    nonisolated static let buzzLifetime: TimeInterval = 120

    // MARK: Tracing an alarm back to its item

    /// Every item that has a due time, keyed by the id its alarm would have.
    ///
    /// **Why this exists.** AlarmKit's `Alarm` carries no metadata the app can
    /// read back from a ringing alarm, but the alarm's id is deliberately a
    /// hash of (assignment id, ring time) (`BerserkAlarmPlan.alarmID`), so the
    /// id can be recomputed for each item and matched. The ring time is due
    /// minus `loudAlertLead`, exactly what `BerserkAlarmPlan.alarms` uses, and
    /// the due time is `DashItem.due` (the student's edited date, if any), so
    /// a moved item resolves by its new alarm and the old alarm, which the
    /// next reschedule cancels, resolves to nothing. The wrong fix is a second
    /// copy of the id arithmetic: this calls the one function.
    nonisolated static func alarmIndex(items: [DashItem]) -> [UUID: DashItem] {
        var index: [UUID: DashItem] = [:]
        for item in items {
            guard let due = item.due else { continue }
            let id = BerserkAlarmPlan.alarmID(
                assignmentID: item.assignment.id,
                fireDate: due.addingTimeInterval(-NotificationScheduler.loudAlertLead))
            if index[id] == nil { index[id] = item }
        }
        return index
    }

    // MARK: Building the screen's content

    /// The takeover for `item`.
    ///
    /// The title is cut the way a reminder's body and an alarm's title are cut
    /// (`NotificationScheduler.reminderName`), with the class standing in for a
    /// blank name, and the link is chosen by `LoudAlertActions.buttons(for:)`
    /// and mapped exactly as `BerserkAlarmPlan.alarms` maps it, so the
    /// takeover can never offer a page the alarm's own stop button would not.
    nonisolated static func takeover(
        for item: DashItem,
        source: BerserkTakeover.Source,
        nameOverrides: [String: String]
    ) -> BerserkTakeover {
        let assignment = item.assignment
        let course = assignment.displayCourse(overrides: nameOverrides)
        let name = NotificationScheduler.reminderName(assignment.title)
        let buttons = LoudAlertActions.buttons(for: assignment)
        let link: PlannedAlarm.Link?
        switch (buttons.categoryID, buttons.url) {
        case (LoudAlertActions.canvasCategoryID, let url?): link = .init(kind: .canvas, url: url)
        case (LoudAlertActions.gradescopeCategoryID, let url?): link = .init(kind: .gradescope, url: url)
        default: link = nil
        }
        return BerserkTakeover(
            assignmentID: assignment.id,
            course: course,
            title: name.isEmpty ? course : name,
            due: item.due,
            link: link,
            source: source)
    }

    // MARK: Which signal gets the screen

    /// What `resolve` decided: the takeover to show (nil for none) and the
    /// signals that stay in the model, in the order they arrived.
    struct Resolution: Equatable, Sendable {
        let current: BerserkTakeover?
        let waiting: [PendingBerserkSignal]
    }

    /// Turns the signals waiting in the model into at most one takeover.
    ///
    /// - **Fixture data** (preview mode, the DEBUG demo launch) yields nothing
    ///   at all: the sample data never rings (`BerserkAlarmPlan.alarmsAllowed`)
    ///   and so must never take over the screen either.
    /// - **An alarm signal whose id is not ringing is dropped.** The student
    ///   stopped it from the lock screen, or it was stopped for finished work;
    ///   a takeover for an alarm that is silent would be a screen about
    ///   nothing.
    /// - **An alarm that is ringing but not traceable to an item is kept
    ///   waiting**, not dropped: the dashboard may not have loaded yet (a cold
    ///   launch from the lock screen), and the alarm is still ringing. A buzz
    ///   whose item is not on the list is kept for the same reason, until its
    ///   `buzzLifetime` runs out.
    /// - **A signal whose item is finished is dropped.** Ticked off means the
    ///   alert has done its job.
    /// - **One assignment is one takeover.** An alarm and a buzz for the same
    ///   item collapse to the alarm, because only the alarm carries the id that
    ///   stopping it needs; two identical signals collapse to the first.
    /// - **The soonest due is shown first**, a missing due time last, ties by
    ///   assignment id so the choice is a function of its inputs. The others
    ///   stay in `waiting` in arrival order, and the host resolves again when
    ///   the one on screen is answered, so a second ringing item follows the
    ///   first rather than being lost.
    nonisolated static func resolve(
        pending: [PendingBerserkSignal],
        items: [DashItem],
        alerting: Set<UUID>,
        now: Date,
        isUsingFixtureData: Bool,
        nameOverrides: [String: String]
    ) -> Resolution {
        guard BerserkAlarmPlan.alarmsAllowed(isUsingFixtureData: isUsingFixtureData) else {
            return Resolution(current: nil, waiting: [])
        }

        let alarmItems = alarmIndex(items: items)
        var itemsByID: [String: DashItem] = [:]
        for item in items where itemsByID[item.assignment.id] == nil {
            itemsByID[item.assignment.id] = item
        }

        // A signal that survived the drop rules, with its item when it has
        // one. `order` is its place in `pending`.
        struct Kept {
            let order: Int
            let entry: PendingBerserkSignal
            let item: DashItem?
            let source: BerserkTakeover.Source?

            var isAlarm: Bool {
                if case .some(.alarm) = source { return true }
                return false
            }
        }

        var kept: [Kept] = []
        for (order, entry) in pending.enumerated() {
            switch entry.signal {
            case .alarm(let id):
                guard alerting.contains(id) else { continue }
                if let item = alarmItems[id] {
                    if item.isCompleted { continue }
                    kept.append(Kept(order: order, entry: entry, item: item, source: .alarm(id)))
                } else {
                    kept.append(Kept(order: order, entry: entry, item: nil, source: nil))
                }
            case .buzz(let assignmentID):
                guard now.timeIntervalSince(entry.arrivedAt) <= buzzLifetime else { continue }
                if let item = itemsByID[assignmentID] {
                    if item.isCompleted { continue }
                    kept.append(Kept(order: order, entry: entry, item: item, source: .buzz))
                } else {
                    kept.append(Kept(order: order, entry: entry, item: nil, source: nil))
                }
            }
        }

        // One winner per assignment: an alarm beats a buzz, otherwise the
        // earlier arrival.
        var winners: [String: Kept] = [:]
        for candidate in kept {
            guard let item = candidate.item else { continue }
            let key = item.assignment.id
            if let existing = winners[key] {
                if !existing.isAlarm && candidate.isAlarm { winners[key] = candidate }
            } else {
                winners[key] = candidate
            }
        }

        // What stays: each winner, and each unresolved signal once.
        var survivors: [Kept] = []
        var seenUnresolved = Set<BerserkTakeoverSignal>()
        for candidate in kept {
            if let item = candidate.item {
                if winners[item.assignment.id]?.order == candidate.order { survivors.append(candidate) }
            } else if seenUnresolved.insert(candidate.entry.signal).inserted {
                survivors.append(candidate)
            }
        }

        let chosen = winners.values
            .filter { $0.item != nil }
            .min { lhs, rhs in
                guard let left = lhs.item, let right = rhs.item else { return false }
                return DashItem.isOrderedByDueDate(left, right)
            }

        guard let chosen, let item = chosen.item, let source = chosen.source else {
            return Resolution(current: nil, waiting: survivors.map(\.entry))
        }
        return Resolution(
            current: takeover(for: item, source: source, nameOverrides: nameOverrides),
            waiting: survivors.filter { $0.order != chosen.order }.map(\.entry))
    }

    // MARK: What a choice does

    /// The effects of `choice`, in the order to run them.
    ///
    /// **"turned in" is the only choice that deposits a "turned in", and no
    /// dismissal path may ever mark work done.** This is `BerserkAlarmPlan`'s
    /// rule carried onto the screen: a way out of the takeover that is not a
    /// deliberate tap on a button saying "turned in" (the app going to the
    /// background, the alarm being stopped from the lock screen, "not yet")
    /// must leave the work open and the app still warning about it. The
    /// wrong fix is to treat any answer as the student being done with it.
    ///
    /// Stopping the alarm from inside the app is the student's own stop and
    /// completes nothing. "open" with no page to open has nowhere to go and
    /// behaves as "not yet", rather than doing nothing and leaving the
    /// student on a screen whose button did not work.
    nonisolated static func effects(
        for choice: BerserkTakeoverChoice,
        takeover: BerserkTakeover
    ) -> [BerserkTakeoverEffect] {
        var stop: [BerserkTakeoverEffect] = []
        if case .alarm(let id) = takeover.source { stop = [.stopAlarm(id)] }

        switch choice {
        case .turnedIn:
            return stop + [.silenceBuzzes(takeover.assignmentID),
                           .deposit(.turnedIn(takeover.assignmentID)),
                           .dismiss]
        case .open:
            guard let link = takeover.link else {
                return effects(for: .notYet, takeover: takeover)
            }
            return stop + [.openURL(link.url), .dismiss]
        case .notYet:
            return stop + [.silenceBuzzes(takeover.assignmentID), .dismiss]
        }
    }

    // MARK: When the screen goes away on its own

    /// Whether the takeover on screen has nothing left to be about.
    ///
    /// An alarm-sourced one ends when its alarm is no longer ringing (stopped
    /// from the lock screen or the drop-in alert, or stopped because the work
    /// was ticked off); any takeover ends when its item is finished. A buzz
    /// takeover otherwise stays until the student answers it: a buzz has no
    /// ringing state to follow, and a screen that vanished by itself would
    /// let the student miss it.
    nonisolated static func shouldDismiss(
        _ current: BerserkTakeover,
        alerting: Set<UUID>,
        items: [DashItem]
    ) -> Bool {
        if case .alarm(let id) = current.source, !alerting.contains(id) { return true }
        return items.contains { $0.assignment.id == current.assignmentID && $0.isCompleted }
    }

    // MARK: Words

    /// The countdown as text, for VoiceOver and as the fallback where a live
    /// timer is not drawn. "due now" at or past the due time or with none.
    nonisolated static func countdownLabel(due: Date?, now: Date) -> String {
        guard let due, due > now else { return "due now" }
        let minutes = Int((due.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "due in \(minutes) min" }
        let remainder = minutes % 60
        return remainder == 0
            ? "due in \(minutes / 60) h"
            : "due in \(minutes / 60) h \(remainder) min"
    }
}

/// What is waiting for the screen and what is on it.
///
/// A class of its own, shared, because the signals arrive from places that
/// have no view: the notification delegate (`NotificationResponseDelegate`)
/// and AlarmKit's update stream. The delegate reaches it with one `await` on
/// this `@MainActor` class, the pattern its doc comments insist on.
@MainActor
final class BerserkTakeoverModel: ObservableObject {
    static let shared = BerserkTakeoverModel()

    @Published private(set) var pending: [PendingBerserkSignal] = []
    @Published private(set) var current: BerserkTakeover? = nil

    /// Alarms the student has answered. An alarm id names one ring time, so it
    /// never rings twice and is kept for the life of the process.
    private var answeredAlarms: Set<UUID> = []
    /// When the student last answered a takeover for each assignment. The
    /// loud alert is three buzzes three seconds apart: without this, a "not
    /// yet" on the first would be followed by a second takeover when the
    /// second buzz arrives. Forgotten after `buzzLifetime`.
    private var answeredBuzzes: [String: Date] = [:]

    init() {}

    /// Records that `signal` was seen at `now`, unless it is already waiting,
    /// already on screen, or was answered a moment ago.
    func note(_ signal: BerserkTakeoverSignal, at now: Date) {
        if pending.contains(where: { $0.signal == signal }) { return }
        if let current, Self.describes(current, signal) { return }
        switch signal {
        case .alarm(let id):
            if answeredAlarms.contains(id) { return }
        case .buzz(let assignmentID):
            if let answeredAt = answeredBuzzes[assignmentID],
               now.timeIntervalSince(answeredAt) <= BerserkTakeoverRules.buzzLifetime { return }
        }
        pending.append(PendingBerserkSignal(signal: signal, arrivedAt: now))
    }

    /// `note(.alarm)` for every id in `ids`: the alarms ringing right now.
    func noteAlerting(_ ids: [UUID], at now: Date) {
        for id in ids { note(.alarm(id), at: now) }
    }

    /// Takes the outcome of `BerserkTakeoverRules.resolve`.
    ///
    /// **Never replaces a takeover that is on screen with a different one.**
    /// A student mid-decision must not have the page change under their
    /// thumb. When one is showing, only `pending` is updated; the candidate
    /// `resolution` would have shown stays waiting (its signal went out of
    /// `pending` when it was last promoted, and `resolve` was asked about the
    /// rest, so it is put back from the signals we still hold), and the host
    /// resolves again after the shown one is answered.
    func apply(_ resolution: BerserkTakeoverRules.Resolution) {
        guard current == nil else {
            var waiting = resolution.waiting
            if let candidate = resolution.current,
               let held = pending.first(where: { Self.describes(candidate, $0.signal) }) {
                waiting.append(held)
                waiting.sort { lhs, rhs in
                    (pending.firstIndex(of: lhs) ?? Int.max) < (pending.firstIndex(of: rhs) ?? Int.max)
                }
            }
            if pending != waiting { pending = waiting }
            return
        }
        current = resolution.current
        if pending != resolution.waiting { pending = resolution.waiting }
    }

    /// Clears the screen, and remembers the answer so the same alarm, or a
    /// buzz for the same item in the next two minutes, does not bring it back.
    func dismiss(at now: Date = Date()) {
        if let current {
            if case .alarm(let id) = current.source { answeredAlarms.insert(id) }
            answeredBuzzes = answeredBuzzes.filter {
                now.timeIntervalSince($0.value) <= BerserkTakeoverRules.buzzLifetime
            }
            answeredBuzzes[current.assignmentID] = now
        }
        current = nil
    }

    /// Whether `signal` is what `takeover` is already showing.
    nonisolated static func describes(_ takeover: BerserkTakeover, _ signal: BerserkTakeoverSignal) -> Bool {
        switch signal {
        case .alarm(let id):
            if case .alarm(let own) = takeover.source { return own == id }
            return false
        case .buzz(let assignmentID):
            return takeover.assignmentID == assignmentID
        }
    }
}
