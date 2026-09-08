import Foundation

/// Free, deterministic, offline extraction: no network call, no API key,
/// no per-announcement cost. This is the default backend —
/// `ClaudeAnnouncementExtractor` / `BackendAnnouncementExtractor` exist for
/// announcements this one can't make sense of, not the other way around.
///
/// **Design stance: false positives are worse than false negatives.** A
/// missed assignment is invisible — the student never notices the dashboard
/// didn't catch it, and Canvas's own assignment/ICS feed is very likely to
/// carry the same due date anyway once the professor actually creates the
/// graded item. A *wrong* assignment — one this extractor invented from an
/// announcement that was actually just "office hours moved to 3pm" — sits on
/// the dashboard next to real deadlines and erodes the one thing this app is
/// for: trusting the "what's due next" list. Every threshold below is chosen
/// to be conservative for that reason.
///
/// **The bug this file was rewritten to fix.** The announcement "Thursday
/// Slides (9/3) Posted" / "The slides discussed today have been posted." was
/// turned into an assignment due 11:59 PM and then shown overdue. The old
/// gate was "any action verb (matched by bare word stem, including `post`)
/// AND any deadline cue (including a bare `today`)" — it never asked *who*
/// the verb applied to, what voice the sentence was in, or whether the
/// "deadline" word was actually attached to a deadline. "Slides ... have
/// been posted" matched the verb list on `post` and the cue list on `today`,
/// and nothing downstream could tell that apart from "please submit the
/// essay due today." The fix below adds three things the old code had none
/// of: an upfront "this whole announcement is informational, not a task"
/// filter (`isLikelyInformational`), a voice/addressee check before a verb
/// is allowed to count at all (`isStudentDirected` — passive and first-person
/// sentences are rejected outright, and `post`/`posted` was removed from the
/// verb list entirely rather than patched, since "X was posted" is *never*
/// something the student does), and a submission/preparation split
/// (`ExtractedTaskKind`) so that even a correctly-detected "bring a
/// calculator" can never become a graded item shown overdue.
///
/// **Why this only does sentence-level pattern matching, not real NLP.** A
/// full parser (dependency parsing, NER for dates) would catch more phrasing
/// but is exactly the kind of thing that quietly regresses when Canvas
/// professors write in ways nobody tested against — and this package has no
/// on-device ML dependency to begin with (CLAUDE.md: no third-party SDKs).
/// The backend extractor is the escape hatch for phrasing this one can't
/// reach; this one only needs to be right when it fires, not fire on
/// everything.
public struct HeuristicAnnouncementExtractor: AnnouncementAssignmentExtractor {
    /// Never store `Date()`/`.current` as extraction state — everything here
    /// is driven by the `now` parameter `extract(from:now:)` receives, so a
    /// test can fix "today" and get deterministic weekday/relative-date math.
    /// The caller is responsible for setting `calendar.timeZone` — this type
    /// no longer takes a separate `timeZone` parameter, since a `Calendar`
    /// that doesn't already carry the right time zone would make every
    /// weekday/relative-date computation here wrong regardless of what else
    /// was passed in.
    private let calendar: Calendar
    /// This course's scheduled class meetings, used only to resolve
    /// "before class on Thursday" style phrasing to an actual clock time
    /// (`resolveDueDate`). Empty by default — and always empty until the
    /// backend's catalog sync has actually run for this course — in which
    /// case class-time resolution simply never fires and the older
    /// end-of-day fallback takes over, exactly as it did before this
    /// existed.
    private let meetings: [ClassMeeting]

    public init(calendar: Calendar = .current, meetings: [ClassMeeting] = []) {
        self.calendar = calendar
        self.meetings = meetings
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
        guard !Self.isLikelyInformational(title: announcement.title, body: announcement.body) else {
            return []
        }

        var results: [ExtractedAssignment] = []
        for sentence in Self.splitSentences(announcement.body) {
            guard results.count < Self.maxExtractionsPerAnnouncement else { break }
            guard let kind = Self.taskKind(of: sentence) else { continue }
            guard Self.isStudentDirected(sentence) else { continue }
            guard Self.containsDeadlineCue(sentence) else { continue }
            let dueAt = Self.resolveDueDate(in: sentence, now: now, calendar: calendar, meetings: meetings)
            let title = Self.title(from: sentence, fallback: announcement.title)
            results.append(ExtractedAssignment(title: title, dueAt: dueAt, kind: kind))
        }
        return results
    }

    /// A cheap, deliberately *generous* pre-filter — any student-directed
    /// verb OR any deadline cue, anywhere in the text, with none of
    /// `extract`'s stricter per-sentence AND-of-three-conditions gating —
    /// used to decide whether an announcement is even worth paying to send
    /// to the AI backend (`AppState.announcementAIEnabled`'s spend control).
    /// Being generous here is deliberate and asymmetric with the rest of this
    /// file: false positives cost a fraction of a cent and get a second,
    /// more careful look from the model; false negatives mean an
    /// announcement never reaches the accurate backend at all. The one thing
    /// this shares with `extract` is the informational filter — an
    /// announcement this file can already tell is "the slides were posted"
    /// has nothing worth paying to double-check.
    public static func mightContainTask(title: String, body: String) -> Bool {
        guard !isLikelyInformational(title: title, body: body) else { return false }
        for sentence in splitSentences(body) {
            if taskKind(of: sentence) != nil { return true }
            if containsDeadlineCue(sentence) { return true }
        }
        return false
    }

    // MARK: - Sentence splitting

    /// Splits on `.`, `!`, and newline. Deliberately not `?` — "Did everyone
    /// finish the reading?" is a rhetorical check-in, not an instruction, and
    /// treating `?` as a sentence terminator here wouldn't change that; it's
    /// omitted from the terminator set rather than special-cased because the
    /// gates below already have to do the real filtering work. Also
    /// deliberately not `;` — a semicolon-joined run-on ("Grades have been
    /// released; please review them by Friday.") is kept as one sentence, so
    /// an informational clause and an actionable clause sharing one
    /// semicolon both live or die together under `isLikelyInformational`
    /// rather than needing a second splitter to drift out of sync with this
    /// one.
    static func splitSentences(_ body: String) -> [String] {
        protectAbbreviationPeriods(in: body)
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "\n" })
            .map { String($0).replacingOccurrences(of: abbreviationPeriodPlaceholder, with: ".").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "ch." and "pp." — the exact two abbreviated forms this file's own
    /// `isPreparationVerb`/`isSubmissionVerb` content-word lists recognize
    /// alongside "chapter" and "pages" — are not sentence boundaries. Naive
    /// period-splitting would otherwise cut "Read pp. 40-55 for Monday" into
    /// "Read pp" (has the verb, but now no deadline cue) and "40-55 for
    /// Monday" (has the cue, but now no verb): two fragments, neither of
    /// which can pass this file's gates, silently turning a real reading
    /// assignment into nothing. The list is deliberately short — just the
    /// two abbreviations this file's own vocabulary already depends on, not
    /// a general abbreviation list (no "Mr.", "etc.", "No.") — because a
    /// broader list risks merging two genuinely separate sentences that
    /// happen to end in one of those words, which is exactly the kind of
    /// false positive this file's whole design stance treats as worse than
    /// a missed one.
    private static let abbreviationsBeforePeriod = ["pp", "ch"]
    private static let abbreviationPeriodPlaceholder = "\u{2024}" // ONE DOT LEADER — never appears in real announcement text.

    private static func protectAbbreviationPeriods(in body: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b(" + abbreviationsBeforePeriod.joined(separator: "|") + ")\\.",
            options: [.caseInsensitive]
        ) else { return body }
        let range = NSRange(location: 0, length: (body as NSString).length)
        return regex.stringByReplacingMatches(in: body, range: range, withTemplate: "$1\(abbreviationPeriodPlaceholder)")
    }

    // MARK: - Informational filter

    /// True when the announcement's title or first sentence reads as "here
    /// is something that already happened" rather than "here is something to
    /// do" — slides/notes/recordings/grades being posted, a room or office
    /// hours moving, a class being cancelled. Checked once per announcement,
    /// before any sentence-level extraction runs, so it can't be defeated by
    /// an unrelated later sentence happening to contain a verb+cue pair.
    ///
    /// The gap between the subject noun and the posting verb
    /// (`.{0,40}?`) is deliberate, not a loose match tightened later: real
    /// announcements put things between them — "Thursday Slides (9/3)
    /// Posted" has a parenthetical date, "The slides discussed today have
    /// been posted" has an entire relative clause. A pattern requiring the
    /// noun and verb to be adjacent would miss both of the sentences that
    /// motivated this rewrite.
    public static func isLikelyInformational(title: String, body: String) -> Bool {
        let firstSentence = splitSentences(body).first ?? body
        return matchesInformationalPattern(title) || matchesInformationalPattern(firstSentence)
    }

    private static let informationalPatterns: [String] = [
        #"\b(slides|notes|recording|lecture video|handout|solutions|grades|scores|feedback)\b.{0,40}?\b(posted|uploaded|available|up|out|released|online)\b"#,
        #"\broom change\b"#,
        #"\blocation change\b"#,
        #"\boffice hours\b.{0,20}?\b(moved|changed|cancel\w*)\b"#,
        #"\bclass\b.{0,10}?\bcancel\w*\b"#,
        #"\bno class\b"#,
        #"\breminder:\s*(no|there is no)\b"#,
    ]

    private static func matchesInformationalPattern(_ text: String) -> Bool {
        informationalPatterns.contains { regexMatches($0, in: text) }
    }

    // MARK: - Task kind (submission vs. preparation) and the verb gate

    /// The verb (or verb-shaped absence of one — a bare "is due") a sentence
    /// carries, or `nil` when nothing here recognizes it as actionable at
    /// all. `"post"`/`"posted"` is deliberately absent from every list below
    /// — see this file's header comment — where the old code had it as a
    /// bare stem match.
    static func taskKind(of sentence: String) -> ExtractedTaskKind? {
        let lower = sentence.lowercased()
        if let kind = explicitVerbKind(lower) { return kind }
        // No listed verb, but the sentence still says something is "due" —
        // "Homework 2 is due Friday at 11:59pm" never uses an imperative verb
        // at all, yet is as unambiguous a submission as this extractor will
        // ever see. `\bdue\b` naturally excludes "overdue" (no word boundary
        // between the 'r' and the 'd'), so a professor mentioning a
        // previously-missed, already-overdue item doesn't get a fresh one
        // minted from the same word.
        if regexMatches(#"\bdue\b"#, in: lower) { return .submission }
        return nil
    }

    private static func explicitVerbKind(_ lower: String) -> ExtractedTaskKind? {
        if isSubmissionVerb(lower) { return .submission }
        if isPreparationVerb(lower) { return .preparation }
        return nil
    }

    /// `submit`, `turn in`, `hand in`, `upload`, `fill out` are unconditional
    /// — there is no context in which "please submit the essay" isn't about
    /// handing something in. `complete` and `take` are gated on a nearby
    /// coursework noun (`complete the dishes` isn't a pset; `take a seat`
    /// isn't a quiz) — the same reasoning as the old code's verb+cue AND,
    /// applied one level down to a single ambiguous verb instead of the
    /// whole sentence.
    private static func isSubmissionVerb(_ lower: String) -> Bool {
        if regexMatches(#"\bsubmit\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bturn\s+in\b"#, in: lower) { return true }
        if regexMatches(#"\bhand\s+in\b"#, in: lower) { return true }
        if regexMatches(#"\bupload\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bfill\s+out\b"#, in: lower) { return true }
        if regexMatches(#"\bcomplete\w*\b"#, in: lower),
           regexMatches(#"\b(quiz|survey|form|assignment|problem set|pset|homework|hw|lab report)\b"#, in: lower) {
            return true
        }
        if regexMatches(#"\btake\b"#, in: lower),
           regexMatches(#"\b(quiz|survey|poll)\b"#, in: lower) {
            return true
        }
        return false
    }

    /// `finish` is gated the same way `complete` is above ("finish your
    /// coffee" isn't a reading assignment); everything else here has nothing
    /// to submit even when unconditional, which is the entire point of
    /// `ExtractedTaskKind.preparation` existing.
    private static func isPreparationVerb(_ lower: String) -> Bool {
        if regexMatches(#"\bread\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bfinish\w*\b"#, in: lower),
           regexMatches(#"\b(reading|chapter|ch|pages|pp|article|book)\b"#, in: lower) {
            return true
        }
        if regexMatches(#"\breview\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bwatch\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bprepare\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bbring\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bstudy\w*\b"#, in: lower) { return true }
        if regexMatches(#"\blook\s+over\b"#, in: lower) { return true }
        if regexMatches(#"\bskim\w*\b"#, in: lower) { return true }
        if regexMatches(#"\bprint\w*\b"#, in: lower) { return true }
        return false
    }

    /// Every verb stem/phrase recognized above, combined into one
    /// alternation. Shared by `startsWithImperativeVerb` (is the sentence's
    /// *first* word one of these) and the "please <verb>" phrase check in
    /// `containsDirectedPhrase` — both need "is this word one of our verbs,"
    /// neither needs `isSubmissionVerb`/`isPreparationVerb`'s extra
    /// content-noun gating, so this is a separate, smaller list rather than
    /// a call back into either of those (which would also risk the
    /// `isStudentDirected` ⇄ `isSubmissionVerb` circularity the "upload only
    /// when student-directed" note in the brief was steering away from: the
    /// directedness check cannot depend on a verb classifier that itself
    /// depends on directedness).
    private static let actionVerbAlternation: String = {
        let stems = [
            "submit", "upload", "complete", "take", "read", "finish",
            "review", "watch", "prepare", "bring", "study", "skim", "print",
        ].map { NSRegularExpression.escapedPattern(for: $0) + "\\w*" }
        let phrases = ["turn\\s+in", "hand\\s+in", "fill\\s+out", "look\\s+over"]
        return (stems + phrases).joined(separator: "|")
    }()

    // MARK: - Directedness (voice / addressee) gate

    /// True when the sentence is phrased as an instruction to the student —
    /// an imperative ("Read chapter 3"), a "please <verb>"/"make sure to
    /// <verb>" softened imperative, or an explicit "you/everyone/students
    /// should/must/need to" — and false for passive voice ("the slides have
    /// been posted") or first person ("I posted the slides", "we will cover
    /// chapter 4"), which win outright over any imperative-looking prefix a
    /// sentence might also contain. This is the check the old extractor
    /// never had at all: it asked "does an action verb appear anywhere,"
    /// never "is the sentence actually telling the student to do it."
    static func isStudentDirected(_ sentence: String) -> Bool {
        let lower = sentence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if isPassiveVoice(lower) { return false }
        if isFirstPerson(lower) { return false }
        if startsWithImperativeVerb(lower) { return true }
        if containsDirectedPhrase(lower) { return true }
        return false
    }

    private static func isPassiveVoice(_ lower: String) -> Bool {
        regexMatches(
            #"\b(has|have|had|is|are|was|were|been|be|being)\s+(\w+\s+)?(posted|uploaded|released|published|discussed|covered|recorded|graded|returned|shared|sent)\b"#,
            in: lower
        )
    }

    /// "I posted the slides for today" and "we will cover chapter 4" — a
    /// first-person pronoun followed, within up to three intervening words,
    /// by one of the same posting/covering verbs the passive check uses.
    /// Matched by stem (`cover\w*`) rather than the exact inflection the
    /// passive list uses, since "we will cover" is present tense, not
    /// passive, and wouldn't match `isPassiveVoice` at all.
    private static func isFirstPerson(_ lower: String) -> Bool {
        let verbs = ["post", "upload", "release", "publish", "discuss", "cover", "record", "grade", "return", "share", "send"]
            .map { NSRegularExpression.escapedPattern(for: $0) + "\\w*" }
            .joined(separator: "|")
        let pattern = "\\b(i|i've|i'll|i'm|we|we've|we'll|we're)\\b(?:\\s+\\S+){0,3}\\s+(\(verbs))\\b"
        return regexMatches(pattern, in: lower)
    }

    private static func startsWithImperativeVerb(_ lower: String) -> Bool {
        regexMatches("^(\(actionVerbAlternation))", in: lower)
    }

    /// Phrases that address the student without necessarily starting the
    /// sentence with a bare verb. `\b(is|are)\s+due\b` is not in the brief's
    /// original phrase list, but is added here for the same reason
    /// `taskKind`'s bare-`due` fallback exists: "Homework 2 is due Friday"
    /// has no imperative verb and no "please," yet is unambiguously
    /// addressed at every student in the course, and without this the
    /// `taskKind` fallback above would be reachable but never actually pass
    /// the directedness gate.
    private static func containsDirectedPhrase(_ lower: String) -> Bool {
        let patterns = [
            "\\bplease\\s+(\(actionVerbAlternation))\\b",
            #"\bmake sure (to|you)\b"#,
            #"\bremember to\b"#,
            #"\bdon'?t forget to\b"#,
            #"\bbe sure to\b"#,
            #"\byou (should|need to|must|will need to|have to|are expected to)\b"#,
            #"\beveryone (should|must|needs to)\b"#,
            #"\bstudents (should|must|need to)\b"#,
            #"\b(is|are)\s+due\b"#,
        ]
        return patterns.contains { regexMatches($0, in: lower) }
    }

    // MARK: - Deadline-cue gate

    /// Single words that, on their own, mark a sentence as carrying a
    /// deadline: "due", "by", "before", "deadline", "until". "no later than"
    /// is matched as its own phrase since it doesn't stem from any of these.
    /// "today"/"tonight"/"tomorrow" are handled separately
    /// (`relativeDayCueCounts`) since, unlike every other cue here, they only
    /// count when they're actually attached to a deadline — see that
    /// function's comment.
    private static let cueWords = ["due", "by", "before", "deadline", "until"]

    static func containsDeadlineCue(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        for word in cueWords {
            if regexMatches("\\b\(word)\\b", in: lower) { return true }
        }
        if regexMatches(#"\bno later than\b"#, in: lower) { return true }
        // A bare weekday name is always a cue regardless of what surrounds
        // it ("Tuesday's exam," "for Monday," "before class on Thursday");
        // there's no phrasing where naming a specific day of the week in an
        // announcement isn't pointing at a deadline of some kind.
        if matchedWeekday(in: sentence) != nil { return true }
        if matchedMonthDay(in: sentence) != nil { return true }
        if regexMatches(#"\b(before|in|for|next)\s+class\b"#, in: lower) { return true }
        if regexMatches(#"\bat the start of class\b"#, in: lower) { return true }
        if relativeDayCueCounts(lower) { return true }
        return false
    }

    /// "Today"/"tonight"/"tomorrow" are common in purely informational
    /// announcements too ("today's recording is available," "I posted the
    /// slides for today" — both from this file's own test fixtures), so
    /// unlike every other cue above they only count when they're actually
    /// doing deadline work: immediately preceded by a cue word ("by
    /// tonight", "due today", "end of today") or followed by a clock time
    /// ("today at 5"). A bare "today" with neither is far more often a
    /// timestamp on something that already happened than a deadline.
    private static func relativeDayCueCounts(_ lower: String) -> Bool {
        for word in ["today", "tonight", "tomorrow"] {
            guard regexMatches("\\b\(word)\\b", in: lower) else { continue }
            if regexMatches("\\b(by|before|due|until|deadline|end of)\\s+\(word)\\b", in: lower) { return true }
            if regexMatches("\\b\(word)\\s+at\\s+\\d", in: lower) { return true }
        }
        return false
    }

    // MARK: - Due-date resolution

    /// Tries the most specific cue first: an explicit calendar date beats a
    /// class-meeting time, which beats a bare weekday name, which beats
    /// "tomorrow", which beats "today"/"tonight". Returns `nil` when the
    /// sentence passed the deadline-cue gate on a cue this function doesn't
    /// know how to turn into a calendar date (bare "due" or "before class"
    /// with nothing else and no known meetings) — an undated
    /// `ExtractedAssignment` is a legal, useful result, not a failure.
    ///
    /// For `.preparation` items, an explicit clock time in the sentence
    /// ("by 5pm", "at 11:59") overrides whatever time-of-day the day-level
    /// resolution above picked. `.submission` items never get this
    /// treatment — they always resolve to 23:59 on the resolved day
    /// (`endOfDay`), the same "due end of day unless we know better"
    /// default this extractor has always used, so a submission clock time
    /// that happens to already be 11:59pm (as in this file's own "Homework
    /// 2... by 11:59pm" fixture) changes nothing.
    static func resolveDueDate(in sentence: String, now: Date, calendar: Calendar, meetings: [ClassMeeting] = []) -> Date? {
        var resolved: Date?

        if let date = explicitDate(in: sentence, now: now, calendar: calendar) {
            resolved = endOfDay(date, calendar: calendar)
        } else if let classDate = classMeetingDate(in: sentence, now: now, calendar: calendar, meetings: meetings) {
            resolved = classDate
        } else if let weekday = matchedWeekday(in: sentence) {
            resolved = endOfDay(nextOccurrence(ofWeekday: weekday, from: now, calendar: calendar), calendar: calendar)
        } else if regexMatches(#"\btomorrow\b"#, in: sentence) {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            resolved = endOfDay(tomorrow, calendar: calendar)
        } else if regexMatches(#"\btoday\b"#, in: sentence) || regexMatches(#"\btonight\b"#, in: sentence) {
            resolved = endOfDay(now, calendar: calendar)
        }

        guard let day = resolved else { return nil }
        if taskKind(of: sentence) == .preparation, let withClockTime = applyClockTime(sentence: sentence, to: day, calendar: calendar) {
            return withClockTime
        }
        return day
    }

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
    }

    /// Nouns that, paired with a named weekday, mean "this is talking about
    /// a scheduled class session on that day" and should resolve to the
    /// meeting's actual start time rather than end-of-day. The brief this
    /// file was written against named only "class|lecture|section," but two
    /// of its own fixed test fixtures — "Bring a calculator to Tuesday's
    /// exam" and "review the practice problems before the midterm on
    /// Thursday" — need a meeting-time resolution despite naming neither
    /// word, so `exam`/`midterm`/`quiz`/`discussion`/`recitation` were added
    /// to reach the specified outputs. A bare weekday with *none* of these
    /// nouns ("Read pp. 40-55 for Monday") still falls through to
    /// end-of-day, unchanged — see `classMeetingDate`'s comment for why that
    /// case is deliberately left ambiguous rather than guessed at.
    private static let classEventNouns = ["class", "lecture", "section", "exam", "midterm", "quiz", "discussion", "recitation"]

    /// Resolves "before class," "before class on Thursday," "bring a
    /// calculator to Tuesday's exam" to the actual start time of the
    /// matching class meeting, when one is known.
    ///
    /// Two ways in: a bare class-session phrase ("before class", "in class",
    /// "for class", "next class", "at the start of class") with no weekday
    /// named, which resolves to the *next* meeting after `now` regardless of
    /// which day that falls on; or a named weekday paired with one of
    /// `classEventNouns`, which resolves to that meeting on that specific
    /// weekday. Either way, `meetings` empty (no catalog synced for this
    /// course yet) or no meeting actually falling on the named weekday both
    /// fall through to `nil` here, letting the caller's plain
    /// weekday/tomorrow/today chain take over instead — the same
    /// "conservative when uncertain" stance as the rest of this file. A bare
    /// weekday with no event noun at all ("Read pp. 40-55 for Monday") never
    /// reaches this function's weekday branch in the first place, by design
    /// — see `classEventNouns`'s comment.
    private static func classMeetingDate(in sentence: String, now: Date, calendar: Calendar, meetings: [ClassMeeting]) -> Date? {
        guard !meetings.isEmpty else { return nil }
        let lower = sentence.lowercased()

        if let weekday = matchedWeekday(in: sentence) {
            let hasEventNoun = classEventNouns.contains { regexMatches("\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", in: lower) }
            guard hasEventNoun else { return nil }
            let dayMeetings = meetings.filter { $0.weekday == weekday }
            guard let meeting = preferLecture(dayMeetings) else { return nil }
            let day = nextOccurrence(ofWeekday: weekday, from: now, calendar: calendar)
            return setStartTime(of: meeting, on: day, calendar: calendar)
        }

        let barePhrase = regexMatches(#"\b(before|in|for|next)\s+class\b"#, in: lower)
            || regexMatches(#"\bat the start of class\b"#, in: lower)
        guard barePhrase, let next = nextMeeting(after: now, in: meetings, calendar: calendar) else { return nil }
        return setStartTime(of: next.meeting, on: next.date, calendar: calendar)
    }

    /// Among a day's meetings, prefers the lecture over a lab/recitation —
    /// "before class" almost always means the main lecture, and a course
    /// with more than one meeting type on the same day (rare, but possible
    /// for e.g. a lecture immediately followed by a discussion section) is
    /// far more likely to be asked about via its lecture.
    private static func preferLecture(_ meetings: [ClassMeeting]) -> ClassMeeting? {
        meetings.first { $0.activity.uppercased() == "LEC" } ?? meetings.first
    }

    private static func setStartTime(of meeting: ClassMeeting, on day: Date, calendar: Calendar) -> Date {
        let hour = meeting.startMinutes / 60
        let minute = meeting.startMinutes % 60
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// The chronologically nearest meeting at or after `now`, across every
    /// section this course has — used only for a bare "before class"/"next
    /// class" with no weekday named, where "the next time this course
    /// meets" is the only sensible reading.
    private static func nextMeeting(after now: Date, in meetings: [ClassMeeting], calendar: Calendar) -> (meeting: ClassMeeting, date: Date)? {
        var best: (meeting: ClassMeeting, date: Date)?
        for meeting in meetings {
            let day = nextOccurrence(ofWeekday: meeting.weekday, from: now, calendar: calendar)
            let candidate = setStartTime(of: meeting, on: day, calendar: calendar)
            let adjusted = candidate < now ? (calendar.date(byAdding: .day, value: 7, to: candidate) ?? candidate) : candidate
            if best == nil || adjusted < best!.date {
                best = (meeting: meeting, date: adjusted)
            }
        }
        return best
    }

    /// Parses the first `H(:MM)? am/pm` clock time in the sentence — "by
    /// 5pm", "at 11:59am" — and applies it to `date`'s hour/minute, leaving
    /// the day untouched. Returns `nil` when no clock time is present, so
    /// the caller's day-level resolution (end of day, or a class meeting's
    /// start time) is left as the answer.
    private static func applyClockTime(sentence: String, to date: Date, calendar: Calendar) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = sentence as NSString
        guard let match = regex.firstMatch(in: sentence, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges >= 4 else {
            return nil
        }
        var hour = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let minute = match.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: match.range(at: 2))) ?? 0) : 0
        let meridiem = ns.substring(with: match.range(at: 3)).lowercased()
        if meridiem == "pm", hour != 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// `Calendar.component(.weekday, from:)` numbers Sunday...Saturday as
    /// 1...7, which is the numbering this returns so it can be handed
    /// straight to `nextOccurrence(ofWeekday:from:calendar:)` (and to
    /// `ClassMeeting.weekday`) without a translation step.
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
