import Foundation

/// One exam a syllabus names next to a date.
public struct ExamCandidate: Sendable, Hashable {
    /// The exam as the syllabus wrote it: "Midterm 1", "Final Exam".
    public let name: String
    /// The day of the exam, or the exact moment when `hasTime`. Without a
    /// time this is midnight at the start of that day in the calendar the
    /// caller passed; it is a day, not a moment, and must be shown (and
    /// scheduled) as all-day. Nothing here ever invents a time: a syllabus
    /// that says "Midterm 1: Thursday, October 23" has not said when on the
    /// 23rd.
    public let date: Date
    public let hasTime: Bool
    /// The whole line the exam was read from, so a person can be shown why
    /// the app believes this.
    public let sourceLine: String
    /// Which exam it is, as `ExamIdentity` tells exams apart. `name` cannot be
    /// trusted to carry this on its own: it is only the phrase that names the
    /// exam, so "Makeup Midterm 1: Nov 5" has the name "Midterm 1" and the
    /// makeup lives in the words around it (`modifiers`). Reading the identity
    /// back out of `name` would file the makeup under the ordinary sitting's id.
    public let kind: ExamDetection.Kind
    /// The "1" of "Midterm 1"; nil for an unnumbered exam.
    public let ordinal: Int?
    /// `makeup`, `retake` or `alternate`, when the line says so.
    public let modifiers: Set<String>

    public init(
        name: String,
        date: Date,
        hasTime: Bool,
        sourceLine: String,
        kind: ExamDetection.Kind,
        ordinal: Int?,
        modifiers: Set<String>
    ) {
        self.name = name
        self.date = date
        self.hasTime = hasTime
        self.sourceLine = sourceLine
        self.kind = kind
        self.ordinal = ordinal
        self.modifiers = modifiers
    }
}

/// Reads exam dates out of syllabus text: the lines that name an exam next to
/// a date.
///
/// The input is plain text, as `HTMLText.plainText(from:)` or
/// `SyllabusTextExtractor` produce it: one paragraph, list item or table row
/// per line. A table row arrives as its cells joined by spaces (`HTMLText`
/// turns `<td>` into a space), or by pipes if a syllabus was pasted that way,
/// so both "Week 8 10/21 Midterm" and "Week 8 | 10/21 | Midterm" are read.
///
/// **Why this has its own date reader.** `HeuristicAnnouncementExtractor`
/// already resolves "September 12" and "9/12", but its helpers are private,
/// report no position, take no year, and pick the year by rolling forward
/// when a date is more than 30 days past. That last rule is right for an
/// announcement ("due Sept 1", posted Sept 5) and wrong for a syllabus, which
/// lists the whole term: on Oct 18 a syllabus line "Midterm 1: Sept 11" is
/// this fall's, five weeks ago, not next September's. So this reads the same
/// two shapes (month name and day, and M/D) and chooses the year itself.
///
/// **Choosing the year.** Syllabus dates rarely carry one. The three
/// candidates are the reference year and the years either side, and the
/// occurrence closest to `referenceDate` wins, because a term is a few months
/// long and `referenceDate` is inside it or just before it: across New Year
/// (reference Dec 28, "Midterm: Jan 25") that is January of the *next* year.
/// A weekday written beside the date ("Thursday, October 23") is checked
/// against each candidate first, which is what tells a recycled Canvas site
/// apart: its syllabus still says "Thursday, October 23" from 2025, and in
/// 2026 October 23 is a Friday, so the only year the weekday agrees with is a
/// year ago and the line is dropped rather than moved to a date the
/// instructor never wrote (see the recycled-site trap in CLAUDE.md). An
/// explicit year is trusted as written.
///
/// A date more than `staleAfterDays` before the reference is dropped as a
/// previous term's. A date earlier *this* term (Midterm 1, five weeks ago) is
/// kept: whether it is shown is the dashboard's decision, and a finished exam
/// belongs in "prev".
public enum SyllabusExamExtractor {

    /// A term is about 15 weeks, so anything older than this relative to
    /// `referenceDate` belongs to a previous term or a recycled site. Kept as
    /// a number of days (not "last semester") so tests and the caller can
    /// reason about it without a term calendar.
    static let staleAfterDays = 150

    public static func extract(
        text: String,
        referenceDate: Date,
        calendar: Calendar = .current,
        timeZone: TimeZone? = nil
    ) -> [ExamCandidate] {
        var calendar = calendar
        if let timeZone { calendar.timeZone = timeZone }

        var found: [ExamCandidate] = []
        // The same exam is often listed twice in one syllabus (the overview and
        // the weekly schedule). Same exam on the same day is one candidate;
        // when one copy carries a time and the other does not, the timed one
        // is kept.
        var indexByKey: [String: Int] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for clause in clauses(of: line) {
                for pairing in pairings(in: clause) {
                    guard let (date, hasTime) = resolve(pairing, referenceDate: referenceDate, calendar: calendar) else { continue }
                    let candidate = ExamCandidate(
                        name: displayName(pairing.mention.phrase),
                        date: date,
                        hasTime: hasTime,
                        sourceLine: line,
                        kind: pairing.mention.kind,
                        ordinal: pairing.mention.ordinal,
                        modifiers: pairing.mention.modifiers
                    )
                    let day = calendar.startOfDay(for: date).timeIntervalSinceReferenceDate
                    let key = [
                        pairing.mention.kind.rawValue,
                        pairing.mention.ordinal.map(String.init) ?? "-",
                        pairing.mention.modifiers.sorted().joined(separator: ","),
                        String(day),
                    ].joined(separator: "|")
                    if let existing = indexByKey[key] {
                        if hasTime && !found[existing].hasTime { found[existing] = candidate }
                    } else {
                        indexByKey[key] = found.count
                        found.append(candidate)
                    }
                }
            }
        }
        return found
    }

    // MARK: - Clauses

    /// Splits a line where a sentence ends or a semicolon sits, and nowhere
    /// else. Table cells (pipes, runs of spaces) must stay together because
    /// the exam and its date are in different cells of one row. The sentence
    /// break needs a capital letter after it, so "Nov. 20" and "Oct. 23"
    /// (a digit follows the period) are not broken in half.
    private static func clauses(of line: String) -> [String] {
        let broken = line
            .replacingOccurrences(of: ";", with: "\n")
            .replacingOccurrences(of: #"(?<=[.!?])\s+(?=[A-Z])"#, with: "\n", options: .regularExpression)
        return broken.components(separatedBy: "\n")
            .map { normalizeSpacing($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Folds every dash-like character to an ASCII hyphen and every
    /// no-break or exotic space to a plain space, one scalar for one scalar so
    /// no offset moves. The patterns below then need only `-`.
    ///
    /// Done by scalar instead of a regex with the characters inside it
    /// because CLAUDE.md's regex trap applies: a raw string would hand Swift's
    /// `\u{...}` to ICU, which does not read it.
    private static func normalizeSpacing(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2010...0x2015, 0x2212, 0xFE58, 0xFE63, 0xFF0D:
                scalars.append("-")
            case 0x00A0, 0x2007, 0x2009, 0x200A, 0x202F:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: - Pairing exams with dates

    private struct Pairing {
        let mention: ExamDetection.Mention
        let date: DateMatch
        /// Where in the clause to look for a clock time: the whole clause for
        /// a lone exam, this exam's own stretch when a clause lists several.
        let timeRegion: Range<String.Index>
        let clause: String
        /// The spans already spoken for (every exam phrase and date), blanked
        /// out before a time is searched for so the "1" of "Midterm 1" and
        /// the "23" of "Oct 23" are never read as an hour.
        let claimed: [Range<String.Index>]
    }

    /// One exam and one date per pairing.
    ///
    /// - A clause with one exam takes the nearest date, so "Final exam: Dec
    ///   15 (Dec 18 for conflicts)" is Dec 15.
    /// - A clause with several exams is only read when it alternates cleanly,
    ///   "Midterm 1: Oct 23, Midterm 2: Nov 20" or "Oct 23 Midterm 1, Nov 20
    ///   Midterm 2", and each exam takes its neighbour. "Midterms 1 and 2 are
    ///   on Oct 23 and Nov 20" is skipped: with no way to know which date goes
    ///   with which exam, a wrong pairing is worse than none.
    private static func pairings(in clause: String) -> [Pairing] {
        // A window of three words is how far a context word ("review",
        // "solutions", "practice") is allowed to be from an exam and still
        // cancel it, without letting an unrelated "review session" later in a
        // long line cancel a real midterm.
        let mentions = ExamDetection.mentions(in: clause, contextWindow: 3)
            .filter { !($0.isPlural && $0.ordinal == nil) }
        guard !mentions.isEmpty else { return [] }
        let dates = findDates(in: clause)
        guard !dates.isEmpty else { return [] }
        let claimed = mentions.map(\.range) + dates.map(\.range)

        if mentions.count == 1 {
            let mention = mentions[0]
            guard let date = nearest(to: mention.range, in: dates, clause: clause) else { return [] }
            return [Pairing(
                mention: mention, date: date,
                timeRegion: clause.startIndex..<clause.endIndex,
                clause: clause, claimed: claimed
            )]
        }

        guard mentions.count == dates.count else { return [] }
        enum Item { case mention(ExamDetection.Mention), date(DateMatch) }
        let ordered: [(Range<String.Index>, Item)] = (
            mentions.map { ($0.range, Item.mention($0)) } + dates.map { ($0.range, Item.date($0)) }
        ).sorted { $0.0.lowerBound < $1.0.lowerBound }
        var pairs: [(ExamDetection.Mention, DateMatch)] = []
        var i = 0
        while i + 1 < ordered.count {
            switch (ordered[i].1, ordered[i + 1].1) {
            case let (.mention(m), .date(d)), let (.date(d), .mention(m)):
                pairs.append((m, d))
            default:
                return []
            }
            i += 2
        }
        return pairs.enumerated().map { index, pair in
            let lower = min(pair.0.range.lowerBound, pair.1.range.lowerBound)
            let upper = index + 1 < pairs.count
                ? min(pairs[index + 1].0.range.lowerBound, pairs[index + 1].1.range.lowerBound)
                : clause.endIndex
            return Pairing(
                mention: pair.0, date: pair.1,
                timeRegion: lower..<upper,
                clause: clause, claimed: claimed
            )
        }
    }

    private static func nearest(to range: Range<String.Index>, in dates: [DateMatch], clause: String) -> DateMatch? {
        func gap(_ d: DateMatch) -> Int {
            if d.range.lowerBound >= range.upperBound {
                return clause.distance(from: range.upperBound, to: d.range.lowerBound)
            }
            return clause.distance(from: d.range.upperBound, to: range.lowerBound)
        }
        // On a tie the date after the exam wins: "Midterm 1: Oct 23" is far
        // more common than a date on each side.
        return dates.min { a, b in
            let ga = gap(a), gb = gap(b)
            if ga != gb { return ga < gb }
            return a.range.lowerBound > b.range.lowerBound
        }
    }

    /// "midterm exam" in a paragraph, "MIDTERM #1" in a heading: capitalise
    /// the first letter and otherwise leave the words as the syllabus wrote
    /// them. Re-casing the rest would turn "Exam II" into "Exam Ii".
    private static func displayName(_ phrase: String) -> String {
        guard let first = phrase.first else { return phrase }
        return first.uppercased() + phrase.dropFirst()
    }

    // MARK: - Dates

    private struct DateMatch {
        let range: Range<String.Index>
        let month: Int
        let day: Int
        let year: Int?
        let weekday: Int?
    }

    private static let monthNumbers: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]

    private static func compile(_ pattern: String) -> NSRegularExpression {
        // A literal checked by the test suite; a typo should fail loudly the
        // first time it runs, not quietly find no exams (the `try?` trap).
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // "Sept" before "sep" and "march" before "mar" so the longest spelling wins.
    private static let monthDayRegex = compile(
        #"\b(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec)\.?\s*(\d{1,2})(?:st|nd|rd|th)?\b(?:\s*,?\s*(20\d{2})\b)?"#
    )
    // Month/day with an optional year. The lookarounds keep "1/2/3" and
    // "3.5/4" from being read as dates.
    private static let numericRegex = compile(
        #"(?<![\d/.])(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?(?![\d/])"#
    )
    // "of", "pts", "%" after a slash pair mark a fraction or a score
    // ("Midterm 1/3 of the grade", "Exam 2 worth 1/4 points"), not a date.
    private static let fractionTailRegex = compile(#"^\s*(?:of\b|pts?\b|points?\b|%)"#)
    private static let weekdayWords = #"(sun(?:day)?|mon(?:day)?|tue(?:s(?:day)?)?|wed(?:nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?)"#
    private static let weekdayBeforeRegex = compile(#"\b"# + weekdayWords + #"\b\.?,?\s*$"#)
    private static let weekdayAfterRegex = compile(#"^\s*[,(]?\s*"# + weekdayWords + #"\b\)?"#)

    private static func findDates(in clause: String) -> [DateMatch] {
        let whole = NSRange(clause.startIndex..., in: clause)
        var matches: [DateMatch] = []

        for m in monthDayRegex.matches(in: clause, range: whole) {
            guard let range = Range(m.range, in: clause),
                  let monthRange = Range(m.range(at: 1), in: clause),
                  let dayRange = Range(m.range(at: 2), in: clause),
                  let month = monthNumbers[clause[monthRange].lowercased()],
                  let day = Int(clause[dayRange]), (1...31).contains(day)
            else { continue }
            let year = Range(m.range(at: 3), in: clause).flatMap { Int(clause[$0]) }
            matches.append(withWeekday(
                DateMatch(range: range, month: month, day: day, year: year, weekday: nil),
                in: clause
            ))
        }

        for m in numericRegex.matches(in: clause, range: whole) {
            guard let range = Range(m.range, in: clause),
                  let monthRange = Range(m.range(at: 1), in: clause),
                  let dayRange = Range(m.range(at: 2), in: clause),
                  let month = Int(clause[monthRange]), (1...12).contains(month),
                  let day = Int(clause[dayRange]), (1...31).contains(day)
            else { continue }
            let tailRange = NSRange(range.upperBound..<clause.endIndex, in: clause)
            if fractionTailRegex.firstMatch(in: clause, range: tailRange) != nil { continue }
            // A numeric date inside a month-name date ("Oct 2/3"?) would be
            // double counted; month-name matches win.
            if matches.contains(where: { $0.range.overlaps(range) }) { continue }
            var year = Range(m.range(at: 3), in: clause).flatMap { Int(clause[$0]) }
            if let y = year, y < 100 { year = 2000 + y }
            matches.append(withWeekday(
                DateMatch(range: range, month: month, day: day, year: year, weekday: nil),
                in: clause
            ))
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Picks up the weekday written directly before ("Thursday, October 23")
    /// or after ("Oct 23 (Thu)") a date and widens the date's span to cover
    /// it, so the later time search does not mistake it for anything.
    private static func withWeekday(_ date: DateMatch, in clause: String) -> DateMatch {
        var range = date.range
        var weekday: Int?

        // Searched in `clause` itself, over a bounded range, so every match
        // comes back as an index into `clause` (a copy of the prefix would
        // hand back indices into the copy). `$` and `^` anchor to the ends of
        // the range given, which is the point: "the weekday that ends right
        // where the date starts".
        let beforeRange = NSRange(clause.startIndex..<date.range.lowerBound, in: clause)
        let afterRange = NSRange(date.range.upperBound..<clause.endIndex, in: clause)
        if let m = weekdayBeforeRegex.firstMatch(in: clause, range: beforeRange),
           let whole = Range(m.range, in: clause),
           let word = Range(m.range(at: 1), in: clause) {
            weekday = weekdayNumber(String(clause[word]))
            range = whole.lowerBound..<range.upperBound
        } else if let m = weekdayAfterRegex.firstMatch(in: clause, range: afterRange),
                  let whole = Range(m.range, in: clause),
                  let word = Range(m.range(at: 1), in: clause) {
            weekday = weekdayNumber(String(clause[word]))
            range = range.lowerBound..<whole.upperBound
        }
        return DateMatch(range: range, month: date.month, day: date.day, year: date.year, weekday: weekday)
    }

    /// `Calendar`'s numbering: Sunday is 1.
    private static func weekdayNumber(_ word: String) -> Int? {
        switch word.lowercased().prefix(3) {
        case "sun": return 1
        case "mon": return 2
        case "tue": return 3
        case "wed": return 4
        case "thu": return 5
        case "fri": return 6
        case "sat": return 7
        default: return nil
        }
    }

    // MARK: - Resolving a pairing to a Date

    private static func resolve(_ pairing: Pairing, referenceDate: Date, calendar: Calendar) -> (Date, Bool)? {
        guard let day = resolveDay(pairing.date, referenceDate: referenceDate, calendar: calendar) else { return nil }
        guard let time = clockTime(in: pairing) else { return (day, false) }
        guard let moment = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) else {
            return (day, false)
        }
        return (moment, true)
    }

    /// The start of the day this date means, or nil when it cannot be
    /// trusted. See the type comment for the year rule.
    private static func resolveDay(_ match: DateMatch, referenceDate: Date, calendar: Calendar) -> Date? {
        let referenceYear = calendar.component(.year, from: referenceDate)
        let years = match.year.map { [$0] } ?? [referenceYear - 1, referenceYear, referenceYear + 1]

        var candidates: [Date] = []
        for year in years {
            guard let date = calendar.date(from: DateComponents(year: year, month: match.month, day: match.day)) else { continue }
            // `Calendar` rolls Feb 30 or a non-leap Feb 29 into March instead
            // of failing; a date the instructor could not have meant is not a
            // date.
            let back = calendar.dateComponents([.year, .month, .day], from: date)
            guard back.year == year, back.month == match.month, back.day == match.day else { continue }
            candidates.append(calendar.startOfDay(for: date))
        }

        if match.year == nil, let weekday = match.weekday {
            let agreeing = candidates.filter { calendar.component(.weekday, from: $0) == weekday }
            // No year agrees: a mistyped weekday, not a stale syllabus, so
            // fall back to ignoring it rather than discarding the exam.
            if !agreeing.isEmpty { candidates = agreeing }
        }

        guard let cutoff = calendar.date(byAdding: .day, value: -staleAfterDays, to: referenceDate) else { return nil }
        candidates = candidates.filter { $0 >= cutoff }

        // Closest to the reference wins; on a tie, the later one.
        return candidates.min { a, b in
            let da = abs(a.timeIntervalSince(referenceDate)), db = abs(b.timeIntervalSince(referenceDate))
            if da != db { return da < db }
            return a > b
        }
    }

    // MARK: - Clock time

    private static let timeRangeRegex = compile(
        #"\b(\d{1,2})(?::(\d{2}))?\s*(?:([ap])\.?m\.?)?\s*(?:-|to)\s*(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\b\.?"#
    )
    private static let timeRegex = compile(#"\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\b\.?"#)
    private static let noonRegex = compile(#"\bnoon\b"#)
    // 24-hour only from 13:00, where it cannot be anything else. "Exam 2: 6:00"
    // could be morning or evening and so is not a time at all.
    private static let twentyFourHourRegex = compile(#"\b(1[3-9]|2[0-3]):([0-5]\d)\b"#)

    /// The start time on this pairing's stretch of the clause, or nil. A
    /// range ("6-8 pm") yields its start. Nil is the common case and is
    /// correct: no time stated means all-day.
    private static func clockTime(in pairing: Pairing) -> (hour: Int, minute: Int)? {
        // Blank every claimed span with spaces (same length) so digits that
        // belong to an exam number or a date are not read as an hour.
        var chars = Array(pairing.clause)
        let base = pairing.clause.startIndex
        for span in pairing.claimed {
            let lower = pairing.clause.distance(from: base, to: span.lowerBound)
            let upper = pairing.clause.distance(from: base, to: span.upperBound)
            for i in lower..<min(upper, chars.count) { chars[i] = " " }
        }
        let lower = pairing.clause.distance(from: base, to: pairing.timeRegion.lowerBound)
        let upper = pairing.clause.distance(from: base, to: pairing.timeRegion.upperBound)
        let region = String(chars[lower..<min(upper, chars.count)])
        let whole = NSRange(region.startIndex..., in: region)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: region).map { String(region[$0]) }
        }

        if let m = timeRangeRegex.firstMatch(in: region, range: whole),
           let startHour = group(m, 1).flatMap(Int.init), let endHour = group(m, 4).flatMap(Int.init),
           (1...12).contains(startHour), (1...12).contains(endHour),
           let endMeridiem = group(m, 6)?.lowercased() {
            let minute = group(m, 2).flatMap(Int.init) ?? 0
            guard (0...59).contains(minute) else { return nil }
            var meridiem = group(m, 3)?.lowercased() ?? endMeridiem
            // "11-1 pm" starts at 11 in the morning, not 11 at night.
            if group(m, 3) == nil, endMeridiem == "p", startHour != 12, startHour > endHour { meridiem = "a" }
            return (to24(startHour, meridiem: meridiem), minute)
        }
        if let m = timeRegex.firstMatch(in: region, range: whole),
           let hour = group(m, 1).flatMap(Int.init), (1...12).contains(hour),
           let meridiem = group(m, 3)?.lowercased() {
            let minute = group(m, 2).flatMap(Int.init) ?? 0
            guard (0...59).contains(minute) else { return nil }
            return (to24(hour, meridiem: meridiem), minute)
        }
        if noonRegex.firstMatch(in: region, range: whole) != nil { return (12, 0) }
        if let m = twentyFourHourRegex.firstMatch(in: region, range: whole),
           let hour = group(m, 1).flatMap(Int.init), let minute = group(m, 2).flatMap(Int.init) {
            return (hour, minute)
        }
        return nil
    }

    private static func to24(_ hour: Int, meridiem: String) -> Int {
        if meridiem == "a" { return hour == 12 ? 0 : hour }
        return hour == 12 ? 12 : hour + 12
    }
}
