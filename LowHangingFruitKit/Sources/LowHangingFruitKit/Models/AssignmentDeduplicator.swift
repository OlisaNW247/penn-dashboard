import Foundation

/// Collapses an assignment a professor posted on BOTH Canvas and Gradescope
/// into a single dashboard item, so the user doesn't see (and have to
/// separately complete) two copies of the same homework.
///
/// This is deliberately conservative — per the design brief, a false merge
/// (two genuinely different assignments collapsed into one) is worse than a
/// missed merge (a real duplicate that still shows twice). Every rule below
/// exists to keep the false-merge rate near zero:
///
///  1. Matching is always scoped to the same course (`Assignment.course`,
///     already normalized by `CourseCode.parse` upstream) — "HW 3" in two
///     different classes is never considered the same assignment.
///  2. Two titles that normalize to the exact same token sequence (see
///     `normalize`) are a match — but ONLY collapsed if neither side's due
///     date contradicts it (see `sameTitleMaxDueGap`): a generic recurring
///     title like "Reading Response" appearing on both platforms weeks apart
///     is more likely two different instances than one assignment.
///  3. Two titles that are merely SIMILAR (not identical after
///     normalization) additionally require both due dates to be known and
///     within ~24h of each other — title similarity alone is too easy to
///     false-positive on ("Midterm Review" vs. "Midterm").
///  4. Matching is 1:1 — a greedy, highest-confidence-first assignment, so
///     one Canvas item can absorb at most one Gradescope item and vice versa.
public enum AssignmentDeduplicator {
    /// One confirmed cross-platform pairing, identified by `Assignment.id`
    /// (`"source:sourceID"`) on each side.
    public struct Match: Sendable, Hashable {
        public let canvasID: String
        public let gradescopeID: String

        public init(canvasID: String, gradescopeID: String) {
            self.canvasID = canvasID
            self.gradescopeID = gradescopeID
        }
    }

    /// Two titles normalizing identically are still refused as a match if
    /// both sides carry a due date and those dates are more than this far
    /// apart (rule 2 above) — guards against generically-named recurring
    /// work appearing on both platforms in different weeks.
    private static let sameTitleMaxDueGap: TimeInterval = 21 * 86_400

    /// How close two due dates must be, when titles are only SIMILAR (not
    /// identical) for the pair to still be considered a duplicate (rule 3
    /// above). "~24h" per the design brief, with a little slack for
    /// timezone/rounding differences between the two platforms' feeds.
    private static let similarTitleDueDateTolerance: TimeInterval = 26 * 3600

    /// Minimum Jaccard similarity (over normalized token sets) for two
    /// non-identical titles to even be considered for the due-date-gated
    /// similar-title tier. Deliberately higher than `GradescopeOverlay`'s
    /// 0.5 fuzzy-grade-matching threshold: that tier only ever proposes a
    /// user-confirmable suggestion, while a dashboard merge here is applied
    /// automatically with no confirmation step, so it needs a stronger signal.
    private static let similarTitleThreshold = 0.6

    // MARK: - Pure heuristic (unit-testable in isolation)

    /// Whether two assignment postings — described only by title and due
    /// date — are plausibly the same assignment. Course scoping is the
    /// caller's job (see `matchPairs`); this function knows nothing about
    /// courses.
    public static func isLikelyDuplicate(
        titleA: String,
        dueA: Date?,
        titleB: String,
        dueB: Date?
    ) -> Bool {
        let tokensA = normalize(titleA)
        let tokensB = normalize(titleB)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return false }

        if tokensA == tokensB {
            if let dueA, let dueB, abs(dueA.timeIntervalSince(dueB)) > sameTitleMaxDueGap {
                return false
            }
            return true
        }

        guard let dueA, let dueB,
              abs(dueA.timeIntervalSince(dueB)) <= similarTitleDueDateTolerance
        else { return false }

        return jaccardSimilarity(Set(tokensA), Set(tokensB)) >= similarTitleThreshold
    }

    // MARK: - Course-scoped, 1:1 pairing

    /// Finds the best conservative 1:1 pairing between `canvasItems` and
    /// `gradescopeItems`, scoped to matching `course` on both sides. Greedy:
    /// candidate pairs are scored (exact normalized title beats a fuzzy
    /// similar-title match) and assigned highest-confidence first, skipping
    /// any item already claimed by an earlier, better pairing — so no item
    /// is ever merged twice.
    /// `confirmedPairings` are pairings this app has already established on a
    /// previous sync and written to the ledger. They are honored **before** the
    /// heuristic runs and are not re-tested against it.
    ///
    /// This is what makes a merge survive a professor moving a due date. The
    /// similar-title tier requires both dates within ~26h (rule 3); if the date
    /// moves on Canvas but not on Gradescope, that test starts failing and a
    /// pair the user has been treating as one assignment silently splits into
    /// two cards — with completion state stranded on whichever half they had
    /// ticked. Once we've seen the two together, we keep them together.
    public static func matchPairs(
        canvasItems: [Assignment],
        gradescopeItems: [Assignment],
        confirmedPairings: [Match] = []
    ) -> [Match] {
        guard !canvasItems.isEmpty, !gradescopeItems.isEmpty else { return [] }

        struct Candidate {
            let canvas: Assignment
            let gradescope: Assignment
            let score: Double
        }

        // Honor stored pairings first, but only while BOTH sides are still
        // present — a pairing referencing an item that's gone is stale, and
        // reviving it would resurrect an assignment the ledger has retired.
        let canvasIDs = Set(canvasItems.map(\.id))
        let gradescopeIDs = Set(gradescopeItems.map(\.id))
        var matches: [Match] = []
        var usedCanvasIDs: Set<String> = []
        var usedGradescopeIDs: Set<String> = []
        for pairing in confirmedPairings {
            guard canvasIDs.contains(pairing.canvasID),
                  gradescopeIDs.contains(pairing.gradescopeID),
                  !usedCanvasIDs.contains(pairing.canvasID),
                  !usedGradescopeIDs.contains(pairing.gradescopeID)
            else { continue }
            usedCanvasIDs.insert(pairing.canvasID)
            usedGradescopeIDs.insert(pairing.gradescopeID)
            matches.append(pairing)
        }

        var candidates: [Candidate] = []
        for canvasItem in canvasItems where !usedCanvasIDs.contains(canvasItem.id) {
            for gradescopeItem in gradescopeItems
            where gradescopeItem.course == canvasItem.course
                && !usedGradescopeIDs.contains(gradescopeItem.id) {
                guard isLikelyDuplicate(
                    titleA: canvasItem.title, dueA: canvasItem.dueAt,
                    titleB: gradescopeItem.title, dueB: gradescopeItem.dueAt
                ) else { continue }
                candidates.append(Candidate(
                    canvas: canvasItem,
                    gradescope: gradescopeItem,
                    score: matchScore(canvasItem, gradescopeItem)
                ))
            }
        }

        // Highest confidence first; ties broken by the closer due-date gap,
        // then by a stable id comparison so the result is deterministic.
        let ordered = candidates.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let gapA = dueDateGap(a.canvas.dueAt, a.gradescope.dueAt)
            let gapB = dueDateGap(b.canvas.dueAt, b.gradescope.dueAt)
            if gapA != gapB { return gapA < gapB }
            return a.canvas.id < b.canvas.id
        }

        for candidate in ordered {
            guard !usedCanvasIDs.contains(candidate.canvas.id),
                  !usedGradescopeIDs.contains(candidate.gradescope.id)
            else { continue }
            usedCanvasIDs.insert(candidate.canvas.id)
            usedGradescopeIDs.insert(candidate.gradescope.id)
            matches.append(Match(canvasID: candidate.canvas.id, gradescopeID: candidate.gradescope.id))
        }
        return matches
    }

    private static func matchScore(_ canvas: Assignment, _ gradescope: Assignment) -> Double {
        let tokensA = normalize(canvas.title)
        let tokensB = normalize(gradescope.title)
        if tokensA == tokensB { return 2.0 } // exact-title tier always outranks fuzzy
        return jaccardSimilarity(Set(tokensA), Set(tokensB))
    }

    private static func dueDateGap(_ a: Date?, _ b: Date?) -> TimeInterval {
        guard let a, let b else { return .greatestFiniteMagnitude }
        return abs(a.timeIntervalSince(b))
    }

    // MARK: - Merge (builds the single dashboard-visible item)

    /// Combines Canvas + Gradescope items for the dashboard: every matched
    /// pair (`matchPairs`) collapses to ONE item anchored on the Canvas copy
    /// (requirement: Canvas has richer metadata), with `linkedID` set so
    /// completion can propagate to the Gradescope identity too. Everything
    /// that doesn't match passes through unchanged. Order is not
    /// guaranteed — callers sort separately.
    public static func merge(
        canvasItems: [Assignment],
        gradescopeItems: [Assignment],
        confirmedPairings: [Match] = []
    ) -> [Assignment] {
        let matches = matchPairs(
            canvasItems: canvasItems,
            gradescopeItems: gradescopeItems,
            confirmedPairings: confirmedPairings
        )
        guard !matches.isEmpty else { return canvasItems + gradescopeItems }

        let gradescopeByID = Dictionary(uniqueKeysWithValues: gradescopeItems.map { ($0.id, $0) })
        let gradescopeIDByCanvasID = Dictionary(uniqueKeysWithValues: matches.map { ($0.canvasID, $0.gradescopeID) })
        let matchedGradescopeIDs = Set(matches.map(\.gradescopeID))

        let mergedCanvas = canvasItems.map { canvasItem -> Assignment in
            guard let gradescopeID = gradescopeIDByCanvasID[canvasItem.id],
                  let gradescopeItem = gradescopeByID[gradescopeID]
            else { return canvasItem }
            return mergedAssignment(canvas: canvasItem, gradescope: gradescopeItem)
        }
        let unmatchedGradescope = gradescopeItems.filter { !matchedGradescopeIDs.contains($0.id) }
        return mergedCanvas + unmatchedGradescope
    }

    /// Builds the single dashboard-visible item for one matched pair. Canvas
    /// supplies the display metadata (title, due date, url, term, kind), but
    /// `submitted` is true if EITHER side reports it (Canvas's ICS-derived
    /// flag is always false in practice — Canvas submission truth actually
    /// flows through `AppState.submittedCanvasAssignmentIDs` separately and
    /// is unaffected by this merge, since the merged item keeps Canvas's own
    /// `sourceID`/`url` — but folding in Gradescope's `submitted` here means
    /// a Gradescope-reported completion doesn't need that separate channel).
    /// `linkedID` records the Gradescope identity so `AppState.markCompleted`
    /// /`markActive` can propagate a manual completion to both underlying IDs
    /// — which also means each identity's completion state stays independently
    /// correct if a later sync no longer matches the pair.
    public static func mergedAssignment(canvas: Assignment, gradescope: Assignment) -> Assignment {
        Assignment(
            source: canvas.source,
            sourceID: canvas.sourceID,
            kind: canvas.kind,
            course: canvas.course,
            title: canvas.title,
            dueAt: canvas.dueAt,
            url: canvas.url,
            term: canvas.term,
            submitted: canvas.submitted || gradescope.submitted,
            scoreEarned: canvas.scoreEarned ?? gradescope.scoreEarned,
            scoreMax: canvas.scoreMax ?? gradescope.scoreMax,
            linkedID: gradescope.id
        )
    }

    // MARK: - Canvas ICS ↔ Canvas Modules collapse

    /// One `.canvasModules` row hidden because a `.canvas` (ICS) row already
    /// covers the same assignment.
    public struct CanvasCollapse: Sendable, Hashable {
        /// The surviving `.canvas` row's `Assignment.id`.
        public let canvasID: String
        /// The `.canvasModules` row's `Assignment.id` that is hidden.
        public let moduleID: String

        public init(canvasID: String, moduleID: String) {
            self.canvasID = canvasID
            self.moduleID = moduleID
        }
    }

    /// Hides every `.canvasModules` row that is the same assignment as a
    /// `.canvas` row in the same course, returning the canvas items unchanged,
    /// the module rows that survived (order preserved), and the pairs
    /// collapsed.
    ///
    /// This is intentionally its own function rather than a case fed into
    /// `matchPairs`/`merge` above, because it is solving a different problem.
    /// `matchPairs` reconciles two *different platforms'* independent
    /// postings of one assignment, where each side can carry information the
    /// other doesn't (a Gradescope score, a Canvas due-date correction) — so
    /// merging builds a new combined item. A `.canvas` row and a
    /// `.canvasModules` row, by contrast, are the SAME platform describing the
    /// SAME assignment through two different Canvas APIs (the ICS calendar
    /// feed and the Modules JSON listing); there is nothing on one side that
    /// isn't equally available on the other, so there is nothing to merge —
    /// one copy simply needs to stop being shown. And unlike a Gradescope
    /// item, a module row is `Assignment.Kind.event` (readings/modules content
    /// isn't itself gradework) and only exists at all when the course has
    /// opted in to Canvas content sync (`docs/READINGS_COURSES_PLAN.md`), so
    /// this collapse is a narrow, additive step that only ever fires for
    /// students who have that turned on — it changes nothing for anyone who
    /// hasn't.
    ///
    /// **Deliberately many-to-one, not 1:1 like `matchPairs`.** A Gradescope
    /// posting is a single distinct listing of an assignment, so it makes
    /// sense for `matchPairs` to claim it at most once — a second Canvas item
    /// claiming the same Gradescope row would be a genuine double-count. A
    /// Canvas assignment, though, routinely appears in more than one Module —
    /// the same "HW 3" listed under both "Week 3" and a standing "Labs"
    /// module — which produces multiple `.canvasModules` rows that all carry
    /// the identical `canvasAssignmentID` (or the identical title/due date).
    /// Those are not distinct assignments competing for one canvas row; they
    /// are the same assignment mentioned twice, and every one of them needs
    /// to disappear, not just the first. So the only per-row constraint here
    /// is on the MODULE side (`collapsedModuleIDs` — each module row
    /// collapses at most once, since it's exactly one dashboard entry to
    /// hide); a `.canvas` row may absorb any number of module rows, and there
    /// is deliberately no canvas-side claim set at all.
    public static func collapseCanvasDuplicates(
        canvasItems: [Assignment],
        moduleItems: [Assignment]
    ) -> (canvasItems: [Assignment], moduleItems: [Assignment], collapses: [CanvasCollapse]) {
        guard !canvasItems.isEmpty, !moduleItems.isEmpty else {
            return (canvasItems, moduleItems, [])
        }

        var canvasByCourse: [String: [Assignment]] = [:]
        for item in canvasItems { canvasByCourse[item.course, default: []].append(item) }

        var collapsedModuleIDs: Set<String> = []
        var collapsesByModuleID: [String: CanvasCollapse] = [:]

        // Pass 1: exact Canvas-assignment-id matches. This is the strongest
        // signal available and is resolved for every module row, over the
        // WHOLE input, before any fuzzy title matching runs — so a looser
        // title match in pass 2 can never steal a module row an id match
        // legitimately wants, regardless of which order the two arrays
        // happened to be handed in. Note there is no canvas-side claim check:
        // several module rows sharing one `canvasAssignmentID` (the same
        // assignment listed in two Modules) all collapse onto that one canvas
        // row here.
        var canvasByIDInCourse: [String: [String: Assignment]] = [:]
        for item in canvasItems {
            guard let id = item.canvasAssignmentID else { continue }
            canvasByIDInCourse[item.course, default: [:]][id] = item
        }
        for moduleItem in moduleItems {
            guard let moduleAssignmentID = moduleItem.canvasAssignmentID,
                  let canvasMatch = canvasByIDInCourse[moduleItem.course]?[moduleAssignmentID]
            else { continue }
            collapsedModuleIDs.insert(moduleItem.id)
            collapsesByModuleID[moduleItem.id] = CanvasCollapse(canvasID: canvasMatch.id, moduleID: moduleItem.id)
        }

        // Pass 2: the same title/due-date heuristic every other dedup path in
        // this type uses, for whatever pass 1 left unresolved. Candidates are
        // scored by due-date gap (closer wins) and ordered smallest-gap-first
        // with a stable id comparison to break exact ties, so the result
        // never depends on input ordering — but assignment here only enforces
        // the module side of the constraint: a module row takes the first
        // (best) candidate in that order and is done, while the canvas row it
        // picked stays open for any other module row still looking, for the
        // same many-to-one reason pass 1 has no canvas-side claim set.
        struct Candidate {
            let moduleItem: Assignment
            let canvasItem: Assignment
            let gap: TimeInterval
        }
        var candidates: [Candidate] = []
        for moduleItem in moduleItems where !collapsedModuleIDs.contains(moduleItem.id) {
            for canvasItem in canvasByCourse[moduleItem.course] ?? [] {
                guard isLikelyDuplicate(
                    titleA: moduleItem.title, dueA: moduleItem.dueAt,
                    titleB: canvasItem.title, dueB: canvasItem.dueAt
                ) else { continue }
                candidates.append(Candidate(
                    moduleItem: moduleItem,
                    canvasItem: canvasItem,
                    gap: dueDateGap(moduleItem.dueAt, canvasItem.dueAt)
                ))
            }
        }
        let ordered = candidates.sorted { a, b in
            if a.gap != b.gap { return a.gap < b.gap }
            if a.moduleItem.id != b.moduleItem.id { return a.moduleItem.id < b.moduleItem.id }
            return a.canvasItem.id < b.canvasItem.id
        }
        for candidate in ordered {
            guard !collapsedModuleIDs.contains(candidate.moduleItem.id) else { continue }
            collapsedModuleIDs.insert(candidate.moduleItem.id)
            collapsesByModuleID[candidate.moduleItem.id] = CanvasCollapse(
                canvasID: candidate.canvasItem.id,
                moduleID: candidate.moduleItem.id
            )
        }

        let survivors = moduleItems.filter { !collapsedModuleIDs.contains($0.id) }
        // Collapses reported in the order their module rows appeared in the
        // input, matching the survivor ordering guarantee above.
        let collapses = moduleItems.compactMap { collapsesByModuleID[$0.id] }
        return (canvasItems, survivors, collapses)
    }

    // MARK: - Title normalization

    /// Reduces a title to a token sequence for comparison: lowercase,
    /// punctuation stripped to spaces, common prefixes canonicalized (`hw` /
    /// `homework` / `ps` / `problem set(s)` → `hw`; `lab`/`labs` → `lab`;
    /// `project`/`projects`/`proj` → `project`), and letter/digit runs split
    /// so "HW3" and "HW 3" tokenize identically — with numeric tokens
    /// compared by value so "03" == "3". This intentionally mirrors
    /// `GradescopeOverlay.normalize`'s approach (kept as a separate,
    /// self-contained function here since the two call sites canonicalize
    /// slightly different prefix sets and have different false-positive
    /// tolerances — see the type doc comment).
    static func normalize(_ raw: String) -> [String] {
        var s = raw.lowercased()
        s = s.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        // Phrase-level collapses before word-splitting, so multi-word phrases
        // line up with their single-word abbreviations.
        s = s.replacingOccurrences(of: #"\bproblem\s+sets?\b"#, with: "hw", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard !s.isEmpty else { return [] }

        var tokens: [String] = []
        for word in s.split(separator: " ") {
            tokens.append(contentsOf: splitLetterDigitRuns(String(word)))
        }
        return tokens.map(canonicalize)
    }

    /// Splits a token like "hw3" into ["hw", "3"] at the letter/digit
    /// boundary, so "HW3" and "HW 3" normalize to the same token sequence —
    /// this is also where an assignment number gets isolated as its own
    /// token for the numeric-equality comparison in `canonicalize`.
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
        case "hw", "homework", "ps", "pset", "psets": return "hw"
        case "lab", "labs": return "lab"
        case "project", "projects", "proj": return "project"
        default: return token
        }
    }

    /// |A ∩ B| / |A ∪ B| over two normalized token sets.
    private static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
