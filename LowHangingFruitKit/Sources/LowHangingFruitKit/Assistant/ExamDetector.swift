import Foundation

/// Shared "is this calendar/assignment title actually naming an exam"
/// judgment call. `WorkKindFilter.exam` (the "next exam" / "any exams this
/// week" question path in `QuestionIntent.swift`) is the one caller today;
/// anything else that needs the same call should use this rather than
/// growing its own regex, the way `WorkKindFilter.exam` briefly did.
///
/// Why negation and governance matter here, not just keyword-spotting: a
/// real phone transcript (2026-09-13) had ask answer "when's my next
/// exam?" with "Your next exam is Yom Kippur (no exams/assignments) for
/// (unknown course): Sun, Sep 20 ... After that: Yom Kippur (no
/// exams/assignments) ((unknown course)), Mon Sep 21". The university
/// calendar feed Canvas re-exports ships a holiday event whose title says
/// there are *no* exams that day, and the old check — "does the title
/// contain the word exam" — matched it anyway. A bare keyword match also
/// can't tell "Midterm 1" (an exam) from "Midterm review session" (a study
/// session *about* an exam, from `AssistantFixture`'s own ECON 1
/// announcement fixture) or "Final project" (a deliverable) from "Final
/// Exam".
public enum ExamDetector {
    /// Exam-family words, matched as whole tokens (case-insensitive) so
    /// "exam" never fires inside "example" or "examine". Plurals included
    /// because a title says "no exams" as often as "no exam". `prelim(s)`
    /// carries over from the regex this replaces
    /// (the old `WorkKindFilter.exam` pattern).
    private static let examWords: Set<String> = [
        "exam", "exams", "midterm", "midterms", "final", "finals",
        "quiz", "quizzes", "test", "tests", "prelim", "prelims",
    ]

    /// Nearby words that mean the title is about NOT having an exam:
    /// "no exams", "exam cancelled", "without a final", etc.
    private static let negationWords: Set<String> = [
        "no", "not", "without", "cancel", "cancelled", "canceled",
    ]

    /// Nearby words that turn the exam word into something *about* an exam
    /// rather than the exam itself: "midterm review session", "review
    /// session for midterm", "study for the final", "exam prep".
    /// Deliberately this short, specific list rather than a broader
    /// heuristic — these are the cases the brief that produced this file
    /// called out by name, and a longer guessed list risks swallowing
    /// titles like "Final Exam Room Change" that are still about the exam.
    private static let governingWords: Set<String> = ["review", "study", "prep", "session"]

    /// How many tokens away still counts as "nearby" for each check.
    /// Unordered on purpose: the phone transcript's negation ("no exams")
    /// sits BEFORE the word, but "Exam 2 cancelled" puts it AFTER, and both
    /// must read as not-an-exam; likewise "Midterm review session" has the
    /// governing words after, while "Review session for midterm" (the
    /// other shape named in the brief) has them before.
    private static let negationWindow = 4
    private static let governingWindow = 3

    /// True when `title` is naming an exam/midterm/final/quiz/test itself,
    /// as opposed to mentioning the word in passing, negating it, or using
    /// it as a plain adjective for something else ("final project",
    /// "final draft", "the Final Frontier").
    public static func isExam(title: String) -> Bool {
        let tokens = tokenize(title)
        guard !tokens.isEmpty else { return false }

        for (index, token) in tokens.enumerated() where examWords.contains(token) {
            // "final"/"finals" is the one exam word that also works as a
            // plain adjective in front of some other noun. It only counts
            // as naming the exam itself when it's the title's last word,
            // is followed by a number ("Final 2"), or is followed by
            // another exam word ("Final Exam"); anything else after it
            // ("project", "draft", "frontier"...) means "final" is
            // modifying that word, not standing in for the exam. Numbers
            // like "midterm 1"/"quiz 3" are unaffected — this narrowing
            // only applies to "final"/"finals".
            if token == "final" || token == "finals" {
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                if let next, !examWords.contains(next), !next.allSatisfy(\.isNumber) {
                    continue
                }
            }

            let radius = max(negationWindow, governingWindow)
            let lowerBound = max(0, index - radius)
            let upperBound = min(tokens.count - 1, index + radius)
            var negated = false
            var governed = false
            if lowerBound <= upperBound {
                for other in lowerBound...upperBound where other != index {
                    let distance = abs(other - index)
                    let word = tokens[other]
                    if distance <= negationWindow, negationWords.contains(word) { negated = true }
                    if distance <= governingWindow, governingWords.contains(word) { governed = true }
                }
            }
            if !negated, !governed { return true }
        }
        return false
    }

    /// Lowercased alphanumeric tokens. Punctuation never separates two
    /// words that should still read as "nearby" — "(no exams/assignments)"
    /// must keep "no" and "exams" adjacent, not split into unrelated
    /// clauses by the parenthesis and slash. Deliberately its own simple
    /// splitter rather than `TextTokenizer`: that tokenizer stems words for
    /// search relevance ("cancelled" → "cancell", not "cancel"), which
    /// would silently break the exact-word negation list above.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
