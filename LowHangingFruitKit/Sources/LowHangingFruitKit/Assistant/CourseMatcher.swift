import Foundation

/// Finds which course a question is about. Handles "CIS 2400", "cis2400",
/// "cis-2400", department-only mentions when unambiguous ("my cis class"),
/// and everyday names ("my stats class", "econ").
public enum CourseMatcher {
    public struct Match: Sendable, Hashable {
        public let course: CourseSummary
        /// Range of the mention in the original question, so it can be
        /// stripped before matching an item title.
        public let mention: String
    }

    static let aliases: [String: [String]] = [
        "stats": ["stat"], "statistics": ["stat"],
        "econ": ["econ"], "economics": ["econ"],
        "psych": ["psyc"], "psychology": ["psyc"],
        "bio": ["biol"], "biology": ["biol"],
        "chem": ["chem"], "chemistry": ["chem"],
        "calc": ["math", "calculus"], "calculus": ["math", "calculus"],
        "cs": ["cis", "computer"], "compsci": ["cis", "computer"],
        "physics": ["phys"], "writing": ["writ"], "seminar": ["writ", "sem"],
        "spanish": ["span"], "french": ["fren"], "history": ["hist"],
        "philosophy": ["phil"], "polisci": ["psci"], "politics": ["psci"],
        "linear": ["math"], "management": ["mgmt"], "marketing": ["mktg"],
        "finance": ["fnce"], "accounting": ["acct"], "nursing": ["nurs"],
        "engineering": ["engr", "meam", "ese", "cbe", "be"], "art": ["fnar"],
    ]

    /// "CIS 2400-001" / "cis2400" / "CIS-2400" → "cis 2400"
    public static func normalize(_ code: String) -> String {
        let lower = code.lowercased()
        let pattern = #"^\s*([a-z]{2,5})\s?-?(\d{3,4}[a-z]?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let dept = Range(match.range(at: 1), in: lower),
           let num = Range(match.range(at: 2), in: lower) {
            return "\(lower[dept]) \(lower[num])"
        }
        return lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func match(in question: String, courses: [CourseSummary]) -> Match? {
        guard !courses.isEmpty else { return nil }
        let q = question.lowercased()

        // 1. Explicit code anywhere in the question: "cis 2400", "cis2400".
        if let regex = try? NSRegularExpression(pattern: #"\b([a-z]{2,5})\s?-?(\d{3,4}[a-z]?)\b"#) {
            for m in regex.matches(in: q, range: NSRange(q.startIndex..., in: q)) {
                guard let dept = Range(m.range(at: 1), in: q), let num = Range(m.range(at: 2), in: q),
                      let whole = Range(m.range, in: q) else { continue }
                let key = "\(q[dept]) \(q[num])"
                if let course = courses.first(where: { normalize($0.code) == key || normalize($0.name) == key }) {
                    return Match(course: course, mention: String(q[whole]))
                }
                // Same department, number prefix ("cis 24" for "cis 2400")
                if let course = courses.first(where: { normalize($0.code).hasPrefix(key) }) {
                    return Match(course: course, mention: String(q[whole]))
                }
            }
        }

        // 2. Department alone ("my cis class"), only when it's unambiguous.
        let rawWords: [String] = q.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let words: [String] = TextTokenizer.tokens(q) + rawWords
        let departments = Dictionary(grouping: courses) { normalize($0.code).split(separator: " ").first.map(String.init) ?? "" }
        for word in Set(words) {
            if let group = departments[word], group.count == 1, word.count >= 3 {
                return Match(course: group[0], mention: word)
            }
            if let targets = aliases[word] {
                let candidates = courses.filter { course in
                    let haystack = (normalize(course.code) + " " + course.name.lowercased())
                    return targets.contains(where: { haystack.contains($0) })
                }
                if candidates.count == 1 { return Match(course: candidates[0], mention: word) }
            }
        }

        // 3. A distinctive word from the course name ("software", "systems").
        for course in courses {
            let nameWords = TextTokenizer.tokens(course.name).filter { $0.count >= 5 && !$0.allSatisfy(\.isNumber) }
            for word in nameWords where words.contains(word) {
                let others = courses.filter { $0.courseID != course.courseID && TextTokenizer.tokens($0.name).contains(word) }
                if others.isEmpty { return Match(course: course, mention: word) }
            }
        }
        return nil
    }

    /// True when `course` (a display string from either source) refers to the
    /// same course as `summary`.
    public static func sameCourse(_ course: String, as summary: CourseSummary) -> Bool {
        let key = normalize(course)
        return key == normalize(summary.code) || key == normalize(summary.name)
    }
}
