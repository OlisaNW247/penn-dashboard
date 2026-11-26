import Foundation

/// What the last-hour poll should do right now. Pure, so the cadence is a
/// table in a test rather than a timer nobody can watch.
public enum PollDecision: Equatable, Sendable {
    case poll
    case wait(until: Date)
    case idle
}

/// The cadence of the poll that runs only while an alarm is about to ring:
/// inside the hour before the next ring, at most once a minute, and never
/// while a back-off (a rate limit or an error) is in force. Outside that hour
/// the answer is `.idle`, so a student with no alarm near costs Canvas nothing.
public enum LastHourPoll {
    /// True while `nextRing` is still ahead and no more than `hour` away. A
    /// ring already in the past is not inside the hour: it has rung or been
    /// missed, and polling for it would only spend requests.
    public static func insideTheHour(now: Date, nextRing: Date?, hour: TimeInterval = 3600) -> Bool {
        guard let nextRing else { return false }
        return nextRing > now && nextRing.timeIntervalSince(now) <= hour
    }

    public static func cadence(
        now: Date,
        nextRing: Date?,
        lastPoll: Date?,
        backedOffUntil: Date?,
        interval: TimeInterval = 60,
        hour: TimeInterval = 3600
    ) -> PollDecision {
        if let backedOffUntil, backedOffUntil > now { return .wait(until: backedOffUntil) }
        guard insideTheHour(now: now, nextRing: nextRing, hour: hour) else { return .idle }
        guard let lastPoll, now.timeIntervalSince(lastPoll) < interval else { return .poll }
        return .wait(until: lastPoll.addingTimeInterval(interval))
    }

    /// The planner window a poll asks for: an hour back to two hours ahead.
    public static func window(now: Date) -> (start: Date, end: Date) {
        (now.addingTimeInterval(-3600), now.addingTimeInterval(7200))
    }
}
