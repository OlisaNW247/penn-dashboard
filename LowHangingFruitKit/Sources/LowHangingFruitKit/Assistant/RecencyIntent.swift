import Foundation

/// Whether a question is asking for the *newest* posts rather than the ones
/// whose words best match it, and if so how far back it looks.
///
/// **Why this exists.** `ask` answers from passages the phone retrieves by
/// BM25 (`CourseSearch`), and BM25 knows nothing about time. On 2026-10-20 the
/// owner asked "What have been the recent staff posts on Ed for my cis 2620
/// class" and then "What about in the past week". The search matched the words
/// "staff" and "posts" and handed the model six posts from Aug 28 to Oct 7,
/// while the two newest Ed posts on the phone (Oct 12 and Oct 18) never
/// reached the excerpts, because their text did not contain those words. The
/// model, told by its prompt to answer only from the excerpts, said nothing
/// newer than Oct 7 existed. That is a wrong answer produced by a correct
/// reading of what it was shown.
///
/// The wrong fix is to tune the ranking: boosting recent documents inside
/// BM25 still needs a word match to get a post into the pool at all, and a
/// boost big enough to matter would drag recent-but-irrelevant posts into
/// every ordinary question ("when is the midterm"). So recency is decided
/// here, by the question's own words, and acted on only when it fires
/// (`BackendAssistantResponder.recencyPicks`); every other question keeps
/// exactly the retrieval it had.
///
/// Pure and clock-free: it reads the text of the question and nothing else.
/// "Today" and "this week" are resolved against the question's `askedAt` by
/// the caller.
///
/// **What fires.**
/// - On its own, with no window ("the newest, however old"): `recent`,
///   `recently`, `latest`, `newest`, `lately`, `what's new`, `any news`,
///   `any updates`, `new posts`, `most recent`.
/// - A time phrase (`today`, `yesterday`, `this week`, `past week`, `last 10
///   days`, ...) fires only when the question also names something that gets
///   posted (`post`, `announcement`, `update`, `staff`, `ed`, `board`, ...).
///   Without that, "what's due today" and "is there homework this week" are
///   questions about deadlines, which the work list answers and which must
///   not reorder the excerpts.
/// - When a question has both a recency word and a time phrase, the time
///   phrase's window wins ("recent staff posts ... what about in the past
///   week" is 7 days). When it has several time phrases, the one written last
///   wins, because `FollowUpRetrieval` puts the earlier question first and
///   the student's new words last.
public struct RecencyIntent: Sendable, Equatable {
    /// `nil`: "the newest", no window. Otherwise "within the last N days".
    public let windowDays: Int?

    public init(windowDays: Int?) {
        self.windowDays = windowDays
    }

    public static func detect(in question: String) -> RecencyIntent? {
        // A curly apostrophe from the keyboard would otherwise hide "what's new".
        let q = question.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        guard !q.isEmpty else { return nil }

        let hasRecencyWord = q.range(of: recencyPattern, options: .regularExpression) != nil
        let hasPostingNoun = q.range(of: postingNounPattern, options: .regularExpression) != nil

        if hasPostingNoun, let window = lastWindow(in: q) {
            return RecencyIntent(windowDays: window)
        }
        if hasRecencyWord { return RecencyIntent(windowDays: nil) }
        return nil
    }

    // MARK: - Patterns

    private static let recencyPattern =
        #"\b(?:recent|recently|latest|newest|lately|what'?s\s+new|any\s+news|any\s+updates|new\s+posts|most\s+recent)\b"#

    private static let postingNounPattern =
        #"\b(?:post|posts|posted|announcement|announcements|announce|announced|update|updates|news|said|staff|ed|discussion|message|messages|board)\b"#

    private struct WindowPhrase: Sendable {
        let pattern: String
        let days: Int
    }

    private static let windowPhrases: [WindowPhrase] = [
        WindowPhrase(pattern: #"\btoday\b"#, days: 1),
        WindowPhrase(pattern: #"\byesterday\b"#, days: 2),
        WindowPhrase(pattern: #"\b(?:this\s+week|past\s+week|last\s+week|the\s+week)\b"#, days: 7),
        WindowPhrase(pattern: #"\b(?:past|last)\s+(?:two|2)\s+weeks\b"#, days: 14),
        WindowPhrase(pattern: #"\b(?:this\s+month|past\s+month|last\s+month)\b"#, days: 30),
    ]

    /// "past 10 days", "last 30 days". The number is read back out of the
    /// match, so the fixed phrases above need no entry for each count.
    private static let daysPhrasePattern = #"\b(?:past|last)\s+(\d{1,3})\s+days?\b"#

    /// The window of the time phrase written last in `q`, or `nil` when it
    /// has none.
    private static func lastWindow(in q: String) -> Int? {
        var best: (position: Int, days: Int)?
        func consider(_ range: Range<String.Index>, days: Int) {
            let position = q.distance(from: q.startIndex, to: range.lowerBound)
            if best == nil || position >= best!.position { best = (position, days) }
        }
        for phrase in windowPhrases {
            if let range = q.range(of: phrase.pattern, options: .regularExpression) {
                consider(range, days: phrase.days)
            }
        }
        if let range = q.range(of: daysPhrasePattern, options: .regularExpression) {
            let digits = q[range].filter { $0.isASCII && $0.isNumber }
            if let days = Int(digits), days >= 1 {
                consider(range, days: days)
            }
        }
        return best?.days
    }
}
