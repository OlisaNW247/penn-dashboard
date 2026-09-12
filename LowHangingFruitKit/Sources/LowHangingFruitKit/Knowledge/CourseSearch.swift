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
    /// Which component of a multi-component course site (lecture vs. lab
    /// vs. recitation) `document` belongs to. Defaults to classifying
    /// `document` when not supplied, so a caller that already computed this
    /// (as `CourseSearch.search` does, once per document per search) can
    /// pass it through instead of paying for a second classification.
    public let component: DocumentComponent

    public init(passage: Passage, document: CourseDocument, score: Double, component: DocumentComponent? = nil) {
        self.passage = passage
        self.document = document
        self.score = score
        self.component = component ?? DocumentComponent.classify(title: document.title, text: document.text)
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
    /// Where the on-device sentence embedding comes from. Defaults to the
    /// process-wide `.shared` instance — every real call site wants that one
    /// so a downloaded embedding, once warmed up anywhere, benefits every
    /// search in the process — and exists as a parameter only so a test can
    /// hand this a fresh, cold provider instead of racing whatever state
    /// `.shared` happens to be in from another test or from a real
    /// `NLEmbedding` asset actually present on the machine running the
    /// suite.
    private let embeddingProvider: SentenceEmbeddingProvider

    public init(knowledge: CourseKnowledgeBase) {
        self.init(knowledge: knowledge, embeddingProvider: .shared)
    }

    init(knowledge: CourseKnowledgeBase, embeddingProvider: SentenceEmbeddingProvider) {
        self.knowledge = knowledge
        self.embeddingProvider = embeddingProvider
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
    ///   - preferredComponent: when a query names a course component (a "lab
    ///     late policy" or "class late policy" question), boost passages
    ///     from that component — or, for `.lecture`, from `.lecture` and
    ///     `.general` documents — over the others. `nil` leaves scoring
    ///     exactly as it was before component-awareness existed. Other
    ///     components are never hidden, only outranked, so the model still
    ///     sees them labelled as a possible secondary answer.
    public func search(
        _ query: String,
        courseID: String? = nil,
        kinds: Set<CourseDocument.Kind>? = nil,
        preferredComponent: DocumentComponent? = nil,
        limit: Int = 5
    ) -> [SearchHit] {
        search(query, courseIDs: courseID.map { [$0] }, kinds: kinds, preferredComponent: preferredComponent, limit: limit)
    }

    /// Like the `courseID:` overload above, except a question can now be
    /// scoped to every Canvas site of one course code at once — PHYS 0151's
    /// lecture and lab are two separate `courseID`s that share one display
    /// code, so "the late policy in PHYS 0151" has to search both sites'
    /// documents, not whichever single site an old single-`courseID` filter
    /// happened to have kept. `nil` means unscoped, same as `courseID:
    /// nil`; a non-nil, empty set means "scoped to nothing," matching
    /// nothing rather than falling back to unscoped — a caller resolving
    /// zero courseIDs for a named course should get no hits, not every
    /// course's.
    public func search(
        _ query: String,
        courseIDs: Set<String>?,
        kinds: Set<CourseDocument.Kind>? = nil,
        preferredComponent: DocumentComponent? = nil,
        limit: Int = 5
    ) -> [SearchHit] {
        guard !index.isEmpty else { return [] }
        // Over-fetch so filters and the rerank have something to work with.
        let raw = index.search(query, limit: max(limit * 6, 30))
        var hits: [SearchHit] = []
        // Classify once per document per search, not once per passage: a
        // syllabus contributing two passages (the `perDocument` cap below)
        // should not pay for `DocumentComponent.component(of:in:)` twice.
        var componentByDocument: [String: DocumentComponent] = [:]
        for hit in raw {
            guard let passage = passages[hit.passageID], let document = documents[passage.documentID] else { continue }
            if let courseIDs, !courseIDs.contains(document.courseID) { continue }
            if let kinds, !kinds.contains(document.kind) { continue }
            let component: DocumentComponent
            if let cached = componentByDocument[document.id] {
                component = cached
            } else {
                component = DocumentComponent.component(of: document, in: knowledge)
                componentByDocument[document.id] = component
            }
            let score = hit.score * kindBoost(document.kind, query: query) * componentBoost(component, preferredComponent: preferredComponent)
            hits.append(SearchHit(passage: passage, document: document, score: score, component: component))
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

    /// A preferred component boosts its own documents, treats `.general`
    /// documents (a document that isn't part of any labelled split, like a
    /// single-component course's syllabus) as an equally valid answer, and
    /// only mutes — never zeroes — the other named components. `.lecture`
    /// preference is gentler (×0.5 rather than ×0.6) than `.lab`/
    /// `.recitation` preference is on the others, per the brief: a lab
    /// passage should not be able to outrank a lecture passage for a plain
    /// "class" question, but must still surface, labelled, as a secondary
    /// hit — the whole point of this feature is that both syllabi remain
    /// visible, just correctly ordered.
    private func componentBoost(_ component: DocumentComponent, preferredComponent: DocumentComponent?) -> Double {
        guard let preferredComponent else { return 1.0 }
        switch preferredComponent {
        case .lab, .recitation:
            if component == preferredComponent { return 1.5 }
            if component == .general { return 1.0 }
            return 0.6
        case .lecture:
            if component == .lecture || component == .general { return 1.0 }
            return 0.5
        case .general:
            return 1.0
        }
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
        // Crawled site content is unvetted (no per-course policy signal
        // like a syllabus's late-work words) and of unknown freshness, so
        // it neither gets boosted nor muted — same neutral weight as `.page`.
        case .website: return 1.0
        }
    }

    /// Blends BM25 with cosine similarity from Apple's on-device sentence
    /// embedding when available. On other platforms, when the embedding
    /// asset hasn't finished loading yet, or when it turns out to be absent
    /// on this device entirely, the BM25 order stands.
    ///
    /// `embeddingProvider.current()` — never
    /// `NLEmbedding.sentenceEmbedding(for:)` called directly — is the fix for
    /// the two-minute frozen assistant bubble described on
    /// `SentenceEmbeddingProvider`'s doc comment: calling the framework
    /// function here synchronously would, on a fresh install, block whatever
    /// actor is running this search for as long as iOS takes to download the
    /// embedding asset. `current()` instead returns immediately — `nil` on
    /// every question until the asset happens to finish loading in the
    /// background, after which every subsequent question benefits for the
    /// rest of the process's life. An answer that skips the rerank entirely
    /// while cold is a strictly better outcome than a correct answer that
    /// takes minutes to start.
    private func rerank(query: String, hits: [SearchHit]) -> [SearchHit] {
        #if canImport(NaturalLanguage)
        guard hits.count > 1,
              let embedding = embeddingProvider.current() as? NLEmbedding,
              let queryVector = embedding.vector(for: query)
        else { return hits }
        let maxScore = hits.map(\.score).max() ?? 1
        return hits.map { hit in
            guard let vector = embedding.vector(for: String(hit.passage.text.prefix(600))) else { return hit }
            let similarity = cosine(queryVector, vector)
            let blended = 0.65 * (hit.score / maxScore) + 0.35 * max(0, similarity)
            // Carry the already-computed component through rather than
            // letting the default parameter reclassify — same document,
            // same answer, but reclassifying here would be exactly the
            // per-passage recomputation the caller above was written to avoid.
            return SearchHit(passage: hit.passage, document: hit.document, score: blended, component: hit.component)
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
