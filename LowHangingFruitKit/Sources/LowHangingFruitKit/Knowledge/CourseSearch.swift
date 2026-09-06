import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// One search result: the passage, the document it came from, and a score.
public struct SearchHit: Sendable, Hashable, Identifiable {
    public var id: String { passage.id }
    public let passage: Passage
    public let document: CourseDocument
    public let score: Double

    public init(passage: Passage, document: CourseDocument, score: Double) {
        self.passage = passage
        self.document = document
        self.score = score
    }
}

/// Retrieval over the course knowledge base: BM25 keyword search, an optional
/// course filter, a small boost for the kinds of documents most likely to
/// answer policy questions, and (on Apple platforms) an on-device sentence
/// embedding rerank from the NaturalLanguage framework. No network, no keys.
public struct CourseSearch: Sendable {
    public let knowledge: CourseKnowledgeBase
    private let passages: [String: Passage]
    private let documents: [String: CourseDocument]
    private let index: BM25Index

    public init(knowledge: CourseKnowledgeBase) {
        self.knowledge = knowledge
        var passageMap: [String: Passage] = [:]
        var all: [Passage] = []
        for document in knowledge.documents {
            for passage in PassageChunker.passages(for: document) {
                passageMap[passage.id] = passage
                all.append(passage)
            }
        }
        self.passages = passageMap
        self.documents = Dictionary(knowledge.documents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.index = BM25Index(passages: all)
    }

    public var isEmpty: Bool { index.isEmpty }

    /// - Parameters:
    ///   - courseID: restrict to one course when the question names it.
    ///   - kinds: restrict to document kinds (e.g. only announcements).
    public func search(
        _ query: String,
        courseID: String? = nil,
        kinds: Set<CourseDocument.Kind>? = nil,
        limit: Int = 5
    ) -> [SearchHit] {
        guard !index.isEmpty else { return [] }
        // Over-fetch so filters and the rerank have something to work with.
        let raw = index.search(query, limit: max(limit * 6, 30))
        var hits: [SearchHit] = []
        for hit in raw {
            guard let passage = passages[hit.passageID], let document = documents[passage.documentID] else { continue }
            if let courseID, document.courseID != courseID { continue }
            if let kinds, !kinds.contains(document.kind) { continue }
            hits.append(SearchHit(passage: passage, document: document, score: hit.score * kindBoost(document.kind, query: query)))
        }
        hits = rerank(query: query, hits: hits)
        // At most two passages per document so one long syllabus can't crowd
        // out an announcement that answers the question directly.
        var perDocument: [String: Int] = [:]
        var result: [SearchHit] = []
        for hit in hits.sorted(by: { $0.score > $1.score }) {
            let seen = perDocument[hit.document.id, default: 0]
            guard seen < 2 else { continue }
            perDocument[hit.document.id] = seen + 1
            result.append(hit)
            if result.count == limit { break }
        }
        return result
    }

    private func kindBoost(_ kind: CourseDocument.Kind, query: String) -> Double {
        let q = query.lowercased()
        switch kind {
        case .syllabus:
            let policyWords = ["policy", "late", "grading", "grade", "attendance", "office hours", "textbook", "exam", "midterm", "final", "weight", "percent", "curve", "extension", "collaboration", "honor", "absence"]
            return policyWords.contains(where: q.contains) ? 1.35 : 1.1
        case .announcement:
            let recentWords = ["announce", "announcement", "said", "posted", "update", "news", "cancel", "reschedul", "moved", "change"]
            return recentWords.contains(where: q.contains) ? 1.4 : 1.0
        case .assignment: return 1.05
        case .page: return 1.0
        case .module: return 0.9
        case .home: return 0.9
        }
    }

    /// Blends BM25 with cosine similarity from Apple's on-device sentence
    /// embedding when available. On other platforms (and when the embedding
    /// asset isn't downloaded) the BM25 order stands.
    private func rerank(query: String, hits: [SearchHit]) -> [SearchHit] {
        #if canImport(NaturalLanguage)
        guard hits.count > 1,
              let embedding = NLEmbedding.sentenceEmbedding(for: .english),
              let queryVector = embedding.vector(for: query)
        else { return hits }
        let maxScore = hits.map(\.score).max() ?? 1
        return hits.map { hit in
            guard let vector = embedding.vector(for: String(hit.passage.text.prefix(600))) else { return hit }
            let similarity = cosine(queryVector, vector)
            let blended = 0.65 * (hit.score / maxScore) + 0.35 * max(0, similarity)
            return SearchHit(passage: hit.passage, document: hit.document, score: blended)
        }
        #else
        return hits
        #endif
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
