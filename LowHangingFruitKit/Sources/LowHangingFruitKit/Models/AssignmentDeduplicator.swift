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
    ///
    /// Public because the announcement dedup in `AppState` reuses it as the
    /// answer to "are these two dates the same day's task": one tolerance for
    /// the fuzzy title tier here, for announcement twins there, and for whether
    /// a completion may follow a twin, so the three cannot drift apart.
    public static let similarTitleDueDateTolerance: TimeInterval = 26 * 3600

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

    /// Announcement prose often wraps the real assignment title in an
    /// imperative ("Take Quiz 2", "Please submit Homework 3"). Comparing
    /// that prose with a structured Canvas title using the ordinary fuzzy
    /// tier would require two due dates, even though the directive itself is
    /// strong evidence and announcements frequently omit the timestamp.
    ///
    /// Only the announcement side loses a small, leading directive. This is
    /// intentionally not general title normalization: stripping words from
    /// both sides would make genuinely different structured assignments more
    /// likely to collapse. The same 21-day contradiction guard as an exact
    /// title match still applies whenever both dates are known.
    public static func isLikelyAnnouncementDuplicate(
        announcementTitle: String,
        announcementDue: Date?,
        existingTitle: String,
        existingDue: Date?
    ) -> Bool {
        let announcementTokens = announcementCoreTokens(announcementTitle)
        let existingTokens = normalize(existingTitle)
        guard !announcementTokens.isEmpty, !existingTokens.isEmpty else { return false }

        if announcementTokens == existingTokens {
            return announcementDatesDoNotContradict(announcementDue, existingDue)
        }

        // Assessment identity is stronger than surrounding prose. Canvas can
        // decorate the official title with a chapter, section, or course code
        // while the announcement simply says "Take Quiz 2". If both sides
        // name the same high-confidence assessment kind and primary ordinal,
        // that is one assessment even when either timestamp is absent.
        // Practice/retake/makeup variants remain distinct from the ordinary
        // sitting (and from each other) unless both titles carry the same
        // modifier set.
        if let announcementIdentity = assessmentIdentity(in: announcementTokens),
           let existingIdentity = assessmentIdentity(in: existingTokens),
           assessmentKindCount(in: announcementTokens) == 1,
           announcementIdentity == existingIdentity {
            return announcementDatesDoNotContradict(announcementDue, existingDue)
        }

        // Work identity is the same idea for the everyday assignment nouns
        // (homework, problem set, lab, project, milestone, assignment, essay,
        // paper). A Canvas announcement and an Ed post about one homework
        // read "Complete HW 2 - Relational Databases" and "Complete
        // Homework 2": same work, different words, and the Jaccard tier below
        // cannot join them (and would need two due dates if it could).
        // Both sides must carry exactly one noun-plus-ordinal. If the noun and
        // ordinal agree, the pair is the same work when the modifier sets
        // agree and refused when they do not ("HW 2" vs "HW 2 solutions
        // posted" must stay two things, and the prefix tier below would
        // otherwise have merged them). The same noun with a different ordinal
        // is refused outright. If the nouns differ, or either side has no
        // identity, this tier says nothing and the later tiers decide
        // exactly as before.
        if let announcementWork = workIdentity(in: announcementTokens),
           let existingWork = workIdentity(in: existingTokens),
           announcementWork.noun == existingWork.noun {
            // Same noun, different number is different work, full stop. Left
            // to the Jaccard tier, "HW 2 Relational Databases" and "HW 3
            // Relational Databases" share 3 of 5 tokens and merge whenever
            // their due dates are within 26 hours.
            guard announcementWork.ordinal == existingWork.ordinal else { return false }
            guard announcementWork.modifiers == existingWork.modifiers else { return false }
            return announcementDatesDoNotContradict(announcementDue, existingDue)
        }

        // The extractor can preserve the sentence tail even when its leading
        // imperative has been removed: "Take Quiz 2 on Canvas by Friday"
        // becomes [quiz, 2, on, canvas, by, friday]. A structured Canvas title
        // [quiz, 2] is still the same work. This prefix tier is deliberately
        // limited to NUMBERED structured titles; allowing an unnumbered title
        // such as "Quiz" or "Midterm" to absorb every announcement beginning
        // with that generic word would recreate the false-merge problem this
        // type is designed to avoid. A second assignment noun or number in the
        // tail also refuses the match ("Quiz 2 and Quiz 3").
        let trailingTokens = announcementTokens.dropFirst(existingTokens.count)
        let tailStartsWithStructuredTitle = announcementTokens.starts(with: existingTokens)
        let structuredTitleIsNumbered = existingTokens.contains { Int($0) != nil }
        let tailIntroducesAnotherWorkItem = trailingTokens.contains { token in
            Int(token) != nil || ["quiz", "exam", "midterm", "test", "hw", "lab", "project", "assignment"].contains(token)
        }
        if tailStartsWithStructuredTitle,
           structuredTitleIsNumbered,
           !trailingTokens.isEmpty,
           !tailIntroducesAnotherWorkItem {
            return announcementDatesDoNotContradict(announcementDue, existingDue)
        }

        return isLikelyDuplicate(
            titleA: announcementTitle,
            dueA: announcementDue,
            titleB: existingTitle,
            dueB: existingDue
        )
    }

    private static func announcementDatesDoNotContradict(_ announcementDue: Date?, _ existingDue: Date?) -> Bool {
        guard let announcementDue, let existingDue else { return true }
        return abs(announcementDue.timeIntervalSince(existingDue)) <= sameTitleMaxDueGap
    }

    private struct AssessmentIdentity: Equatable {
        let kind: String
        let ordinal: Int
        let modifiers: Set<String>
    }

    /// A directive that names two assessments (for example, "Take Quiz 2
    /// and Quiz 3") must not collapse onto either structured assignment.
    /// Keep the identity shortcut restricted to announcements with one clear
    /// assessment reference; the more conservative prefix rules below can
    /// then reject ambiguous tails as well.
    private static func assessmentKindCount(in tokens: [String]) -> Int {
        let kinds = Set([
            "quiz", "quizzes", "test", "tests", "assessment", "assessments",
            "exam", "exams", "midterm", "midterms", "prelim", "prelims",
            "final", "finals",
        ])
        return tokens.reduce(into: 0) { count, token in
            if kinds.contains(token) { count += 1 }
        }
    }

    private static func assessmentIdentity(in tokens: [String]) -> AssessmentIdentity? {
        let kinds: [String: String] = [
            "quiz": "quiz", "quizzes": "quiz",
            "test": "test", "tests": "test",
            "assessment": "assessment", "assessments": "assessment",
            "exam": "exam", "exams": "exam",
            "midterm": "midterm", "midterms": "midterm",
            "prelim": "prelim", "prelims": "prelim",
            "final": "final", "finals": "final",
        ]
        guard let kindIndex = tokens.firstIndex(where: { kinds[$0] != nil }),
              let ordinalToken = tokens[kindIndex...].first(where: { Int($0) != nil }),
              let ordinal = Int(ordinalToken),
              let kind = kinds[tokens[kindIndex]]
        else { return nil }
        let reservedModifiers = Set(["practice", "retake", "makeup"])
        return AssessmentIdentity(
            kind: kind,
            ordinal: ordinal,
            modifiers: Set(tokens).intersection(reservedModifiers)
        )
    }

    private struct WorkIdentity: Equatable {
        let noun: String
        let ordinal: Int
        let modifiers: Set<String>
    }

    /// Spellings (as they come out of `normalize`, which has already turned
    /// "problem set(s)", "pset(s)", "ps" and "homework" into `hw`, and
    /// "labs" / "projects" / "proj" into `lab` / `project`) mapped to one
    /// canonical noun. The extra spellings are listed anyway so this table
    /// does not silently depend on `canonicalize` staying as it is.
    private static let workNouns: [String: String] = [
        "hw": "hw", "hws": "hw", "hmwk": "hw", "homework": "hw", "homeworks": "hw",
        "ps": "hw", "pset": "hw", "psets": "hw",
        "lab": "lab", "labs": "lab",
        "project": "project", "projects": "project", "proj": "project", "projs": "project",
        "milestone": "milestone", "milestones": "milestone",
        "assignment": "assignment", "assignments": "assignment",
        "asst": "assignment", "assn": "assignment", "assign": "assignment",
        "essay": "essay", "essays": "essay",
        "paper": "paper", "papers": "paper",
    ]

    /// Words that make a variant of the work rather than the work itself.
    /// Deliberately a separate, wider table than the assessment tier's
    /// `practice/retake/makeup` (which it includes): solutions, grades and
    /// extensions are things professors post ABOUT a homework, and none of
    /// them is the homework. Sub-parts ("part 2", "part a") are handled
    /// separately in `workModifiers` because they carry a value.
    private static let workModifierWords: [String: String] = [
        "solution": "solution", "solutions": "solution",
        "grade": "grade", "grades": "grade", "graded": "grade",
        "regrade": "regrade", "regrades": "regrade",
        "extension": "extension", "extensions": "extension", "extended": "extension",
        "practice": "practice", "retake": "retake", "makeup": "makeup",
        "redo": "redo",
        "resubmission": "resubmission", "resubmissions": "resubmission",
        "resubmit": "resubmission", "resubmitted": "resubmission",
    ]

    /// Between a noun and its number: "Homework no. 2", "Assignment number 2".
    private static let ordinalFillers: Set<String> = ["no", "number", "num"]

    /// A canonical noun plus ordinal for the everyday assignment nouns, so
    /// "HW 2", "Homework 2", "hw2", "HW #2" and "Homework #02" are one
    /// identity (`normalize` has already stripped `#`/`:`/`-` and turned "02"
    /// into "2").
    ///
    /// The ordinal is the integer directly after the noun (skipping "no" /
    /// "number"), NOT the first integer anywhere after it: that would read
    /// "Homework on chapter 3" as homework 3. Returns nil unless the title
    /// carries exactly one noun-with-ordinal ("HW 2 and HW 3 solutions" is
    /// two), and nil if it names an assessment kind (those belong to
    /// `assessmentIdentity`; "Lab 4 quiz" is too ambiguous to decide here).
    /// A bare "Homework" gives no identity.
    private static func workIdentity(in tokens: [String]) -> WorkIdentity? {
        guard assessmentKindCount(in: tokens) == 0 else { return nil }
        var found: (noun: String, ordinal: Int)?
        for (index, token) in tokens.enumerated() {
            guard let noun = workNouns[token] else { continue }
            var next = index + 1
            while next < tokens.count, ordinalFillers.contains(tokens[next]) { next += 1 }
            guard next < tokens.count, let ordinal = Int(tokens[next]) else { continue }
            if found != nil { return nil }
            found = (noun, ordinal)
        }
        guard let found else { return nil }
        return WorkIdentity(noun: found.noun, ordinal: found.ordinal, modifiers: workModifiers(in: tokens))
    }

    private static func workModifiers(in tokens: [String]) -> Set<String> {
        var modifiers: Set<String> = []
        for (index, token) in tokens.enumerated() {
            if let canonical = workModifierWords[token] {
                modifiers.insert(canonical)
            } else if token == "make", index + 1 < tokens.count, tokens[index + 1] == "up" {
                modifiers.insert("makeup")
            } else if token == "part" || token == "parts" || token == "pt" {
                // "Part 2" and "Part A" are different sub-parts; a bare
                // "part" still marks the title as a part of something.
                let value = index + 1 < tokens.count ? tokens[index + 1] : ""
                modifiers.insert("part:\(value)")
            }
        }
        return modifiers
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

    // MARK: - Canvas ICS section-override collapse

    /// One `.canvas` row hidden because another `.canvas` row already covers
    /// the same underlying Canvas assignment id.
    public struct OverrideCollapse: Sendable, Hashable {
        /// The `Assignment.id` kept — the row shown on the dashboard.
        public let survivorID: String
        /// The `Assignment.id` hidden — a duplicate section-override listing
        /// of the same assignment.
        public let hiddenID: String

        public init(survivorID: String, hiddenID: String) {
            self.survivorID = survivorID
            self.hiddenID = hiddenID
        }
    }

    /// Collapses `.canvas` rows that are the same Canvas assignment (same
    /// `course`, same non-nil `canvasAssignmentID`) into one. `preferredDueDates`
    /// is keyed by Canvas assignment id and carries the student's own effective
    /// due date from Grade Watcher (the assignments API, which resolves
    /// section overrides for the logged-in student server-side) when known.
    ///
    /// This is a THIRD collapse, distinct from both `matchPairs`/`merge` above
    /// and `collapseCanvasDuplicates`. `matchPairs` reconciles two different
    /// platforms' independent postings of one assignment; `collapseCanvasDuplicates`
    /// reconciles two different Canvas APIs (ICS feed vs. Modules JSON)
    /// describing one assignment. This one is neither: it is the SAME
    /// platform, the SAME Canvas API (the ICS calendar feed), describing the
    /// SAME assignment more than once, because Canvas's `to_ics` emits one
    /// VEVENT per *section due-date override* that applies to the student
    /// rather than one VEVENT per assignment (see `Assignment.canvasAssignmentID`
    /// for the full mechanism). A lab with three section overrides shows up as
    /// three separate calendar rows sharing one `#assignment_<id>` fragment,
    /// each with a different `dueAt` (whichever section's date Canvas chose to
    /// stamp on that particular VEVENT) — and only the grades API, which
    /// resolves the override the STUDENT is actually bound by, knows which one
    /// is real. So unlike the other two collapses, which have nothing left to
    /// decide once a match is found, this one has to pick a survivor.
    ///
    /// Survivor selection, per assignment id group of 2+ rows:
    /// - If `preferredDueDates[id]` is known (Grade Watcher has fetched this
    ///   course), keep whichever row's `dueAt` is nearest it — a nil `dueAt`
    ///   counts as infinitely far, so it never wins over a dated row once a
    ///   preferred date exists.
    /// - Otherwise keep the row with the EARLIEST `dueAt` (nil last, so an
    ///   undated row is the last resort). Earliest, deliberately, because a
    ///   wrongly-early deadline is visible and merely annoying — the student
    ///   sees it, checks Canvas, and moves on — while a wrongly-late deadline
    ///   HIDES a missed one behind a due date that hasn't arrived yet, and
    ///   silently hiding owed work is the one failure mode this app must never
    ///   have.
    /// - Ties (equal gap, or equal due date) break on `id` ascending, so the
    ///   result never depends on input ordering.
    ///
    /// Only `.canvas` rows with a resolvable `canvasAssignmentID` participate;
    /// everything else (Gradescope, Canvas Modules, quizzes/discussions/events,
    /// an unresolvable Canvas row) passes through untouched, in input order.
    /// Survivors keep their original input position.
    public static func collapseCanvasOverrides(
        canvasItems: [Assignment],
        preferredDueDates: [String: Date]
    ) -> (canvasItems: [Assignment], collapses: [OverrideCollapse]) {
        guard !canvasItems.isEmpty else { return (canvasItems, []) }

        struct GroupKey: Hashable {
            let course: String
            let assignmentID: String
        }

        var groups: [GroupKey: [Assignment]] = [:]
        var groupOrder: [GroupKey] = []
        for item in canvasItems {
            guard item.source == .canvas, let id = item.canvasAssignmentID else { continue }
            let key = GroupKey(course: item.course, assignmentID: id)
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(item)
        }

        var hiddenIDs: Set<String> = []
        var collapsesByHiddenID: [String: OverrideCollapse] = [:]
        for key in groupOrder {
            guard let rows = groups[key], rows.count >= 2 else { continue }
            let preferred = preferredDueDates[key.assignmentID]
            guard let survivor = rows.min(by: { a, b in
                if let preferred {
                    let gapA = a.dueAt.map { abs($0.timeIntervalSince(preferred)) } ?? .greatestFiniteMagnitude
                    let gapB = b.dueAt.map { abs($0.timeIntervalSince(preferred)) } ?? .greatestFiniteMagnitude
                    if gapA != gapB { return gapA < gapB }
                } else {
                    let dateA = a.dueAt ?? .distantFuture
                    let dateB = b.dueAt ?? .distantFuture
                    if dateA != dateB { return dateA < dateB }
                }
                return a.id < b.id
            }) else { continue }

            for row in rows where row.id != survivor.id {
                hiddenIDs.insert(row.id)
                collapsesByHiddenID[row.id] = OverrideCollapse(survivorID: survivor.id, hiddenID: row.id)
            }
        }

        let survivors = canvasItems.filter { !hiddenIDs.contains($0.id) }
        // Collapses reported in the order their hidden rows appeared in the
        // input, matching every other collapse function's convention here.
        let collapses = canvasItems.compactMap { collapsesByHiddenID[$0.id] }
        return (survivors, collapses)
    }

    // MARK: - Title normalization

    // Compiled once. `normalize` runs on both titles of every same-course
    // pair in the duplicate checks, and each of these used to be re-compiled
    // by `replacingOccurrences(of:with:options: .regularExpression)` on every
    // call, four times a title. Literals known to be valid, so `try!` can only
    // trap on a typo the first test run catches. The replacements contain no
    // `$` or `\`, so template and literal replacement are the same thing.
    private static let nonWordRegex = try! NSRegularExpression(pattern: #"[^a-z0-9\s]"#)
    private static let problemSetRegex = try! NSRegularExpression(pattern: #"\bproblem\s+sets?\b"#)
    private static let midTermRegex = try! NSRegularExpression(pattern: #"\bmid\s+terms?\b"#)
    private static let whitespaceRunRegex = try! NSRegularExpression(pattern: #"\s+"#)

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: text.utf16.count),
            withTemplate: template
        )
    }

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
        s = replacing(nonWordRegex, in: s, with: " ")
        // Phrase-level collapses before word-splitting, so multi-word phrases
        // line up with their single-word abbreviations.
        s = replacing(problemSetRegex, in: s, with: "hw")
        s = replacing(midTermRegex, in: s, with: "midterm")
        s = replacing(whitespaceRunRegex, in: s, with: " ")
            .trimmingCharacters(in: .whitespaces)

        guard !s.isEmpty else { return [] }

        var tokens: [String] = []
        for word in s.split(separator: " ") {
            tokens.append(contentsOf: splitLetterDigitRuns(String(word)))
        }
        return tokens.map(canonicalize)
    }

    private static func announcementCoreTokens(_ raw: String) -> [String] {
        var tokens = normalize(raw)
        let leadIn = Set(["please", "remember", "reminder", "you", "must", "should", "need", "needs", "to"])
        while let first = tokens.first, leadIn.contains(first) {
            tokens.removeFirst()
        }

        if tokens.starts(with: ["turn", "in"]) || tokens.starts(with: ["hand", "in"]) {
            tokens.removeFirst(2)
        } else if let first = tokens.first,
                  ["take", "complete", "submit", "upload", "do"].contains(first) {
            tokens.removeFirst()
        }

        while let first = tokens.first, ["the", "your", "a", "an"].contains(first) {
            tokens.removeFirst()
        }
        return tokens
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
        case "midterm", "midterms": return "midterm"
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
