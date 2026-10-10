import Foundation

/// Query-side synonym expansion for course search. Students ask for "the
/// midterm", the syllabus says "Exam 1"; they ask about "hw", the page says
/// "Problem Set 3"; they ask about "OH", the syllabus says "office hours".
/// BM25 is a bag of exact (stemmed) words, so without help none of those
/// questions find their answer.
///
/// **Why the table is applied to the query and never to the index.** The
/// passages are the student's and their classmates' course material, and the
/// index is rebuilt from it on every search. Expanding the *index* would mean
/// every passage that says "exam" also silently says "midterm", "prelim" and
/// "mid" and "term", which dilutes the real words, changes passage lengths
/// (and so every score), and makes a table edit change what the whole corpus
/// matches. Expanding the *query* touches one short string, costs nothing
/// per passage, and can be turned off or tuned by editing this one table.
/// The wrong fix is to broaden by stemming harder or to write the synonyms
/// into the document text: the document text is hashed and pooled with
/// classmates, so any change to it re-uploads the same course for everyone.
///
/// Expansion terms count for less than the student's own words
/// (`expansionWeight`, split across a multi-word phrase), so a passage that
/// uses the student's word outranks one that merely matches a guess about
/// what they meant. The table is deliberately small and conservative: each
/// group is a set of phrases a student would treat as the same thing, and
/// an unrelated pairing here costs retrieval quality for every question that
/// mentions either word.
public enum QueryExpansion {
    /// How much a whole expansion phrase counts, against 1 for each of the
    /// student's own words. A phrase of several words ("problem set")
    /// spreads this across its words, so two common words ("problem",
    /// "set") together weigh the same as one distinctive word ("pset").
    static let expansionWeight = 0.4

    /// Groups of phrases that mean the same thing to a student. If the
    /// question contains any phrase in a group (plurals and stemming are
    /// handled by running both sides through `TextTokenizer`), the group's
    /// other phrases are added to the query at reduced weight. Phrases are
    /// plain English; short forms whose plural the stemmer does not touch
    /// ("tas", "hws") are listed explicitly.
    static let synonymGroups: [[String]] = [
        ["midterm", "mid-term", "prelim", "exam"],
        ["final", "final exam"],
        ["hw", "hws", "homework", "pset", "problem set", "ps"],
        ["ta", "tas", "teaching assistant"],
        ["oh", "office hours"],
        ["prof", "professor", "instructor"],
        ["attendance", "absence"],
        ["late", "lateness", "extension"],
        ["grading", "grade breakdown", "weights"],
    ]

    /// Each phrase as the stemmed word sequence the tokenizer would make of
    /// it, computed once.
    private static let compiledGroups: [[[String]]] = synonymGroups.map { group in
        group.map { TextTokenizer.tokens($0, minLength: 1) }.filter { !$0.isEmpty }
    }

    /// The query's own words at weight 1, plus the synonyms of any group the
    /// question touches at `expansionWeight`. A synonym that is already one
    /// of the student's own words keeps its full weight.
    public static func weightedTerms(for query: String) -> [BM25Index.WeightedTerm] {
        var weights: [String: Double] = [:]
        for token in TextTokenizer.tokens(query) { weights[token] = 1 }

        // Phrases are matched as a contiguous run of words, so detection
        // looks at every word (`minLength: 1`, the same setting the phrases
        // were compiled with) rather than only the ones the index keeps.
        // Only words the index would keep are added back as terms below.
        let words = TextTokenizer.tokens(query, minLength: 1)
        for group in compiledGroups where group.contains(where: { containsRun($0, in: words) }) {
            for phrase in group {
                let each = expansionWeight / Double(phrase.count)
                for token in phrase where token.count >= 2 || token.allSatisfy(\.isNumber) {
                    weights[token] = max(weights[token] ?? 0, each)
                }
            }
        }
        return weights
            .sorted { $0.key < $1.key }
            .map { BM25Index.WeightedTerm(term: $0.key, weight: $0.value) }
    }

    private static func containsRun(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count)
        where Array(words[start..<(start + phrase.count)]) == phrase {
            return true
        }
        return false
    }
}
