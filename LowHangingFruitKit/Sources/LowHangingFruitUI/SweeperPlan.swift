import Foundation

/// Everything the Sweeper decides, as a value: the master switch, the
/// defaults, the classes switched off, and each class's own lead time and
/// sound. The scheduler builds one from its published state
/// (`NotificationScheduler.sweeperSettings`) and the Sweeper page builds the
/// same one to ask "what rings next", so the page can never describe an alarm
/// the planner would not set.
///
/// **One eligibility rule, two readers.** `qualifies(_:now:horizon:courseRemindersOn:)`
/// is the rule `NotificationScheduler.loudAlerts` has always applied (not
/// done, dated and ahead, submittable, not a found exam, class not switched
/// off, class reminders on), moved here unchanged so the planner and the
/// "next sweep" card share it. The wrong fix is restating it in the view:
/// the first time a new exclusion lands in the planner the card would keep
/// promising an alarm that never rings.
///
/// **Overrides fall back, they do not copy.** A class without an override
/// reads the current default, so changing the default moves every class that
/// never chose, and "reset" on a class is simply removing its entries.
struct SweeperSettings: Equatable, Sendable {
    var isOn: Bool = true
    var defaultMinutes: Int = 10
    var defaultSound: SweeperSound = .smooth
    var excludedCourses: Set<String> = []
    var minutesOverrides: [String: Int] = [:]
    var soundOverrides: [String: SweeperSound] = [:]

    /// The lead time and sound that apply to a class.
    nonisolated func resolved(for course: String) -> (minutes: Int, sound: SweeperSound) {
        (minutesOverrides[course] ?? defaultMinutes, soundOverrides[course] ?? defaultSound)
    }

    /// Whether the class has chosen its own lead time or sound.
    nonisolated func hasOverride(_ course: String) -> Bool {
        minutesOverrides[course] != nil || soundOverrides[course] != nil
    }

    /// Whether `item` is work the Sweeper rings for, ignoring only how close
    /// its ring time is (callers judge that against their own lead). The
    /// switch itself is not part of this: callers check `isOn` first, so a
    /// page can still reason about a class while the Sweeper is off.
    ///
    /// `courseRemindersOn` answers the per-class reminders switch. It is a
    /// closure because that store is main-actor isolated and this rule must
    /// stay callable from anywhere.
    nonisolated func qualifies(
        _ item: DashItem,
        now: Date,
        horizon: Date,
        courseRemindersOn: (String) -> Bool
    ) -> Bool {
        guard !item.isCompleted, let due = item.due, due > now, due <= horizon else { return false }
        guard !item.showsNothingToSubmit, !RecurringTask.isOccurrence(item.assignment) else { return false }
        guard !item.isFoundExam else { return false }
        guard !excludedCourses.contains(item.assignment.course) else { return false }
        guard courseRemindersOn(item.assignment.course) else { return false }
        return true
    }
}

/// One alarm the Sweeper has set: the work, when it rings, and with what.
struct SweepRing: Equatable {
    let item: DashItem
    let ringAt: Date
    let minutes: Int
    let sound: SweeperSound
}

extension SweeperSettings {
    /// The soonest alarm that will actually ring: the qualifying item with the
    /// earliest `due - lead` that is still ahead of `now`, with the lead its
    /// own class resolves to. Nil when the Sweeper is off or nothing is ahead.
    ///
    /// A cancelled item (`DashItem.isFactCancelled`) is skipped for the same
    /// reason `plannedRequests` skips it. Ties go to the lower id so the
    /// answer does not depend on the order the dashboard listed two items
    /// due in the same minute (the planner's own tie-break).
    nonisolated static func nextSweep(
        in items: [DashItem],
        now: Date,
        settings: SweeperSettings,
        horizonDays: Int = NotificationScheduler.horizonDays,
        courseRemindersOn: (String) -> Bool
    ) -> SweepRing? {
        guard settings.isOn else { return nil }
        let horizon = now.addingTimeInterval(Double(horizonDays) * 86_400)
        var best: SweepRing?
        for item in items where !item.isFactCancelled {
            guard settings.qualifies(item, now: now, horizon: horizon, courseRemindersOn: courseRemindersOn),
                  let due = item.due else { continue }
            let (minutes, sound) = settings.resolved(for: item.assignment.course)
            let ringAt = due.addingTimeInterval(-Double(minutes * 60))
            guard ringAt > now else { continue }
            let candidate = SweepRing(item: item, ringAt: ringAt, minutes: minutes, sound: sound)
            if let current = best {
                if ringAt < current.ringAt || (ringAt == current.ringAt && item.id < current.item.id) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }
}
