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

    /// - Parameter minLength: tokens shorter than this are dropped. The index
    ///   uses 2 (single letters are noise); item-title matching uses 1 so
    ///   "pset 3" keeps its number.
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
            .filter { $0.count >= minLength && !stopwords.contains($0) }
            .map(stem)
    }

    /// Conservative stemming: strips common English suffixes only when a
    /// reasonable stem remains. Not linguistically complete; good enough for
    /// matching course vocabulary.
    public static func stem(_ word: String) -> String {
        guard word.count > 4, !word.allSatisfy(\.isNumber) else { return word }
        let suffixes = ["ations", "ation", "ings", "ing", "ies", "ied", "ers", "er", "ed", "es", "s"]
        // "submitting" → "submitt" → "submit"; "quizzes" → "quizz" → "quiz".
        let doubled = ["bb", "dd", "gg", "mm", "nn", "pp", "rr", "tt", "zz"]
        for suffix in suffixes where word.hasSuffix(suffix) {
            let stemLength = word.count - suffix.count
            if stemLength >= 3 {
                var stem = String(word.prefix(stemLength))
                if suffix == "ies" || suffix == "ied" { stem += "y" }
                if suffix == "ations" || suffix == "ation" { stem += "ate" }
                if doubled.contains(where: { stem.hasSuffix($0) }) { stem.removeLast() }
                return stem
            }
        }
        return word
    }
}

/// Okapi BM25 over passages. Pure Swift, built in memory from the knowledge
/// base at launch (a student's course corpus is a few thousand passages at
/// most, so rebuilding takes milliseconds).
public struct BM25Index: Sendable {
    public struct Hit: Sendable, Hashable {
        public let passageID: String
        public let score: Double
    }

    private let k1: Double
    private let b: Double
    private let passageIDs: [String]
    private let lengths: [Int]
    private let averageLength: Double
    /// term → [(passage index, term frequency)]
    private let postings: [String: [(Int, Int)]]
    private let documentCount: Int

    public init(passages: [Passage], k1: Double = 1.2, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
        var ids: [String] = []
        var lengths: [Int] = []
        var postings: [String: [(Int, Int)]] = [:]
        for (index, passage) in passages.enumerated() {
            let tokens = TextTokenizer.tokens(passage.text)
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
        let terms = TextTokenizer.tokens(query)
        guard !terms.isEmpty, documentCount > 0 else { return [] }

        var scores: [Int: Double] = [:]
        for term in Set(terms) {
            guard let list = postings[term] else { continue }
            let n = Double(list.count)
            let idf = log(1 + (Double(documentCount) - n + 0.5) / (n + 0.5))
            for (index, tf) in list {
                let length = Double(lengths[index])
                let tfNorm = (Double(tf) * (k1 + 1)) / (Double(tf) + k1 * (1 - b + b * length / averageLength))
                scores[index, default: 0] += idf * tfNorm
            }
        }

        return scores
            .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
            .prefix(limit)
            .map { Hit(passageID: passageIDs[$0.key], score: $0.value) }
    }
}
