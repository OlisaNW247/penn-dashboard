import Foundation

/// Reads a grading scheme out of syllabus text. Pure — string in, scheme out,
/// no I/O, no network, no model calls.
///
/// **Why a deterministic parser.** The app has no backend and a privacy
/// manifest that says nothing leaves the device; sending a student's syllabus
/// somewhere to be read would change both. Regex is enough here because of one
/// property of the problem: a grading scheme's weights sum to 100. That single
/// check is what makes a cheap parser trustworthy — a wrong parse essentially
/// never adds up, so `parse` refuses it rather than guessing. Anything the
/// gate rejects falls back to manual weight entry, which already exists.
///
/// Nothing this returns is ever applied on its own. The scheme is a
/// *proposal*: the user sees each weight next to the line it was read from and
/// confirms before it touches a grade (docs/grades.md §13).
public enum SyllabusParser {
    /// Weights must land in this band to be believed at all.
    static let acceptedSumRange: ClosedRange<Double> = 90...110
    /// Within this much of 100, the parse is treated as high-confidence.
    static let exactSumTolerance = 0.5

    public static func parse(_ rawText: String) -> SyllabusGradingScheme? {
        let text = normalizedText(rawText)
        guard !text.isEmpty else { return nil }

        let categories = weightCandidates(in: text)
        guard categories.count >= 2 else { return nil }

        let sum = categories.reduce(0) { $0 + $1.weightPercent }
        guard acceptedSumRange.contains(sum) else { return nil }

        let sentences = self.sentences(in: text)
        let enriched = categories.map { category in
            SyllabusCategory(
                id: category.id,
                name: category.name,
                weightPercent: category.weightPercent,
                dropLowest: dropCount(for: category, in: sentences),
                expectedItemCount: expectedCount(for: category, in: sentences),
                evidence: category.evidence
            )
        }

        return SyllabusGradingScheme(
            categories: enriched,
            cutoffs: cutoffs(in: text),
            mentionsCurve: mentionsCurve(text),
            confidence: abs(sum - 100) <= exactSumTolerance ? .high : .medium,
            rawWeightSum: sum
        )
    }

    // MARK: - Text shaping

    /// Collapses runs of spaces but preserves line structure: a flattened HTML
    /// table row ("Problem Sets\t30%") and a bulleted list line are both one
    /// line, which is the unit the weight regexes work on.
    static func normalizedText(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{2013}", with: "-")   // en dash
            .replacingOccurrences(of: "\u{2014}", with: "-")   // em dash
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lines(in text: String) -> [String] {
        text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func sentences(in text: String) -> [String] {
        text
            .split(whereSeparator: { ".;!?\n".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Weight table

    /// `Problem Sets ....... 30%` and `30% - Problem Sets` both appear in the
    /// wild, so both orders are tried on every line. A line can only produce
    /// one category (the first match wins), which keeps a prose sentence
    /// carrying two percentages from inventing two categories.
    /// Note the literal bullet characters in the leading class: `\u{...}` is
    /// NOT interpreted inside a Swift raw string, and ICU rejects the escape
    /// that would reach it, which silently nils the whole regex.
    private static let nameThenPercent = try? NSRegularExpression(
        pattern: #"^[\s\-•*▪·]*([A-Za-z][A-Za-z0-9 &/'()\-]{1,48}?)\s*[:\-.\t ]*\(?(\d{1,3}(?:\.\d+)?)\s*%"#
    )
    private static let percentThenName = try? NSRegularExpression(
        pattern: #"^[\s\-•*▪·]*(\d{1,3}(?:\.\d+)?)\s*%\s*[:\-]?\s*(?:of\s+(?:the\s+)?(?:final\s+|course\s+)?grade\s*[:\-]?\s*)?([A-Za-z][A-Za-z0-9 &/'()\-]{1,48})"#
    )

    private static func weightCandidates(in text: String) -> [SyllabusCategory] {
        var seen: Set<String> = []
        var result: [SyllabusCategory] = []

        for line in lines(in: text) {
            guard let candidate = candidate(from: line) else { continue }
            guard seen.insert(candidate.id).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private static func candidate(from line: String) -> SyllabusCategory? {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)

        if let match = nameThenPercent?.firstMatch(in: line, range: range), match.numberOfRanges >= 3 {
            let name = ns.substring(with: match.range(at: 1))
            let percent = Double(ns.substring(with: match.range(at: 2)))
            if let category = makeCategory(name: name, percent: percent, evidence: line) {
                return category
            }
        }

        if let match = percentThenName?.firstMatch(in: line, range: range), match.numberOfRanges >= 3 {
            let percent = Double(ns.substring(with: match.range(at: 1)))
            let name = ns.substring(with: match.range(at: 2))
            if let category = makeCategory(name: name, percent: percent, evidence: line) {
                return category
            }
        }
        return nil
    }

    private static func makeCategory(name rawName: String, percent: Double?, evidence: String) -> SyllabusCategory? {
        guard let percent, percent > 0, percent <= 100 else { return nil }
        let name = rawName
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-:.()"))
            .trimmingCharacters(in: .whitespaces)
        guard isPlausibleCategoryName(name) else { return nil }
        let key = TitleNormalizer.categoryKey(name)
        guard !key.isEmpty else { return nil }
        return SyllabusCategory(id: key, name: name, weightPercent: percent, evidence: evidence)
    }

    /// Names that look like a category, not like prose or a table footer.
    ///
    /// The two that matter most: a **"Total 100%"** row would double the sum
    /// and blow the gate on an otherwise perfect table, and comparison phrasing
    /// ("attendance below 80% results in…") reads as a category named
    /// "attendance below" worth 80%.
    static func isPlausibleCategoryName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard name.count >= 2, name.count <= 48 else { return false }
        guard name.contains(where: { $0.isLetter }) else { return false }

        let totalRows: Set<String> = ["total", "totals", "overall", "sum", "grand total", "course total", "final grade", "grade", "grades", "percentage", "percent", "weight", "weighting", "component", "components", "category", "categories"]
        if totalRows.contains(lower) { return false }

        let comparisons = ["below", "at least", "fewer than", "less than", "more than", "greater than", "no less", "no more", "up to", "minimum", "maximum", "under ", "over "]
        if comparisons.contains(where: { lower.contains($0) }) { return false }

        return true
    }

    // MARK: - Drop rules

    /// "the lowest two quizzes are dropped" → 2 for the Quizzes category. An
    /// unqualified "your lowest score is dropped" means one.
    private static func dropCount(for category: SyllabusCategory, in sentences: [String]) -> Int {
        for sentence in sentences {
            let lower = sentence.lowercased()
            guard lower.contains("drop"), lower.contains("lowest") else { continue }
            guard mentions(category, in: sentence) else { continue }
            return firstCount(in: lower) ?? 1
        }
        return 0
    }

    // MARK: - Expected item counts

    /// "there will be 10 problem sets over the semester" → 10, which is how the
    /// report can say "Canvas lists 7 of your 10 problem sets."
    private static func expectedCount(for category: SyllabusCategory, in sentences: [String]) -> Int? {
        for sentence in sentences {
            let lower = sentence.lowercased()
            guard mentions(category, in: sentence) else { continue }
            // Only count phrasings that state a quantity of the thing, not a
            // weight ("10 problem sets") — a percentage in the same sentence
            // is far more likely to be the weight we already read.
            guard !lower.contains("%") else { continue }
            guard let count = countImmediatelyBefore(category, in: lower) else { continue }
            guard count >= 2, count <= 60 else { continue }
            return count
        }
        return nil
    }

    /// A number within three words before a token of the category's name.
    private static func countImmediatelyBefore(_ category: SyllabusCategory, in lowerSentence: String) -> Int? {
        let categoryTokens = Set(TitleNormalizer.categoryTokens(category.name))
        guard !categoryTokens.isEmpty else { return nil }

        let words = lowerSentence
            .replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)

        for (index, word) in words.enumerated() {
            guard let value = numericValue(word) else { continue }
            let window = words[(index + 1)..<min(index + 4, words.count)]
            // Normalize the window as a phrase, not word by word: "problem
            // sets" only collapses to the canonical `hw` token when the two
            // words are seen together, and tokenizing them separately yields
            // ["problem"], ["set"] — which never matches a "Problem Sets"
            // category.
            let windowTokens = Set(TitleNormalizer.categoryTokens(window.joined(separator: " ")))
            if !windowTokens.isDisjoint(with: categoryTokens) { return value }
        }
        return nil
    }

    /// True when a sentence is talking about this category — by shared
    /// normalized tokens, so "PSets" reaches a "Problem Sets" category.
    private static func mentions(_ category: SyllabusCategory, in sentence: String) -> Bool {
        let categoryTokens = Set(TitleNormalizer.categoryTokens(category.name))
            .subtracting(["and", "the", "of", "your"])
        guard !categoryTokens.isEmpty else { return false }
        let sentenceTokens = Set(TitleNormalizer.categoryTokens(sentence))
        return !sentenceTokens.isDisjoint(with: categoryTokens)
    }

    private static func firstCount(in lowerText: String) -> Int? {
        for word in lowerText.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let value = numericValue(String(word)), value >= 1, value <= 20 { return value }
        }
        return nil
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20,
    ]

    private static func numericValue(_ word: String) -> Int? {
        if let value = Int(word) { return value }
        return numberWords[word]
    }

    // MARK: - Letter cutoffs

    private static let cutoffLine = try? NSRegularExpression(
        pattern: #"(?:^|\s)([A-DF][+\-]?)\s*(?:[:=]|is|≥|>=|>)?\s*\(?(\d{1,3}(?:\.\d+)?)\s*(?:%|percent)?\s*(?:(?:-|to|and above|or higher|\+)\s*(\d{1,3}(?:\.\d+)?)?)?"#,
        options: [.caseInsensitive]
    )

    /// Standard GPA value per letter, so a syllabus that publishes its own
    /// cutoffs still lands on Penn's scale.
    private static let gpaByLetter: [String: Double] = [
        "A+": 4.0, "A": 4.0, "A-": 3.7,
        "B+": 3.3, "B": 3.0, "B-": 2.7,
        "C+": 2.3, "C": 2.0, "C-": 1.7,
        "D+": 1.3, "D": 1.0, "D-": 0.7,
        "F": 0.0,
    ]

    /// Letter rank, best first — used to validate that a parsed table is
    /// actually monotonic (better letters need higher percentages). A table
    /// that fails this is a misread, not an unusual grading policy.
    private static let letterRank: [String] = ["A+", "A", "A-", "B+", "B", "B-", "C+", "C", "C-", "D+", "D", "D-", "F"]

    static func cutoffs(in text: String) -> GradeCutoffs? {
        var minByLetter: [String: Double] = [:]

        for line in lines(in: text) {
            let ns = line as NSString
            guard let matches = cutoffLine?.matches(in: line, range: NSRange(location: 0, length: ns.length)),
                  !matches.isEmpty
            else { continue }

            for match in matches where match.numberOfRanges >= 3 {
                let letter = ns.substring(with: match.range(at: 1)).uppercased()
                guard gpaByLetter[letter] != nil else { continue }
                guard let first = Double(ns.substring(with: match.range(at: 2))) else { continue }

                // "A 93-100" and "A 100-93" both mean "A starts at 93".
                var minPercent = first
                if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound,
                   let second = Double(ns.substring(with: match.range(at: 3))) {
                    minPercent = Swift.min(first, second)
                }
                guard minPercent > 0, minPercent <= 100 else { continue }
                // First statement of a letter wins; later mentions in prose
                // ("you need an A to...") don't overwrite the table.
                if minByLetter[letter] == nil { minByLetter[letter] = minPercent }
            }
        }

        guard minByLetter.count >= 3 else { return nil }

        let bands = minByLetter
            .map { GradeBand(letter: $0.key, minPercent: $0.value, gpa: gpaByLetter[$0.key] ?? 0) }
            .sorted { $0.minPercent > $1.minPercent }

        // Reject a table whose percentages don't descend with the letters.
        let ranks = bands.compactMap { letterRank.firstIndex(of: $0.letter) }
        guard ranks.count == bands.count, ranks == ranks.sorted() else { return nil }

        return GradeCutoffs(bands: bands, isCustom: true)
    }

    // MARK: - Curve

    /// Narrow on purpose: "subject to change" is boilerplate in nearly every
    /// syllabus and would flag every course, which would train the user to
    /// ignore the warning.
    static func mentionsCurve(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "curve", "curved", "curving",
            "scaled", "scaling",
            "instructor's discretion", "instructor discretion",
            "discretion of the instructor",
            "adjusted upward", "adjusted upwards",
        ]
        return markers.contains { lower.contains($0) }
    }
}
