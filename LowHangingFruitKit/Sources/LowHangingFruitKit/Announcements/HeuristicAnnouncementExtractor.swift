import Foundation

/// Free, deterministic, offline extraction: no network call, no API key,
/// no per-announcement cost. This is the default backend —
/// `ClaudeAnnouncementExtractor` exists for announcements this one can't make
/// sense of, not the other way around.
///
/// **Design stance: false positives are worse than false negatives.** A
/// missed assignment is invisible — the student never notices the dashboard
/// didn't catch it, and Canvas's own assignment/ICS feed is very likely to
/// carry the same due date anyway once the professor actually creates the
/// graded item. A *wrong* assignment — one this extractor invented from an
/// announcement that was actually just "office hours moved to 3pm" — sits on
/// the dashboard next to real deadlines and erodes the one thing this app is
/// for: trusting the "what's due next" list. Every threshold below (the verb
/// list, the cue list, the 3-per-announcement cap, the >30-day-in-the-past
/// year rollover) is chosen to be conservative for that reason, and each is
/// commented at its point of use with what a looser version would have
/// risked.
///
/// **Why this only does sentence-level pattern matching, not real NLP.** A
/// full parser (dependency parsing, NER for dates) would catch more phrasing
/// but is exactly the kind of thing that quietly regresses when Canvas
/// professors write in ways nobody tested against — and this package has no
/// on-device ML dependency to begin with (CLAUDE.md: no third-party SDKs).
/// The Claude backend is the escape hatch for phrasing this one can't
/// reach; this one only needs to be right when it fires, not fire on
/// everything.
public struct HeuristicAnnouncementExtractor: AnnouncementAssignmentExtractor {
    /// Never store `Date()`/`.current` as extraction state — everything here
    /// is driven by the `now` parameter `extract(from:now:)` receives, so a
    /// test can fix "today" and get deterministic weekday/relative-date math.
    /// `calendar` and `timeZone` are injected the same way for the same
    /// reason: "Friday" three weeks from a test run in one timezone can be a
    /// different calendar day than in another.
    private let calendar: Calendar

    public init(calendar: Calendar = .current, timeZone: TimeZone = .current) {
        var resolved = calendar
        resolved.timeZone = timeZone
        self.calendar = resolved
    }

    /// The maximum number of `ExtractedAssignment`s produced per
    /// announcement, regardless of how many sentences look actionable.
    /// Chosen deliberately small: an announcement genuinely listing five
    /// separate deliverables is rare, whereas a syllabus-shaped announcement
    /// pasted in full (which does happen — professors reuse the syllabus text
    /// as a "welcome to the semester" announcement) can contain a dozen
    /// sentences that superficially look actionable. Capping keeps a
    /// mis-fire's blast radius small instead of flooding the dashboard.
    private static let maxExtractionsPerAnnouncement = 3

    public func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
        var results: [ExtractedAssignment] = []
        for sentence in Self.splitSentences(announcement.body) {
            guard results.count < Self.maxExtractionsPerAnnouncement else { break }
            guard Self.containsActionableVerb(sentence) else { continue }
            guard Self.containsDeadlineCue(sentence) else { continue }
            let dueAt = Self.resolveDueDate(in: sentence, now: now, calendar: calendar)
            let title = Self.title(from: sentence, fallback: announcement.title)
            results.append(ExtractedAssignment(title: title, dueAt: dueAt))
        }
        return results
    }

    // MARK: - Sentence splitting

    /// Splits on `.`, `!`, and newline. Deliberately not `?` — "Did everyone
    /// finish the reading?" is a rhetorical check-in, not an instruction, and
    /// treating `?` as a sentence terminator here wouldn't change that; it's
    /// omitted from the terminator set rather than special-cased because the
    /// verb+cue gate below already has to do the real filtering work.
    static func splitSentences(_ body: String) -> [String] {
        body
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Actionable-verb gate

    /// Single-word verbs matched by stem (`\bread\w*`), so "read", "reading"
    /// and "reads" all count — professors write "Reading due Friday" as often
    /// as "Please read chapter 3", and requiring the bare infinitive would
    /// miss the noun form that's arguably the more common phrasing in a
    /// one-line announcement. The word-boundary anchor at the *start* only
    /// (not both ends) is intentional: it must not match "unread" (no
    /// boundary immediately before "read" there), but "readings" should still
    /// count, so the end is left open.
    private static let stemVerbs = [
        "read", "finish", "complete", "submit", "bring",
        "review", "watch", "prepare", "post", "upload",
    ]

    /// Two-word verbs that don't stem cleanly ("turn in" isn't "turn" plus a
    /// suffix), matched as a literal phrase with flexible whitespace between
    /// the words.
    private static let phraseVerbs = ["turn in", "hand in"]

    static func containsActionableVerb(_ sentence: String) -> Bool {
        for verb in stemVerbs {
            if regexMatches("\\b\(NSRegularExpression.escapedPattern(for: verb))\\w*", in: sentence) {
                return true
            }
        }
        for phrase in phraseVerbs {
            let words = phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "\\b" + words.joined(separator: "\\s+") + "\\b"
            if regexMatches(pattern, in: sentence) {
                return true
            }
        }
        return false
    }

    // MARK: - Deadline-cue gate

    /// Single words that, on their own, mark a sentence as carrying a
    /// deadline: "due", "by", "before", "tonight", "today", "tomorrow".
    /// "before class" and "by class" from the brief are intentionally *not*
    /// a separate check — they already contain "before"/"by", which this
    /// list catches, so a dedicated phrase match would be redundant and
    /// would only add a second place for the two lists to drift apart.
    private static let cueWords = ["due", "by", "before", "tonight", "today", "tomorrow"]

    static func containsDeadlineCue(_ sentence: String) -> Bool {
        for word in cueWords {
            if regexMatches("\\b\(word)\\b", in: sentence) { return true }
        }
        if matchedWeekday(in: sentence) != nil { return true }
        if matchedMonthDay(in: sentence) != nil { return true }
        return false
    }

    // MARK: - Due-date resolution

    /// Tries the most specific cue first (an explicit calendar date beats a
    /// bare weekday name, which beats "tomorrow", which beats "today"/
    /// "tonight") so a sentence naming more than one kind of cue resolves to
    /// the one an author almost certainly meant to be authoritative. Returns
    /// `nil` when the sentence passed the deadline-cue gate on a cue this
    /// function doesn't know how to turn into a calendar date (bare "due" or
    /// "before class" with nothing else) — an undated `ExtractedAssignment`
    /// is a legal, useful result, not a failure.
    static func resolveDueDate(in sentence: String, now: Date, calendar: Calendar) -> Date? {
        if let date = explicitDate(in: sentence, now: now, calendar: calendar) {
            return endOfDay(date, calendar: calendar)
        }
        if let weekday = matchedWeekday(in: sentence) {
            return endOfDay(nextOccurrence(ofWeekday: weekday, from: now, calendar: calendar), calendar: calendar)
        }
        if regexMatches("\\btomorrow\\b", in: sentence) {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return endOfDay(tomorrow, calendar: calendar)
        }
        if regexMatches("\\btoday\\b", in: sentence) || regexMatches("\\btonight\\b", in: sentence) {
            return endOfDay(now, calendar: calendar)
        }
        return nil
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
    }

    /// `Calendar.component(.weekday, from:)` numbers Sunday...Saturday as
    /// 1...7, which is the numbering this returns so it can be handed
    /// straight to `nextOccurrence(ofWeekday:from:calendar:)` without a
    /// translation step.
    private static let weekdayNames = [
        1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
        5: "Thursday", 6: "Friday", 7: "Saturday",
    ]

    private static func matchedWeekday(in sentence: String) -> Int? {
        for (number, name) in weekdayNames {
            if regexMatches("\\b\(name)\\b", in: sentence) { return number }
        }
        return nil
    }

    /// "The NEXT occurrence of that weekday (if today is that weekday, use
    /// today)" — a delta of 0 is deliberately kept, not bumped to +7, since
    /// "bring your laptop Tuesday" posted on a Tuesday almost always means
    /// today, not a week from now.
    private static func nextOccurrence(ofWeekday weekday: Int, from now: Date, calendar: Calendar) -> Date {
        let today = calendar.component(.weekday, from: now)
        var delta = weekday - today
        if delta < 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: now) ?? now
    }

    /// Recognized month spellings, including the common abbreviations
    /// (`"Sept"` alongside `"Sep"` — Canvas professors use both). A fixed
    /// dictionary rather than a fuzzy prefix match: prefix matching "sep" as
    /// a stand-in for "September" is exactly the kind of cleverness that
    /// silently mis-parses the day something like "sepia" or "September's"
    /// gets fed through, for a feature where a wrong date is worse than a
    /// missed one.
    private static let monthNumbers: [String: Int] = [
        "jan": 1, "january": 1,
        "feb": 2, "february": 2,
        "mar": 3, "march": 3,
        "apr": 4, "april": 4,
        "may": 5,
        "jun": 6, "june": 6,
        "jul": 7, "july": 7,
        "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10,
        "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]

    /// Matches "September 12", "Sept. 12", "Sep 12th" and the numeric "9/12"
    /// form the brief asks for. No year in either pattern — Canvas
    /// announcements essentially never state one, since "this semester" is
    /// implicit — so the year is inferred from `now` and rolled forward a
    /// year when the resolved date would otherwise land more than 30 days in
    /// the past (see `buildDate(month:day:now:calendar:)`).
    static func explicitDate(in sentence: String, now: Date, calendar: Calendar) -> Date? {
        guard let (month, day) = matchedMonthDay(in: sentence) else { return nil }
        return buildDate(month: month, day: day, now: now, calendar: calendar)
    }

    /// Pure pattern match — no `now`/`calendar` involved — so it can double
    /// as the deadline-cue check (which only needs "is a date mentioned at
    /// all") without pulling in the year-inference logic that belongs to
    /// resolution, not detection.
    private static func matchedMonthDay(in sentence: String) -> (month: Int, day: Int)? {
        let nsSentence = sentence as NSString

        let monthPattern = "\\b(" + monthNumbers.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|") + ")\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?\\b"
        if let regex = try? NSRegularExpression(pattern: monthPattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: sentence, range: NSRange(location: 0, length: nsSentence.length)),
           match.numberOfRanges >= 3 {
            let monthText = nsSentence.substring(with: match.range(at: 1)).lowercased()
            let dayText = nsSentence.substring(with: match.range(at: 2))
            if let month = monthNumbers[monthText], let day = Int(dayText), (1...31).contains(day) {
                return (month, day)
            }
        }

        // Numeric "M/D" — deliberately no "/Y" suffix support, since the
        // brief's examples ("9/12") never carry a year and a bare two-digit
        // trailing number after a second slash is more likely a fraction
        // ("3/4 of the class") than a date once a year is involved.
        let numericPattern = "\\b(\\d{1,2})/(\\d{1,2})\\b"
        if let regex = try? NSRegularExpression(pattern: numericPattern),
           let match = regex.firstMatch(in: sentence, range: NSRange(location: 0, length: nsSentence.length)),
           match.numberOfRanges >= 3 {
            let monthText = nsSentence.substring(with: match.range(at: 1))
            let dayText = nsSentence.substring(with: match.range(at: 2))
            if let month = Int(monthText), let day = Int(dayText),
               (1...12).contains(month), (1...31).contains(day) {
                return (month, day)
            }
        }

        return nil
    }

    /// Builds a midnight date for `month`/`day` in `now`'s year, rolling
    /// forward one year when that lands more than 30 days before `now`. The
    /// 30-day slack (rather than "any date in the past") is deliberate: an
    /// announcement posted September 5th saying "due September 1st" is very
    /// plausibly describing a date days ago (a late add, a make-up
    /// deadline) and shouldn't be silently reinterpreted as next year; a date
    /// months in the past almost certainly means "this date, next
    /// occurrence" instead, most likely because the current year has already
    /// passed it — e.g. a January announcement mentioning "due December 3"
    /// meaning the upcoming December, not one nine months gone.
    private static func buildDate(month: Int, day: Int, now: Date, calendar: Calendar) -> Date? {
        let year = calendar.component(.year, from: now)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let candidate = calendar.date(from: components) else { return nil }

        let daysInPast = calendar.dateComponents([.day], from: candidate, to: now).day ?? 0
        guard daysInPast > 30 else { return candidate }

        components.year = year + 1
        return calendar.date(from: components) ?? candidate
    }

    // MARK: - Title

    /// The actionable sentence, trimmed and normalized, becomes the title;
    /// a degenerate sentence (too short to be a meaningful label once
    /// trimmed — e.g. a lone "Submit." after aggressive sentence splitting)
    /// falls back to the announcement's own title instead of putting
    /// something unreadable on the dashboard.
    static func title(from sentence: String, fallback: String) -> String {
        var trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, ".,;:!?".contains(last) {
            trimmed.removeLast()
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= 8 else { return fallback }

        if trimmed.count > 80 {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: 80)
            trimmed = String(trimmed[..<cutoff]).trimmingCharacters(in: .whitespaces)
        }

        if let first = trimmed.first {
            trimmed.replaceSubrange(trimmed.startIndex...trimmed.startIndex, with: String(first).uppercased())
        }
        return trimmed
    }

    // MARK: - Regex helper

    /// Every pattern here is built fresh per call rather than cached in a
    /// stored `static let` — matching the convention `CanvasModulesClient
    /// .parseDate` and friends already use for `ISO8601DateFormatter`.
    /// `NSRegularExpression` is in fact immutable and thread-safe once
    /// built, and elsewhere in this package (`SyllabusParser`,
    /// `CanvasAnnouncementsClient`) cached `static let` patterns are the
    /// convention. Building per call here is a choice, not a necessity:
    /// this extractor runs a handful of times per sync, never hot enough
    /// for compilation cost to matter, and per-call construction keeps the
    /// type trivially `Sendable` without leaning on Foundation's
    /// thread-safety documentation at all.
    private static func regexMatches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
