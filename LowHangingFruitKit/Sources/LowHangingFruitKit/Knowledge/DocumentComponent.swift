import Foundation

/// A Canvas course site can bundle more than one component under one code —
/// PHYS 0151 is a 1.0 CU lecture plus a 0.5 CU pass/fail lab, with a lab
/// syllabus and a lecture syllabus both synced as separate `CourseDocument`s.
/// Retrieval used to be blind to this: a question about "the class" could
/// retrieve the lab syllabus purely because it scored higher on keyword
/// overlap, and the model would answer about the lab. `DocumentComponent`
/// gives `CourseSearch` something to key a preference on, and gives the
/// rendered excerpts a label so the model (and, transitively, the student)
/// can see which component a passage came from even when it isn't the one
/// preferred.
///
/// Classification is a cheap, deterministic heuristic over title and the
/// first slice of body text — not a model call, not per-passage — because a
/// wrong guess here should be rare and cheap to make, not something a
/// student notices as latency. It is deliberately conservative: the bias
/// throughout is toward `.general` (visible everywhere, boosted nowhere)
/// rather than a confident wrong guess of `.lab`, since mislabeling a
/// lecture document as `.lab` would recreate exactly the bug this type
/// exists to fix.
public enum DocumentComponent: String, Sendable, Hashable, CaseIterable {
    case lecture
    case lab
    case recitation
    case general

    /// Short human-readable tag, e.g. for `"[lab] "` prefixes. `.general`
    /// renders as the empty string — most documents belong to no particular
    /// component and shouldn't be labelled as if they did.
    public var label: String {
        switch self {
        case .lecture: return "lecture"
        case .lab: return "lab"
        case .recitation: return "recitation"
        case .general: return ""
        }
    }

    /// Recitation words are unambiguous enough (no course calls its lecture
    /// "recitation") that they're checked before lab/lecture in `classify`,
    /// and never in tension with the "never lab" bias.
    // Every comparison below runs against `TextTokenizer.tokens`, which
    // stems: "recitation" comes out as "recitate", "class" as "clas",
    // "exams" as "exam". A word list written in plain English would then
    // silently never match those forms — the first version of this file did
    // exactly that and would have classified every recitation page as
    // `.general` and every "how is the class graded" question as having no
    // component. So the lists are stemmed once here, with the same function,
    // and stay in lockstep with whatever the stemmer does next.
    private static func stemmed(_ words: [String]) -> Set<String> {
        Set(words.map(TextTokenizer.stem))
    }

    private static let recitationWords = stemmed(["recitation", "recitations", "rec", "discussion"])
    private static let labWords = stemmed(["lab", "labs", "laboratory", "laboratories"])
    private static let lectureTitleWords = stemmed(["lecture", "lectures", "syllabus"])
    private static let lectureHeadWords = stemmed(["lecture", "lectures", "exam", "exams", "midterm", "midterms", "problem", "homework", "homeworks"])
    private static let classWords = stemmed(["lecture", "lectures", "class", "classes"])
    private static let recitationQuestionWords = stemmed(["recitation", "recitations", "rec"])
    private static let headTextLength = 400

    /// Deterministic, word-boundary classification of one document. Reuses
    /// `TextTokenizer.tokens` (rather than a regex) both for consistency
    /// with the rest of the retrieval stack and because a raw-string regex
    /// with real Unicode escapes is a known trap in this codebase — this
    /// avoids the class of bug entirely by not writing a regex at all.
    public static func classify(title: String, text: String) -> DocumentComponent {
        let titleTokens = Set(TextTokenizer.tokens(title, minLength: 1))
        let headTokens = TextTokenizer.tokens(String(text.prefix(headTextLength)), minLength: 1)
        let headTokenSet = Set(headTokens)

        if !titleTokens.isDisjoint(with: recitationWords) || !headTokenSet.isDisjoint(with: recitationWords) {
            return .recitation
        }

        if !titleTokens.isDisjoint(with: labWords) {
            return .lab
        }

        let headLabCount = headTokens.filter { labWords.contains($0) }.count
        let headLectureCount = headTokens.filter { lectureHeadWords.contains($0) }.count
        if headLabCount >= 2 && headLectureCount == 0 {
            return .lab
        }

        let titleHasLecture = !titleTokens.isDisjoint(with: lectureTitleWords)
        if titleHasLecture && headLectureCount > headLabCount {
            return .lecture
        }

        return .general
    }

    /// Which component (if any) a free-text question is asking about. `nil`
    /// means the question doesn't name a component, so retrieval shouldn't
    /// prefer one. Checked in priority order lab, recitation, lecture: a
    /// question naming more than one ("class lab report") means the student
    /// typed "class" generically but "lab" specifically, so lab wins.
    public static func mentioned(in question: String) -> DocumentComponent? {
        let tokens = Set(TextTokenizer.tokens(question, minLength: 1))
        if !tokens.isDisjoint(with: labWords) {
            return .lab
        }
        if !tokens.isDisjoint(with: recitationQuestionWords) {
            return .recitation
        }
        if !tokens.isDisjoint(with: classWords) {
            return .lecture
        }
        return nil
    }
}
