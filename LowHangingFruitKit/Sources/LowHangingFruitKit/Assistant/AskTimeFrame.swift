import Foundation

/// A run of whole local calendar days: `start` is the first instant of the
/// first day and `end` the first instant of the day after the last one
/// (exclusive), both in the student's zone, with the first and last day
/// spelled `yyyy-MM-dd` so a test, a log line or a later computed note can
/// say "2026-11-03" without redoing the arithmetic.
public struct AskDayRange: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let firstDay: String
    /// The last day *inside* the range (the day before `end`), not `end`'s.
    public let lastDay: String

    public init(start: Date, end: Date, firstDay: String, lastDay: String) {
        self.start = start
        self.end = end
        self.firstDay = firstDay
        self.lastDay = lastDay
    }
}

/// What a question is about in time, decided on the phone before anything is
/// retrieved (`docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`, Part 3 steps 1 and 2).
///
/// **Why this exists.** On 2026-11-02 "Do I not have cis 2620 class today?" was
/// answered from the registrar's weekly schedule while an Ed post from the day
/// before said there were no lectures. `RecencyIntent` fixed that one shape by
/// keyword and says only *which kind* of newest-posts question this is; nothing
/// resolved "today" to a date, and nothing told the search that a fresh post
/// should outrank a stale one for this kind of question only. This type is the
/// single classification both halves read: the excerpt picker (which posts lead)
/// and `CourseSearch` (how scores are weighted).
///
/// **Not a replacement for `RecencyIntent`.** The news and meeting word lists
/// stay there and are consulted first, unchanged, so every question that fired
/// before fires the same way (`recencyIntent` maps the result back). What this
/// adds is the second classification (due-date, policy, specific) and the
/// absolute date range. It is a new type rather than an extension of
/// `RecencyIntent` because that type's `windowDays` is a look-back measured
/// from the asking moment, and a range of local calendar days is a different
/// quantity.
///
/// **`dueOn` is classified and deliberately not acted on yet.** "What's due
/// tomorrow" is answered from the work list, and retrieval must not reorder
/// the excerpts for it (`RecencyIntent` says why). It is exposed here so the
/// later step that filters the work list by day can read the range; today
/// `CourseSearch` and the excerpt block treat it exactly like no intent.
///
/// Pure: it reads the question, a `Date` and a `TimeZone`, never the clock,
/// and never UTC unless the student is in it.
public enum AskTimeFrame: Sendable, Equatable {
    /// Does a class meet / is it cancelled. The range is the day or days the
    /// question names ("today", "this week", "Thursday"), `nil` when it names
    /// none ("when does lecture meet").
    case classMeeting(AskDayRange?)
    /// A deadline question with a day or days in it. Classified only.
    case dueOn(AskDayRange)
    /// What was posted lately; a `nil` window means "the newest, however old".
    case recentNews(windowDays: Int?)
    /// A standing-rule question (late policy, grading, attendance, exam
    /// logistics...) or one that names the syllabus.
    case policy
    /// Everything else.
    case specific

    /// The `RecencyIntent` this classification stands for, for the callers that
    /// pick the newest posts. `nil` for `dueOn`, `policy` and `specific`, which
    /// is what keeps their excerpts byte-identical to before.
    public var recencyIntent: RecencyIntent? {
        switch self {
        case .classMeeting:
            return RecencyIntent(windowDays: RecencyIntent.meetingWindowDays, kind: .meeting)
        case .recentNews(let windowDays):
            return RecencyIntent(windowDays: windowDays)
        case .dueOn, .policy, .specific:
            return nil
        }
    }

    /// Whether `CourseSearch` should decay the score of dated posts by age.
    /// Only for the two questions whose answer is "whatever is newest".
    public var weighsFreshness: Bool {
        switch self {
        case .classMeeting, .recentNews: return true
        case .dueOn, .policy, .specific: return false
        }
    }

    /// Whether a policy word should lift the syllabus a little more than it
    /// does by default (1.5 rather than 1.35): the standing-rule intents.
    public var favoursSyllabus: Bool {
        switch self {
        case .policy, .specific: return true
        case .classMeeting, .dueOn, .recentNews: return false
        }
    }

    // MARK: - Resolving

    public static func resolve(question: String, now: Date, timeZone: TimeZone) -> AskTimeFrame {
        // The same normalisation `RecencyIntent` applies, so a curly apostrophe
        // cannot hide a word from one and not the other.
        let q = question.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let resolver = Resolver(now: now, timeZone: timeZone)

        if let recency = RecencyIntent.detect(in: question) {
            switch recency.kind {
            case .news: return .recentNews(windowDays: recency.windowDays)
            case .meeting: return .classMeeting(resolver.range(in: q))
            }
        }
        if q.range(of: duePattern, options: .regularExpression) != nil, let range = resolver.range(in: q) {
            return .dueOn(range)
        }
        if q.contains("syllabus") || (CourseSearch.mentionsPolicyWord(q) && !carriesChangeWord(q)) {
            return .policy
        }
        return .specific
    }

    /// Words that say the student is asking whether something *changed*. A
    /// standing-rule word beside one of these ("was the midterm moved?") wants
    /// the newest post, not the syllabus, and a `.policy` classification
    /// would raise the syllabus boost and switch freshness off.
    private static let changeWords: Set<String> = [
        "moved", "changed", "rescheduled", "postponed", "cancelled", "canceled",
        "still", "now", "update", "updated", "updates",
    ]

    private static func carriesChangeWord(_ q: String) -> Bool {
        CourseSearch.wordTokens(q).contains(where: changeWords.contains)
    }

    /// A word about work being owed. Together with a day it is a due-date
    /// question; without a day it is not classified as one.
    private static let duePattern =
        #"\b(?:due|deadlines?|turn(?:ed)?\s+in|hand(?:ed)?\s+in|submit|submitted|submission|homeworks?|hw|assignments?|quiz|quizzes|problem\s+sets?|psets?|to-?do)\b"#

    /// Turns a day phrase into a range, in one zone, against one `now`.
    private struct Resolver {
        let calendar: Calendar
        let today: Date
        /// 1 = Sunday ... 7 = Saturday, as `Calendar.component(.weekday)`.
        let weekday: Int
        let formatter: DateFormatter

        init(now: Date, timeZone: TimeZone) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            calendar.locale = Locale(identifier: "en_US_POSIX")
            self.calendar = calendar
            self.today = calendar.startOfDay(for: now)
            self.weekday = calendar.component(.weekday, from: now)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            self.formatter = formatter
        }

        /// The start of the local day `offset` days from today. Calendar
        /// arithmetic, not 86,400-second steps, so a daylight-saving change
        /// inside the range cannot move a boundary off midnight.
        private func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: today) ?? today.addingTimeInterval(Double(offset) * 86_400)
        }

        private func make(from offset: Int, days: Int) -> AskDayRange {
            AskDayRange(
                start: day(offset),
                end: day(offset + days),
                firstDay: formatter.string(from: day(offset)),
                lastDay: formatter.string(from: day(offset + days - 1))
            )
        }

        private static let weekdayNames: [(name: String, number: Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
            ("thursday", 5), ("friday", 6), ("saturday", 7),
        ]

        /// The range of the day phrase written last in `q`, or `nil` when it has
        /// none. Last wins because `FollowUpRetrieval` puts the earlier question
        /// first and the student's new words last, as `RecencyIntent` does.
        func range(in q: String) -> AskDayRange? {
            var best: (position: Int, range: AskDayRange)?
            func consider(_ found: Range<String.Index>, _ candidate: AskDayRange) {
                let position = q.distance(from: q.startIndex, to: found.lowerBound)
                if best == nil || position >= best!.position { best = (position, candidate) }
            }

            if let found = q.range(of: #"\b(?:today|tonight|this\s+morning|this\s+afternoon|this\s+evening)\b"#, options: .regularExpression) {
                consider(found, make(from: 0, days: 1))
            }
            if let found = q.range(of: #"\btomorrow\b"#, options: .regularExpression) {
                consider(found, make(from: 1, days: 1))
            }
            if let found = q.range(of: #"\byesterday\b"#, options: .regularExpression) {
                consider(found, make(from: -1, days: 1))
            }
            if let found = q.range(of: #"\bthis\s+week\b"#, options: .regularExpression) {
                // Today through Sunday. On a Sunday that is today alone.
                let untilSunday = (8 - weekday) % 7
                consider(found, make(from: 0, days: untilSunday + 1))
            }
            if let found = q.range(of: #"\bnext\s+week\b"#, options: .regularExpression) {
                // The Monday after today through the Sunday after it. On a
                // Monday that is a week from today, not today.
                var toMonday = (2 - weekday + 7) % 7
                if toMonday == 0 { toMonday = 7 }
                consider(found, make(from: toMonday, days: 7))
            }
            if let found = q.range(of: #"\bthis\s+weekend\b"#, options: .regularExpression) {
                if weekday == 1 {
                    // Already Sunday: what is left of the weekend is today.
                    consider(found, make(from: 0, days: 1))
                } else {
                    consider(found, make(from: (7 - weekday + 7) % 7, days: 2))
                }
            }
            if let found = q.range(of: #"\b(?:past|last)\s+(\d{1,3})\s+days?\b"#, options: .regularExpression) {
                let digits = q[found].filter { $0.isASCII && $0.isNumber }
                if let n = Int(digits), n >= 1 {
                    // N days back through the end of today.
                    consider(found, make(from: -n, days: n + 1))
                }
            }
            for entry in Self.weekdayNames {
                if let found = q.range(of: "\\b" + entry.name + "\\b", options: .regularExpression) {
                    // The next such day, today included when it is that day.
                    consider(found, make(from: (entry.number - weekday + 7) % 7, days: 1))
                }
            }
            return best?.range
        }
    }
}
