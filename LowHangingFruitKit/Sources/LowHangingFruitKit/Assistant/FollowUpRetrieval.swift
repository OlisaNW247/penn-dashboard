import Foundation

/// What to search the course materials for, and in which course, when a
/// question may be a follow-up to the one before it.
///
/// Every question used to be retrieved on its own. After "what's the late
/// policy in CIS 2400?", the follow-up "and for the final?" searched every
/// course for the single word "final" and had no idea CIS 2400 was the
/// subject, so it came back with whichever syllabus used that word most.
/// Students ask this way all the time ("what about the midterm?", "and
/// labs?"), and the thing that goes missing is exactly the half of the
/// question that was said in the previous turn.
///
/// This type changes only *which passages are chosen*. The question the
/// student typed is still what is shown, still what is sent to the server as
/// `question`, and still what the model answers; the earlier question is
/// never sent anywhere (see `BackendAssistantResponder.makeRequest`, whose
/// `history` stays empty on purpose: shipping earlier turns to the server is
/// a privacy-policy change, not a retrieval tweak). It is also kept out of
/// `AssistantContextDocument`, whose bytes are a prompt-cache prefix.
///
/// Two rules, applied independently:
///
/// - **Scope.** A question that names no course of its own inherits the
///   course named by the most recent earlier question that named one,
///   looking back at most `maxEarlierQuestions` questions, newest first. It
///   looks past questions that named nothing because a chain of fragments
///   ("late policy in CIS 2400?", "and for the final?", "what about the
///   midterm?") keeps one subject while only its first link says which: the
///   third question's immediate predecessor names no course, and stopping
///   there would drop the scope at the second follow-up. The nearest naming
///   question wins, so a different course named more recently overrides an
///   older one. A question that names a course, even a different one, takes
///   that and nothing else: "what about ECON 1?" must never be pulled back
///   to the course before it.
/// - **Query.** A short question (`shortQuestionWordLimit` words or fewer)
///   reads as a fragment of the one before it, so the search text is that
///   immediately previous question followed by the new one. Only that one:
///   the scope reaches back through the chain, the words do not, because
///   each added question dilutes the search with words from a subject the
///   student may have moved on from. A longer question stands on its own
///   words, and gluing the earlier question to it would only dilute them. A
///   question that names its own course is a fresh subject by the same
///   reasoning as above and is searched as typed.
///
/// The scope is a guess, like every scope (`CourseSearch.search` retries a
/// scope that finds nothing, unscoped), so a wrongly inherited course costs
/// one weak search rather than an answer of "not in your materials".
public struct FollowUpRetrieval: Sendable, Hashable {
    /// The text to hand the search: the question as typed, or the earlier
    /// question followed by it.
    public let query: String
    /// The course to limit the search to, or `nil` to search every course.
    /// Either the course the question itself names or, failing that, the one
    /// the earlier question named.
    public let course: CourseSummary?

    /// A question this many words long or shorter is treated as a fragment
    /// that needs the earlier question to mean anything. "and for the
    /// final?" is four; "what is the late policy for the final" is eight.
    public static let shortQuestionWordLimit = 6

    /// How many earlier questions (the previous one included) are searched
    /// for a course to inherit. Far enough back to span a few follow-ups,
    /// near enough that a course named a dozen questions ago, in what is
    /// probably a different conversation in all but name, stays forgotten.
    /// Enforced here as well as where the list is built, so a caller handing
    /// in a longer one cannot stretch it.
    public static let maxEarlierQuestions = 4

    /// - Parameters:
    ///   - question: the new question, as typed.
    ///   - previousQuestion: the most recent earlier question the student
    ///     asked in this conversation (their words, not an answer), or `nil`
    ///     for the first question. It is the one a short follow-up is
    ///     concatenated with.
    ///   - olderQuestions: the questions before `previousQuestion`, newest
    ///     first. They are consulted only for a course to inherit.
    ///   - courses: the courses a mention can resolve to, the same list the
    ///     caller hands `QuestionParser`.
    ///
    /// Blank entries are ignored.
    public static func resolve(
        question: String,
        previousQuestion: String?,
        olderQuestions: [String] = [],
        courses: [CourseSummary]
    ) -> FollowUpRetrieval {
        let ownCourse = CourseMatcher.match(in: question, courses: courses)?.course
        let earlier = (([previousQuestion].compactMap { $0 }) + olderQuestions)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxEarlierQuestions)
        guard let previous = earlier.first else {
            return FollowUpRetrieval(query: question, course: ownCourse)
        }
        // A question that names its own course is a new subject: it inherits
        // neither the scope nor the earlier words.
        if let ownCourse {
            return FollowUpRetrieval(query: question, course: ownCourse)
        }
        let inherited = earlier.lazy.compactMap { CourseMatcher.match(in: $0, courses: courses)?.course }.first
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        let query = wordCount <= shortQuestionWordLimit ? "\(previous) \(trimmed)" : question
        return FollowUpRetrieval(query: query, course: inherited)
    }
}
