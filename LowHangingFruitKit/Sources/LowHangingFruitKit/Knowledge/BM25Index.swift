import Foundation

/// Tokenization shared by the index and the query side. Lowercases, splits on
/// non-alphanumerics, drops stopwords, and applies a light suffix stemmer so
/// "quizzes" matches "quiz" and "submitting" matches "submit".
public enum TextTokenizer {
    public static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "have", "i", "in", "is", "it",
        "its", "my", "of", "on", "or", "that", "the", "this", "to", "was", "we", "were", "what", "when", "where",
        "which", "who", "will", "with", "you", "your", "do", "does", "did", "can", "could", "would", "should",
        "me", "our", "us", "how", "any", "there", "about", "into", "than", "then", "them", "they", "so",
    ]

    /// - Parameter minLength: tokens shorter than this are dropped, except a
    ///   lone digit, which is always kept. The index uses 2 (single letters
    ///   are noise); item-title matching uses 1 so "pset 3" keeps its number.
    ///
    ///   The digit exception exists because a single digit is never noise in
    ///   course material: it is the whole difference between "exam 1" and
    ///   "exam 2", "lab 3" and "lab 4", "week 4" and "week 5". With a flat
    ///   length floor of 2 both sides of the index lost that digit, so a
    ///   question about Exam 2 scored Exam 1's passage exactly as high, and
    ///   the tie went to whichever was synced first. Single *letters* stay
    ///   dropped ("a", "i", the "s" left by an apostrophe).
    public static func tokens(_ text: String, minLength: Int = 2) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
            .filter { ($0.count >= minLength || isLoneDigit($0)) && !stopwords.contains($0) }
            .map(stem)
    }

    private static func isLoneDigit(_ token: String) -> Bool {
        token.count == 1 && token.allSatisfy(\.isNumber)
    }

    /// Conservative stemming: strips common English suffixes only when a
    /// reasonable stem remains. Not linguistically complete; good enough for
    /// matching course vocabulary.
    ///
    /// The one property this has to have is that a singular and its plural
    /// (and a noun and its verb forms) reach the *same* stem, because the
    /// index and the query are both stemmed and a mismatch is invisible: the
    /// passage is simply never found. The first version stripped "es" from
    /// "grades" ("grad") but left "grade" alone, so a question about "the
    /// grade" never matched a syllabus that only said "grades"; "absences" /
    /// "absence", "dates" / "date", "pages" / "page" and "class" / "classes"
    /// all had the same split. The wrong fix is a table of exceptions (the
    /// two words someone noticed). The rules instead make the split
    /// impossible by construction:
    ///
    /// 1. A plural "-es" is stripped whole only after a sibilant
    ///    ("classes", "boxes", "churches", "wishes", "quizzes"). After
    ///    anything else the "es" is really "e" + "s", so only the "s"
    ///    comes off ("dates" → "date", "grades" → "grade").
    /// 2. A word that ends in "s" because of its spelling ("class", "bonus",
    ///    "analysis") is not a plural and keeps it.
    /// 3. Whatever the stem is, one trailing "e" is dropped when at least
    ///    four letters remain ("grade" → "grad", "schedule" → "schedul",
    ///    "evaluate" / "evaluated" / "evaluation" → "evaluat"). The
    ///    four-letter floor leaves "date", "late", "rule" and "page" alone,
    ///    and rule 1 has already brought their plurals to the same place.
    public static func stem(_ word: String) -> String {
        guard word.count > 4, !word.allSatisfy(\.isNumber) else { return word }
        let suffixes = ["ations", "ation", "ings", "ing", "ies", "ied", "ers", "er", "ed", "es", "s"]
        // "submitting" → "submitt" → "submit"; "quizzes" → "quizz" → "quiz".
        let doubled = ["bb", "dd", "gg", "mm", "nn", "pp", "rr", "tt", "zz"]
        let sibilants = ["x", "ch", "sh", "ss", "zz"]
        for suffix in suffixes where word.hasSuffix(suffix) {
            var removed = suffix.count
            if suffix == "es", !sibilants.contains(where: { word.dropLast(2).hasSuffix($0) }) {
                removed = 1
            }
            if removed == 1, ["ss", "us", "is"].contains(where: { word.hasSuffix($0) }) {
                continue
            }
            let stemLength = word.count - removed
            if stemLength >= 3 {
                var stem = String(word.prefix(stemLength))
                if suffix == "ies" || suffix == "ied" { stem += "y" }
                if suffix == "ations" || suffix == "ation" { stem += "ate" }
                if doubled.contains(where: { stem.hasSuffix($0) }) { stem.removeLast() }
                return dropFinalE(stem)
            }
        }
        return dropFinalE(word)
    }

    private static func dropFinalE(_ stem: String) -> String {
        stem.hasSuffix("e") && stem.count > 4 ? String(stem.dropLast()) : stem
    }
}

/// Okapi BM25 over passages. Pure Swift, built in memory from the knowledge
/// base every time a `CourseSearch` is made. Nothing about the index is
/// persisted (only the documents are, in `CourseKnowledgeStore`), which is
/// why a change to the tokenizer or stemmer needs no migration: the next
/// question simply indexes with the new rules. A student's course corpus is
/// a few thousand passages at most, so rebuilding takes milliseconds.
public struct BM25Index: Sendable {
    public struct Hit: Sendable, Hashable {
        public let passageID: String
        public let score: Double
    }

    /// One already-tokenized (stemmed) query term and how much it counts.
    /// The student's own words weigh 1; a synonym added by `QueryExpansion`
    /// weighs less, so a passage that uses the student's own word still
    /// outranks one that only matches a guess about what they meant.
    public struct WeightedTerm: Sendable, Hashable {
        public let term: String
        public let weight: Double

        public init(term: String, weight: Double) {
            self.term = term
            self.weight = weight
        }
    }

    /// How many distinct title words a passage borrows from its document.
    /// A title is a handful of words; a document whose "title" is a
    /// pasted sentence must not be able to out-vote the passage's body.
    static let maxTitleTerms = 12

    private let k1: Double
    private let b: Double
    private let passageIDs: [String]
    private let lengths: [Int]
    private let averageLength: Double
    /// term → [(passage index, term frequency)]
    private let postings: [String: [(Int, Int)]]
    private let documentCount: Int

    /// - Parameter titles: document id → title. A passage is indexed under
    ///   its own words *plus* its document's title (each distinct title word
    ///   once, at most `maxTitleTerms`), because a page called "Midterm 2
    ///   review" is otherwise invisible to a question for it unless the body
    ///   happens to repeat the words, and a Canvas page's title is often the
    ///   one place its subject is named. Once per word, not once per
    ///   occurrence: the title is a hint about the passage, never a rival to
    ///   it.
    public init(passages: [Passage], titles: [String: String] = [:], k1: Double = 1.2, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
        var ids: [String] = []
        var lengths: [Int] = []
        var postings: [String: [(Int, Int)]] = [:]
        var titleTermsByDocument: [String: [String]] = [:]
        for (index, passage) in passages.enumerated() {
            var tokens = TextTokenizer.tokens(passage.text)
            if let title = titles[passage.documentID] {
                let titleTerms: [String]
                if let cached = titleTermsByDocument[passage.documentID] {
                    titleTerms = cached
                } else {
                    var seen: Set<String> = []
                    titleTerms = TextTokenizer.tokens(title).filter { seen.insert($0).inserted }.prefix(Self.maxTitleTerms).map { $0 }
                    titleTermsByDocument[passage.documentID] = titleTerms
                }
                tokens.append(contentsOf: titleTerms)
            }
            ids.append(passage.id)
            lengths.append(tokens.count)
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            for (term, count) in counts {
                postings[term, default: []].append((index, count))
            }
        }
        self.passageIDs = ids
        self.lengths = lengths
        self.postings = postings
        self.documentCount = ids.count
        self.averageLength = ids.isEmpty ? 1 : Double(lengths.reduce(0, +)) / Double(ids.count)
    }

    public var isEmpty: Bool { documentCount == 0 }

    public func search(_ query: String, limit: Int = 10) -> [Hit] {
        let terms = TextTokenizer.tokens(query).map { WeightedTerm(term: $0, weight: 1) }
        return Array(matches(for: terms).prefix(limit))
    }

    /// Every passage that scores above zero for `terms`, best first (ties in
    /// index order, so the result is deterministic). Not truncated, on
    /// purpose: a caller that filters or re-weights hits (`CourseSearch`
    /// narrows to one course and boosts by document kind) has to do that
    /// *before* it cuts the list, or the cut throws away passages the
    /// filter would have kept.
    public func matches(for terms: [WeightedTerm]) -> [Hit] {
        guard !terms.isEmpty, documentCount > 0 else { return [] }

        // A term repeated in the query counts once, at its largest weight.
        var weights: [String: Double] = [:]
        for term in terms { weights[term.term] = max(weights[term.term] ?? 0, term.weight) }

        var scores: [Int: Double] = [:]
        // Sorted so the floating-point sums happen in the same order every
        // run; two passages a rounding error apart must not swap places
        // between launches.
        for term in weights.keys.sorted() {
            guard let list = postings[term], let weight = weights[term] else { continue }
            let n = Double(list.count)
            let idf = log(1 + (Double(documentCount) - n + 0.5) / (n + 0.5))
            for (index, tf) in list {
                let length = Double(lengths[index])
                let tfNorm = (Double(tf) * (k1 + 1)) / (Double(tf) + k1 * (1 - b + b * length / averageLength))
                scores[index, default: 0] += weight * idf * tfNorm
            }
        }

        return scores
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .map { Hit(passageID: passageIDs[$0.key], score: $0.value) }
    }
}
