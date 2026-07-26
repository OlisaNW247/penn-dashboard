import Foundation

/// Title normalization shared by everything that has to decide whether two
/// human-written names mean the same thing: the Gradescope score overlay
/// (docs/grades.md §5.1) and the syllabus → Canvas category matcher.
///
/// Lowercases, strips punctuation, collapses the "problem set" / "PSet" /
/// "homework" family to one canonical `hw` token, and compares numbers by
/// value so `HW3` == `Homework 03`.
///
/// This was `GradescopeOverlay.normalize`; it lives here so the two matchers
/// can't drift apart — a course whose Gradescope items match one way and whose
/// syllabus categories match another would be very hard to reason about.
public enum TitleNormalizer {
    /// Canonical token sequence for a title.
    public static func tokens(_ raw: String) -> [String] {
        var s = raw.lowercased()
        s = s.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        // Phrase-level collapse before word-splitting so "problem set" (two
        // words) lines up with single-word "pset"/"homework".
        s = s.replacingOccurrences(of: #"\bproblem\s+sets?\b"#, with: "hw", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard !s.isEmpty else { return [] }

        var result: [String] = []
        for word in s.split(separator: " ") {
            result.append(contentsOf: splitLetterDigitRuns(String(word)))
        }
        return result.map(canonicalize)
    }

    /// Stable string key for a title's token sequence — used to key persisted
    /// mappings without exposing the token array to callers.
    public static func key(_ raw: String) -> String {
        tokens(raw).joined(separator: " ")
    }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    /// Token-set similarity of two raw titles, 0…1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        jaccard(Set(tokens(a)), Set(tokens(b)))
    }

    /// Category names are written in the plural in syllabi ("Problem Sets",
    /// "Exams") and often in the singular in Canvas ("Problem Set", "Exam").
    /// Applied only on the category-matching path — assignment titles keep the
    /// stricter normalization above, where "Quiz 2" and "Quizzes" should NOT
    /// collapse into each other.
    public static func categoryTokens(_ raw: String) -> [String] {
        tokens(raw).map(singularize)
    }

    public static func categoryKey(_ raw: String) -> String {
        categoryTokens(raw).joined(separator: " ")
    }

    public static func categorySimilarity(_ a: String, _ b: String) -> Double {
        jaccard(Set(categoryTokens(a)), Set(categoryTokens(b)))
    }

    private static func singularize(_ token: String) -> String {
        // Irregulars first, then the two productive English plural endings we
        // actually see in course material. Short tokens are left alone so
        // "labs" → "lab" but "is"/"as" don't get mangled.
        switch token {
        case "quizzes":  return "quiz"
        case "essays":   return "essay"
        case "analyses": return "analysis"
        default: break
        }
        if token.count > 3, token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }
        if token.count > 3, token.hasSuffix("es"), token.hasSuffix("ses") || token.hasSuffix("xes") || token.hasSuffix("zes") {
            return String(token.dropLast(2))
        }
        if token.count > 3, token.hasSuffix("s"), !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    /// Splits a token like "hw3" into ["hw", "3"] at the letter/digit
    /// boundary, so "HW3" and "HW 3" normalize to the same token sequence.
    private static func splitLetterDigitRuns(_ word: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsDigit: Bool?
        for ch in word {
            let isDigit = ch.isNumber
            if currentIsDigit == nil || currentIsDigit == isDigit {
                current.append(ch)
            } else {
                result.append(current)
                current = String(ch)
            }
            currentIsDigit = isDigit
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func canonicalize(_ token: String) -> String {
        // Numeric tokens compare by value, so leading zeros don't matter.
        if let intValue = Int(token) { return String(intValue) }
        switch token {
        case "hw", "homework", "pset", "psets": return "hw"
        case "lab", "labs": return "lab"
        case "quiz", "quizzes": return "quiz"
        default: return token
        }
    }
}
