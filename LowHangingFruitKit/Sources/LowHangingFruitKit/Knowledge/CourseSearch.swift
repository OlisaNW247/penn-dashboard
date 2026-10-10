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

/// Retrieval over the course knowledge base: BM25 keyword search (with the
/// query widened by a small synonym table, `QueryExpansion`), an optional
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
        let documentsByID = Dictionary(knowledge.documents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.documents = documentsByID
        // The titles go in with the passages so a page is findable by its
        // name; see `BM25Index.init(passages:titles:)`.
        self.index = BM25Index(passages: all, titles: documentsByID.mapValues(\.title))
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
    ///   - limit: how many passages to return.
    ///   - perDocument: how many of those may come from one document. The
    ///     default of 2 keeps one long syllabus from crowding out an
    ///     announcement that answers the question directly; a caller asking
    ///     for more passages (a larger `limit`) can raise it.
    public func search(
        _ query: String,
        courseID: String? = nil,
        kinds: Set<CourseDocument.Kind>? = nil,
        preferredComponent: DocumentComponent? = nil,
        limit: Int = 5,
        perDocument: Int = 2
    ) -> [SearchHit] {
        search(query, courseIDs: courseID.map { [$0] }, kinds: kinds, preferredComponent: preferredComponent, limit: limit, perDocument: perDocument)
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
    ///
    /// A scope is a guess about what the question meant, not a fact: the
    /// course matcher can pick the wrong class, or the right class can
    /// simply not hold the answer (a question about "the exam in CIS 2400"
    /// whose answer is in an announcement filed under another site). So a
    /// non-empty scope that finds nothing is retried once, unscoped, rather
    /// than answering "I couldn't find that" from a filter that may have
    /// been wrong. The hits then carry their own course, so the reader can
    /// see they came from somewhere else. (The empty set above is a
    /// different case: it means the caller found no sites at all, and stays
    /// "no hits.")
    public func search(
        _ query: String,
        courseIDs: Set<String>?,
        kinds: Set<CourseDocument.Kind>? = nil,
        preferredComponent: DocumentComponent? = nil,
        limit: Int = 5,
        perDocument: Int = 2
    ) -> [SearchHit] {
        guard !index.isEmpty else { return [] }
        let candidates = index.matches(for: QueryExpansion.weightedTerms(for: query))
        let scoped = rank(
            candidates, query: query, courseIDs: courseIDs, kinds: kinds,
            preferredComponent: preferredComponent, limit: limit, perDocument: perDocument
        )
        guard scoped.isEmpty, let courseIDs, !courseIDs.isEmpty else { return scoped }
        return rank(
            candidates, query: query, courseIDs: nil, kinds: kinds,
            preferredComponent: preferredComponent, limit: limit, perDocument: perDocument
        )
    }

    /// Scope, boost, cut, rerank, cap — in that order. The order is the
    /// point: the BM25 list is *every* matching passage, and the scope
    /// (course, kind) and the kind/component boosts are applied to all of
    /// it before anything is thrown away. This used to take BM25's global
    /// top 30 first and filter to the named course afterwards, so with five
    /// courses synced the named course's best passages could be outscored
    /// by thirty passages from other courses and cut before the filter ever
    /// saw them, leaving "no hits" for a question the materials answer. The
    /// boosts had the same problem in miniature: a lab passage boosted ×1.5
    /// could not climb into a pool it had already been cut from.
    private func rank(
        _ candidates: [BM25Index.Hit],
        query: String,
        courseIDs: Set<String>?,
        kinds: Set<CourseDocument.Kind>?,
        preferredComponent: DocumentComponent?,
        limit: Int,
        perDocument: Int
    ) -> [SearchHit] {
        // Classify once per document per search, not once per passage: a
        // syllabus contributing two passages (the `perDocument` cap below)
        // should not pay for `DocumentComponent.component(of:in:)` twice.
        var componentByDocument: [String: DocumentComponent] = [:]
        func component(of document: CourseDocument) -> DocumentComponent {
            if let cached = componentByDocument[document.id] { return cached }
            let resolved = DocumentComponent.component(of: document, in: knowledge)
            componentByDocument[document.id] = resolved
            return resolved
        }
        var kindBoostByKind: [CourseDocument.Kind: Double] = [:]

        var scored: [(passage: Passage, document: CourseDocument, score: Double)] = []
        for hit in candidates {
            guard let passage = passages[hit.passageID], let document = documents[passage.documentID] else { continue }
            if let courseIDs, !courseIDs.contains(document.courseID) { continue }
            if let kinds, !kinds.contains(document.kind) { continue }
            let kindBoost = kindBoostByKind[document.kind] ?? self.kindBoost(document.kind, query: query)
            kindBoostByKind[document.kind] = kindBoost
            // Only a question that names a component needs to know which
            // component each document is before the cut; otherwise the
            // classification waits until the pool is small.
            let componentBoost = preferredComponent == nil
                ? 1.0
                : self.componentBoost(component(of: document), preferredComponent: preferredComponent)
            scored.append((passage, document, hit.score * kindBoost * componentBoost))
        }

        // Over-fetch so the rerank has something to work with.
        let pool = max(limit * 6, 30)
        var hits: [SearchHit] = Self.descendingOrder(of: scored.map(\.score)).prefix(pool).map { position in
            let item = scored[position]
            return SearchHit(passage: item.passage, document: item.document, score: item.score, component: component(of: item.document))
        }
        hits = rerank(query: query, hits: hits)

        // At most `perDocument` passages per document (two by default) so
        // one long syllabus can't crowd out an announcement that answers
        // the question directly.
        var seenPerDocument: [String: Int] = [:]
        var result: [SearchHit] = []
        for position in Self.descendingOrder(of: hits.map(\.score)) {
            let hit = hits[position]
            let seen = seenPerDocument[hit.document.id, default: 0]
            guard seen < perDocument else { continue }
            seenPerDocument[hit.document.id] = seen + 1
            result.append(hit)
            if result.count >= limit { break }
        }
        return result
    }

    /// Indices of `scores`, highest score first. Equal scores keep their
    /// incoming order, so the ranking never depends on the sort's choice
    /// between ties.
    private static func descendingOrder(of scores: [Double]) -> [Int] {
        scores.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
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
        // An Ed Discussion announcement or pinned staff post is the same
        // kind of signal as a Canvas announcement: short, recent, and
        // usually the newest word on a deadline or a change. So it shares
        // the announcement weighting rather than the neutral one.
        case .announcement, .ed:
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
