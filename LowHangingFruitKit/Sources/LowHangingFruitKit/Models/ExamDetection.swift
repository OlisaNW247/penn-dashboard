import Foundation

/// Which exam a title names, independent of how it was spelled or where it
/// came from. Two titles for the same sitting of the same course's exam
/// produce equal identities, which is what lets a Canvas item, an
/// announcement and a syllabus line collapse to one card.
///
/// **How this relates to `AssignmentDeduplicator`.** The deduper's
/// `assessmentIdentity` is the model: a *kind* plus a primary *ordinal* plus
/// the practice/retake/makeup modifiers, so "Midterm 1" and "Midterm 2" are
/// never one thing and a makeup is never the ordinary sitting. It works on
/// normalised token arrays and only recognises a bare integer after the kind
/// word, which is enough for "Take Quiz 2" against "Quiz 2" but not for what
/// an exam looks like across three sources: "MIDTERM #1", "Midterm Exam I",
/// "1st Midterm", "MT1", "Mid-term 1". This type reads the same shapes, adds
/// those spellings, and also covers the *unnumbered* exam ("Midterm", "Final
/// Exam") which the deduper deliberately leaves to its fuzzy tiers. It does
/// not replace the deduper and does not change it: the deduper still decides
/// whether two *assignments* are one; this decides whether two *exam
/// mentions* are one.
///
/// What it deliberately does not do: an unnumbered "Midterm" and a numbered
/// "Midterm 1" are **not** equal. They might be the same sitting (a course
/// with one midterm that Canvas numbers anyway), but equating them on
/// title alone would also fold "Midterm" into both "Midterm 1" and "Midterm
/// 2" of a course that has two. Whoever wires this into the dashboard should
/// treat that pair as "possibly the same, check the dates", not as equal.
public struct ExamIdentity: Hashable, Sendable {
    /// The course with spacing, punctuation, case and leading zeros removed
    /// ("PHYS 0151" and "phys 151" agree), so identities from sources that
    /// spell the course code differently still compare equal.
    public let course: String
    public let kind: ExamDetection.Kind
    /// The "1" of "Midterm 1". Nil for an unnumbered exam.
    public let ordinal: Int?
    /// `makeup`, `retake` or `alternate` when the title says so. These are
    /// part of identity: a makeup sitting is a different event from the
    /// ordinary one, exactly as in `AssignmentDeduplicator`.
    public let modifiers: Set<String>

    public init(course: String, kind: ExamDetection.Kind, ordinal: Int?, modifiers: Set<String>) {
        self.course = course
        self.kind = kind
        self.ordinal = ordinal
        self.modifiers = modifiers
    }
}

/// Decides whether a title names an exam, and which one.
///
/// "Exam" here means a sitting the student shows up for: a midterm, a final
/// exam, a prelim, a test. It is a stricter question than the dashboard's
/// older "assessment" rule (`AppState.isAssessment`, `WorkItem
/// .looksLikeAssessment`), which is a bare regex over the title and so also
/// says yes to "Practice Exam 2" and "Quiz 4" and "Exam solutions posted".
/// Those two keep their behaviour; the exam card has a louder visual
/// treatment than any other card, and a loud false positive is worse than a
/// quiet one.
///
/// **Whole words only.** The title is split into words first and the exam
/// nouns are matched as whole words, so "contest", "testing", "latest",
/// "examine" and "preliminary" are not exams. A substring regex gets every
/// one of those wrong.
///
/// **What turns a hit off** (each is a named set below, because the wrong
/// version of this is a growing regex nobody can reason about):
/// - *context words* anywhere in the title: quiz, practice, review, solutions,
///   grades, a cheat sheet. "Practice Exam 2" and "Midterm Review Session"
///   name an exam but are not one.
/// - *the word right after* the exam noun, when it says the thing is a
///   deliverable or a piece of information rather than a sitting: "Final
///   Project", "Final Paper", "Final Presentation", "Midterm Topics", "Exam
///   Policy", "Finals Week".
/// - *the word right before*: "no exams", "post-exam survey", "pre-exam".
/// - for the noun **test** only, programming and statistics senses: "test
///   cases", "unit test", "t-test", "hypothesis test".
public enum ExamDetection {

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case midterm, final, exam, test, prelim
    }

    // MARK: - Public surface

    /// True when `title` names a midterm, exam, final, prelim or test.
    public static func isExam(title: String) -> Bool {
        !mentions(in: title, contextWindow: nil).isEmpty
    }

    /// The one decision point the exam card and, later, the dashboard share:
    /// an explicit `override` (the dashboard will set it for an item it knows
    /// is an exam, e.g. one that came from an announcement or the syllabus
    /// under a title the heuristic would not recognise) wins; without one the
    /// title decides.
    public static func isExam(title: String, override: Bool?) -> Bool {
        override ?? isExam(title: title)
    }

    /// The identity of the first exam `title` names, or nil when it names
    /// none. See `ExamIdentity` for how this relates to the deduper.
    public static func examIdentity(title: String, course: String) -> ExamIdentity? {
        guard let mention = mentions(in: title, contextWindow: nil).first else { return nil }
        return ExamIdentity(
            course: normalizedCourse(course),
            kind: mention.kind,
            ordinal: mention.ordinal,
            modifiers: mention.modifiers
        )
    }

    /// Lowercase letters and digits only, with leading zeros dropped from
    /// every digit run that follows a letter. `CourseCode.parse` keeps what
    /// Canvas wrote ("PHYS 0151" has been seen on real phones), while a
    /// syllabus or an announcement says "PHYS 151"; a key nothing else agrees
    /// with is an identity bug (CLAUDE.md, "Course identity").
    static func normalizedCourse(_ raw: String) -> String {
        let compact = String(raw.lowercased().filter { $0.isLetter || $0.isNumber })
        return compact.replacingOccurrences(
            of: #"(?<=[a-z])0+(?=\d)"#,
            with: "",
            options: .regularExpression
        )
    }

    // MARK: - Mentions

    /// One exam named in a piece of text, with where it sits so a caller
    /// reading a whole line (the syllabus extractor) can pair it with a date.
    struct Mention: Hashable, Sendable {
        let kind: Kind
        let ordinal: Int?
        let modifiers: Set<String>
        /// "Midterms", "Final Exams": a category, not one sitting. The
        /// syllabus extractor ignores an unnumbered plural, because "Midterms
        /// are closed book (Oct 23)" says nothing about *when* a midterm is.
        let isPlural: Bool
        /// The words that name it, as written ("Midterm Exam 1", "MIDTERM
        /// #1", "Second Midterm").
        let phrase: String
        let range: Range<String.Index>
    }

    /// Every exam `text` names, in order.
    ///
    /// `contextWindow` is how far the context-word rule looks. A title is one
    /// thing, so `nil` means the whole title: "Quiz on midterm material" is
    /// not an exam. A syllabus line is several things, so a caller passes a
    /// small window of words: in "Midterm 1: Oct 23 (review session Oct 21)"
    /// the review session is not the midterm's problem, but "Review session
    /// for Midterm 1" is.
    static func mentions(in text: String, contextWindow: Int?) -> [Mention] {
        let tokens = tokenize(text)
        var result: [Mention] = []
        var index = 0
        while index < tokens.count {
            guard let noun = nounInfo(tokens[index]) else { index += 1; continue }

            var start = index
            var end = index
            var ordinal = noun.ordinal
            var plural = noun.plural

            // "First midterm", "2nd exam": an ordinal word in front.
            if ordinal == nil, noun.kind != .final, index > 0,
               let lead = leadingOrdinals[tokens[index - 1].text] {
                ordinal = lead
                start = index - 1
            }

            // "Final Exam", "Midterm Exam", "Prelim Exam": the second noun is
            // part of one name, not a second mention.
            var next = index + 1
            if next < tokens.count, absorbs(noun.kind, tokens[next].text) {
                end = next
                plural = plural || (nounInfo(tokens[next])?.plural ?? false)
                next += 1
            }

            // "Exam No. 2", "Midterm number 1": skip the marker word.
            var ordinalIndex = next
            if ordinalIndex < tokens.count, ["no", "number"].contains(tokens[ordinalIndex].text) {
                ordinalIndex += 1
            }
            if ordinalIndex < tokens.count,
               let trailing = trailingOrdinal(at: ordinalIndex, in: tokens, text: text) {
                ordinal = trailing
                end = ordinalIndex
                next = ordinalIndex + 1
            }

            let blocked = isBlocked(
                kind: noun.kind,
                before: start > 0 ? tokens[start - 1].text : nil,
                after: next < tokens.count ? tokens[next].text : nil
            ) || hasBlockingContext(tokens, phrase: start...end, window: contextWindow)

            if !blocked {
                let phraseRange = tokens[start].range.lowerBound..<tokens[end].range.upperBound
                result.append(Mention(
                    kind: noun.kind,
                    ordinal: ordinal,
                    modifiers: modifiers(in: tokens, phrase: start...end, window: contextWindow),
                    isPlural: plural,
                    phrase: String(text[phraseRange]),
                    range: phraseRange
                ))
            }
            index = end + 1
        }
        return result
    }

    // MARK: - Vocabulary

    /// Words that, anywhere near an exam noun, mean the title is *about* an
    /// exam rather than being one. Each family is the false friend it was
    /// added for: practice material, study material, results, and the exam's
    /// paperwork.
    private static let contextBlockers: Set<String> = [
        "quiz", "quizzes",
        "practice", "mock", "sample", "samples", "old", "past", "previous", "prior", "archive", "archived",
        "review", "reviews", "reviewing", "study", "studying", "prep", "preparation",
        "solution", "solutions", "answer", "answers", "key", "bank", "sheet",
        "grade", "grades", "grading", "graded", "score", "scores", "result", "results",
        "regrade", "regrades", "feedback", "correction", "corrections",
        "wrapper", "reflection", "survey", "evaluation", "evaluations",
    ]

    /// Words that, *immediately after* the exam noun (and its number), turn it
    /// into a deliverable or an information page. "Final Project" and "Final
    /// Paper" are the cases that matter most: "final" alone is an exam, but it
    /// is also the most common adjective in a syllabus.
    private static let followingBlockers: Set<String> = [
        // deliverables
        "project", "projects", "paper", "papers", "presentation", "presentations",
        "report", "reports", "draft", "drafts", "essay", "essays", "proposal", "proposals",
        "submission", "submissions", "portfolio", "assignment", "assignments",
        "homework", "hw", "lab", "labs", "poster", "video", "demo", "deliverable", "deliverables",
        "thesis", "design", "prototype", "code", "version", "pitch", "critique",
        "revision", "revisions",
        // information about an exam rather than the exam
        "week", "weeks", "period", "schedule", "policy", "policies", "info", "information",
        "logistics", "format", "topics", "coverage", "conflict", "conflicts",
        "accommodation", "accommodations", "date", "dates",
        // "final" as an ordinary adjective
        "thoughts", "questions", "notes", "reminder", "announcement", "announcements",
        "check", "update", "updates", "discussion", "comments", "deadline", "deadlines",
        "warning", "notice",
    ]

    /// Words right before the noun that negate it or move it out of the
    /// sitting: "no exams" (the holiday row that once surfaced as an
    /// assessment, see `AppState.isAssessment`), "post-exam", "pre-exam",
    /// "semi-final".
    private static let precedingBlockers: Set<String> = [
        "no", "without", "non", "pre", "post", "semi", "quarter",
    ]

    /// The programming and statistics senses of "test", which is the one exam
    /// noun with an everyday second life. Checked only for `Kind.test`.
    private static let testPrecedingBlockers: Set<String> = [
        "unit", "integration", "regression", "hidden", "public", "beta", "stress", "smoke",
        "acceptance", "system", "hypothesis", "t", "z", "f", "chi", "square", "turing",
        "paired", "ab",
    ]
    private static let testFollowingBlockers: Set<String> = [
        "case", "cases", "suite", "suites", "data", "set", "sets", "driven", "file", "files",
        "plan", "harness", "runner", "script", "scripts", "fixture", "fixtures",
        "yourself", "your", "drive",
    ]

    private static let leadingOrdinals: [String: Int] = [
        "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3,
        "fourth": 4, "4th": 4, "fifth": 5, "5th": 5,
    ]

    private static let romanNumerals: [String: Int] = [
        "i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6,
    ]

    /// The words that follow an exam number and make it a quantity instead:
    /// "Final Exam 9 am", "Midterm 3 hours", "Exam 2 (25 points)".
    private static let quantityWords: Set<String> = [
        "am", "pm", "hour", "hours", "hr", "hrs", "min", "minutes", "percent", "point", "points", "pt", "pts",
    ]

    private static let modifierWords: [String: String] = [
        "makeup": "makeup", "retake": "retake", "alternate": "alternate", "alternative": "alternate",
    ]

    private struct NounInfo {
        let kind: Kind
        let ordinal: Int?
        let plural: Bool
    }

    private static func nounInfo(_ token: Token) -> NounInfo? {
        switch token.text {
        case "midterm": return NounInfo(kind: .midterm, ordinal: nil, plural: false)
        case "midterms": return NounInfo(kind: .midterm, ordinal: nil, plural: true)
        case "exam", "examination": return NounInfo(kind: .exam, ordinal: nil, plural: false)
        case "exams", "examinations": return NounInfo(kind: .exam, ordinal: nil, plural: true)
        case "final": return NounInfo(kind: .final, ordinal: nil, plural: false)
        case "finals": return NounInfo(kind: .final, ordinal: nil, plural: true)
        case "prelim": return NounInfo(kind: .prelim, ordinal: nil, plural: false)
        case "prelims": return NounInfo(kind: .prelim, ordinal: nil, plural: true)
        case "test": return NounInfo(kind: .test, ordinal: nil, plural: false)
        case "tests": return NounInfo(kind: .test, ordinal: nil, plural: true)
        default:
            // "MT2" / "MT-2": a midterm with its number attached.
            let digits = token.text.dropFirst(2)
            if token.text.hasPrefix("mt"), (1...2).contains(digits.count), let n = Int(digits), n >= 1 {
                return NounInfo(kind: .midterm, ordinal: n, plural: false)
            }
            return nil
        }
    }

    private static func absorbs(_ kind: Kind, _ word: String) -> Bool {
        switch kind {
        case .final, .midterm: return ["exam", "exams", "examination", "examinations", "test"].contains(word)
        case .prelim: return ["exam", "exams", "examination", "examinations"].contains(word)
        case .exam, .test: return false
        }
    }

    private static func isBlocked(kind: Kind, before: String?, after: String?) -> Bool {
        if let before, precedingBlockers.contains(before) { return true }
        if let after, followingBlockers.contains(after) { return true }
        if kind == .test {
            if let before, testPrecedingBlockers.contains(before) { return true }
            if let after, testFollowingBlockers.contains(after) { return true }
        }
        return false
    }

    /// The slice of tokens the context rules look at: the whole text, or
    /// `window` words either side of the phrase.
    private static func contextRange(_ tokens: [Token], phrase: ClosedRange<Int>, window: Int?) -> ClosedRange<Int> {
        guard let window else { return 0...(tokens.count - 1) }
        return max(0, phrase.lowerBound - window)...min(tokens.count - 1, phrase.upperBound + window)
    }

    private static func hasBlockingContext(_ tokens: [Token], phrase: ClosedRange<Int>, window: Int?) -> Bool {
        for i in contextRange(tokens, phrase: phrase, window: window) where !phrase.contains(i) {
            let word = tokens[i].text
            guard contextBlockers.contains(word) else { continue }
            // Inside a window, "quiz" only counts when it is touching the
            // exam: "Quiz 3 and Midterm 1: Oct 23" is a midterm, "Midterm
            // quiz" is not. In a whole title there is nothing else for it to
            // be about, so it always counts.
            if window != nil, word.hasPrefix("quiz") {
                let distance = i < phrase.lowerBound ? phrase.lowerBound - i : i - phrase.upperBound
                if distance > 1 { continue }
            }
            return true
        }
        return false
    }

    private static func modifiers(in tokens: [Token], phrase: ClosedRange<Int>, window: Int?) -> Set<String> {
        var found: Set<String> = []
        for i in contextRange(tokens, phrase: phrase, window: window) where !phrase.contains(i) {
            if let modifier = modifierWords[tokens[i].text] { found.insert(modifier) }
        }
        return found
    }

    /// The number after an exam word: "1", "02", "II", "#3". Not "10/23"
    /// (a date), "25%" (a weight), "9:00" (a time), "9 am" or "3 hours".
    private static func trailingOrdinal(at index: Int, in tokens: [Token], text: String) -> Int? {
        let token = tokens[index]
        if token.text.allSatisfy(\.isNumber) {
            guard token.text.count <= 2, let value = Int(token.text), value >= 1 else { return nil }
            let after = text[token.range.upperBound...]
            if let first = after.first {
                if first == "/" || first == "%" { return nil }
                let second = after.dropFirst().first
                if (first == ":" || first == ".") && (second?.isNumber ?? false) { return nil }
            }
            if index + 1 < tokens.count, quantityWords.contains(tokens[index + 1].text) { return nil }
            return value
        }
        if let value = romanNumerals[token.text] {
            // A lone "I" or "V" is also a pronoun and a letter; accept those
            // only in capitals ("Exam II" and "exam ii" are both fine).
            if token.text.count == 1, token.original != token.original.uppercased() { return nil }
            return value
        }
        return nil
    }

    // MARK: - Tokens

    private struct Token {
        var text: String
        var original: String
        var range: Range<String.Index>
    }

    /// Words are runs of letters and digits, so every dash, slash, colon,
    /// bracket and hash is a separator without a list of them to maintain
    /// (the en and em dashes in "Final Exam — December 15" need no special
    /// case).
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i].isLetter || text[i].isNumber else { i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, text[j].isLetter || text[j].isNumber { j = text.index(after: j) }
            let original = String(text[i..<j])
            tokens.append(Token(text: original.lowercased(), original: original, range: i..<j))
            i = j
        }
        return merged(tokens, in: text)
    }

    /// Joins the spellings that are one word split by a space or hyphen:
    /// "mid term" / "Mid-term" (the same noun the announcement classifier
    /// already tolerates), "make-up", "re-take", and "MT-2".
    private static func merged(_ tokens: [Token], in text: String) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count, let joined = join(tokens[i], tokens[i + 1], in: text) {
                result.append(joined)
                i += 2
            } else {
                result.append(tokens[i])
                i += 1
            }
        }
        return result
    }

    private static func join(_ a: Token, _ b: Token, in text: String) -> Token? {
        let gap = text[a.range.upperBound..<b.range.lowerBound]
        guard gap.count <= 2 else { return nil }
        let isHyphenOrSpace = gap.allSatisfy { $0.isWhitespace || $0 == "-" || $0 == "\u{2010}" || $0 == "\u{2011}" }
        let isHyphen = gap.allSatisfy { $0 == "-" || $0 == "\u{2010}" || $0 == "\u{2011}" }
        let pair = (a.text, b.text)
        let joinable: Bool
        switch pair {
        case ("mid", "term"), ("mid", "terms"), ("make", "up"), ("re", "take"):
            joinable = isHyphenOrSpace
        case ("mt", _):
            joinable = isHyphen && b.text.count <= 2 && b.text.allSatisfy(\.isNumber)
        default:
            joinable = false
        }
        guard joinable else { return nil }
        return Token(
            text: a.text + b.text,
            original: a.original + b.original,
            range: a.range.lowerBound..<b.range.upperBound
        )
    }
}
