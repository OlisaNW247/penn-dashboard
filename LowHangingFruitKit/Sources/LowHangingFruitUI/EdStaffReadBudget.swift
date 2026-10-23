import Foundation

/// How many Ed **staff posts** the Ed task pass may send to an extractor in one
/// UTC day, on this install (`AppState.syncEdAnnouncementTasks`).
///
/// **Why a cap exists.** `extract-announcement` draws on the same per-student
/// daily quota as ask (`ASK_DAILY_LIMIT`, 40 by default; `backend/PROTOCOL.md`,
/// "Quota"). Staff posts are read only for a relevance judgment, and a busy
/// board has a 14-day backlog of them: the first sync after the staff-post read
/// shipped would otherwise spend a large share of a student's ask budget on
/// posts that, mostly, are answers nobody will list. The same trap has bitten
/// before. On 2026-10-19 every extraction failed, each 15-minute sync re-sent
/// the same 13 posts, and the student's chat quota was gone within the hour;
/// the comment on "THE QUOTA IS SHARED WITH ASK" in `AppState.syncAnnouncements`
/// tells it, and the retry clock, the three-strikes rule and the hour's back-off
/// (`announcementExtractionBackoff`) were its fixes. Those limit *failures*.
/// This limits *successes*: a staff post that reads fine is still a unit of the
/// student's quota.
///
/// **Per UTC day, not per run.** The pass runs after every change to the
/// course material, and the course-material sync runs all day, so a per-run cap
/// only spreads the same cost: six posts a run, a dozen runs a day, and the
/// quota is gone anyway. The wrong fix is a cap on the loop. A day's count is
/// the quantity the server's quota is about. The day is the UTC day because the
/// server's counter rolls over then, and the phone's local midnight would hand
/// out a second budget in the same server day.
///
/// **What is counted.** One for each staff post sent to a backend-or-injected
/// extractor, whether the call succeeds or fails (a failed call can still have
/// been counted by the server, and refusing to count it would make a failing
/// backend the cheapest way to blow the budget). Not counted: an informational
/// staff post (judged `news` on the phone with no call), a staff post of a
/// hidden class, or one read by the free on-device heuristic, none of which
/// touches the quota. A staff post held back by an exhausted budget is left
/// completely alone: not an attempt, no retry clock, not marked processed. It
/// is simply still eligible at the next run, which is how the oldest ones are
/// read on a later day. Announcement and pinned posts and the Canvas path never
/// consult this.
///
/// **Where it lives.** The day and the count sit in the preferences tier beside
/// the pass's retry clock (`edTaskRetryAfterV1`), as one small dictionary.
/// Under the test runner an `AppState` gets a memory-only budget, so no test
/// can reach the shared defaults domain; a test that wants to see the stored
/// form builds one over a scratch suite (`AppState.edStaffReadBudget`).
final class EdStaffReadBudget {
    /// Staff-post extractor calls per UTC day, per install.
    static let dailyLimit = 6
    static let key = "edStaffReadsV1"

    let limit: Int
    private let defaults: UserDefaults?
    /// The day and count when there is no defaults to keep them in.
    private var memory: (day: Int, count: Int)?

    /// - Parameter defaults: where the day and count persist; nil keeps them in
    ///   this object only.
    init(defaults: UserDefaults?, limit: Int = EdStaffReadBudget.dailyLimit) {
        self.defaults = defaults
        self.limit = limit
    }

    /// The UTC day `date` falls on, as whole days since 1970. No calendar, zone
    /// or formatter, so no setting on the phone can move the boundary.
    static func utcDay(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Calls already made on the UTC day of `date`.
    func used(on date: Date) -> Int {
        let today = Self.utcDay(of: date)
        let stored: (day: Int, count: Int)?
        if let defaults {
            let saved = defaults.dictionary(forKey: Self.key) as? [String: Int]
            stored = saved.flatMap { entry in
                guard let day = entry["day"], let count = entry["count"] else { return nil }
                return (day, count)
            }
        } else {
            stored = memory
        }
        guard let stored, stored.day == today else { return 0 }
        return max(stored.count, 0)
    }

    /// Calls left on the UTC day of `date`.
    func remaining(on date: Date) -> Int {
        max(limit - used(on: date), 0)
    }

    /// Records one call made at `date`. A new UTC day starts again from one.
    func recordCall(on date: Date) {
        let today = Self.utcDay(of: date)
        let count = used(on: date) + 1
        if let defaults {
            defaults.set(["day": today, "count": count], forKey: Self.key)
        } else {
            memory = (today, count)
        }
    }
}
