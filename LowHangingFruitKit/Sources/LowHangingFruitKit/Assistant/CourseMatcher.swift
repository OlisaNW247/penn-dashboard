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

    /// `normalize`'s "dept number" with the number's leading zeros removed,
    /// used only to *compare* a typed mention with a course code, never to
    /// display or store one. Penn writes three-digit course numbers with a
    /// leading zero ("PHYS 0151") and students do not ("phys 151",
    /// "phys151"), so comparing `normalize` output directly made the most
    /// natural way to name a Penn course match nothing. `normalize` itself
    /// is left alone on purpose: it is the course identity key for the
    /// ledger, reminders, grades and dedup (see CLAUDE.md, "Course
    /// identity"), and changing what it returns would re-key all of them.
    static func comparisonKey(_ normalized: String) -> String {
        guard let space = normalized.firstIndex(of: " ") else { return normalized }
        let dept = normalized[..<space]
        let number = normalized[normalized.index(after: space)...]
        let stripped = number.drop(while: { $0 == "0" })
        guard dept.allSatisfy(\.isLetter), stripped.count < number.count, let first = stripped.first, first.isNumber else {
            return normalized
        }
        return "\(dept) \(stripped)"
    }

    /// The one course a group of candidates amounts to, if they are all the
    /// same course. A department-only mention ("my phys class") used to
    /// require exactly one candidate, but PHYS 0151's lecture and lab are
    /// two Canvas sites that share one code, so a student with both had two
    /// candidates and the mention matched nothing at all. Candidates that
    /// share a code are one course as far as every consumer is concerned
    /// (retrieval scopes by `courseIDs(forCode:)`, which finds every site),
    /// so the first stands for the group. Candidates with different codes
    /// are still ambiguous and still give up: a `Match` names one course,
    /// and widening it to "every course in the department" would change
    /// `ParsedQuestion.course` for every consumer.
    private static func singleCourse(in candidates: [CourseSummary]) -> CourseSummary? {
        guard let first = candidates.first else { return nil }
        let key = comparisonKey(normalize(first.code))
        return candidates.allSatisfy { comparisonKey(normalize($0.code)) == key } ? first : nil
    }

    public static func match(in question: String, courses: [CourseSummary]) -> Match? {
        guard !courses.isEmpty else { return nil }
        let q = question.lowercased()

        // 1. Explicit code anywhere in the question: "cis 2400", "cis2400".
        if let regex = try? NSRegularExpression(pattern: #"\b([a-z]{2,5})\s?-?(\d{3,4}[a-z]?)\b"#) {
            for m in regex.matches(in: q, range: NSRange(q.startIndex..., in: q)) {
                guard let dept = Range(m.range(at: 1), in: q), let num = Range(m.range(at: 2), in: q),
                      let whole = Range(m.range, in: q) else { continue }
                let key = comparisonKey("\(q[dept]) \(q[num])")
                if let course = courses.first(where: { comparisonKey(normalize($0.code)) == key || comparisonKey(normalize($0.name)) == key }) {
                    return Match(course: course, mention: String(q[whole]))
                }
                // Same department, number prefix ("cis 24" for "cis 2400")
                if let course = courses.first(where: { comparisonKey(normalize($0.code)).hasPrefix(key) }) {
                    return Match(course: course, mention: String(q[whole]))
                }
            }
        }

        // 2. Department alone ("my cis class"), only when it's unambiguous.
        let rawWords: [String] = q.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let words: [String] = TextTokenizer.tokens(q) + rawWords
        let departments = Dictionary(grouping: courses) { normalize($0.code).split(separator: " ").first.map(String.init) ?? "" }
        for word in Set(words) {
            if let group = departments[word], word.count >= 3, let course = singleCourse(in: group) {
                return Match(course: course, mention: word)
            }
            if let targets = aliases[word] {
                let candidates = courses.filter { course in
                    let haystack = (normalize(course.code) + " " + course.name.lowercased())
                    return targets.contains(where: { haystack.contains($0) })
                }
                if let course = singleCourse(in: candidates) { return Match(course: course, mention: word) }
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
