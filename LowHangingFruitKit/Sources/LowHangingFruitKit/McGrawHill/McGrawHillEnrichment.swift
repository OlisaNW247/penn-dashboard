import Foundation

/// One assignment as the McGraw Hill reader saw it in the student's own
/// Connect (or ALEKS) account. Built by the reader's client from the shapes
/// `docs/mcgraw-hill/RECON.md` records; until that file exists no code builds
/// one outside tests.
///
/// It lives in memory only. Nothing here is written to the ledger, to
/// defaults, to the backend or to the ask context document: the reader's
/// whole output is the `McGrawHillEnrichment` values below, applied to Canvas
/// rows on this phone.
public struct McGrawHillItem: Sendable, Equatable {
    /// The reader's own stable key for the item (an opaque McGraw Hill id).
    /// Never shown, never logged, never sent anywhere.
    public let key: String
    public let product: McGrawHillTool.Product
    /// The Canvas course code the reader found this item under (the reader
    /// launches McGraw Hill from one Canvas course at a time, so it knows
    /// this exactly), e.g. "ECON 0100".
    public let course: String
    public let title: String
    /// The due date McGraw Hill shows *this student*: an extension or an
    /// ALEKS exception moves it, which Canvas never sees.
    public let dueAt: Date?
    public let isDone: Bool
    /// The Canvas assignment this item is deployed as, when McGraw Hill's
    /// answer says so (an LTI resource link back to Canvas). Recon decides
    /// whether such a field exists; nil means "match by course, title and
    /// date".
    public let canvasAssignmentID: String?

    public init(
        key: String,
        product: McGrawHillTool.Product,
        course: String,
        title: String,
        dueAt: Date?,
        isDone: Bool,
        canvasAssignmentID: String? = nil
    ) {
        self.key = key
        self.product = product
        self.course = course
        self.title = title
        self.dueAt = dueAt
        self.isDone = isDone
        self.canvasAssignmentID = canvasAssignmentID
    }
}

/// What McGraw Hill adds to one Canvas row that Canvas also lists. The Canvas
/// row stays the card (its title, its link, its place in the ledger); this is
/// only what Canvas cannot know.
public struct McGrawHillEnrichment: Sendable, Equatable {
    /// The Canvas assignment id of the row this enriches.
    public let canvasAssignmentID: String
    /// McGraw Hill says the student finished it. Canvas often records no
    /// `submitted_at` for LTI work, which is the overdue trap this fixes.
    public let isDone: Bool
    /// The student's own due date, only when it differs from Canvas's (an
    /// extension, an ALEKS exception). Nil when they agree or McGraw Hill has
    /// none, so the card keeps Canvas's date.
    public let studentDueAt: Date?
    /// "in connect" / "in aleks".
    public let label: String

    public init(canvasAssignmentID: String, isDone: Bool, studentDueAt: Date?, label: String) {
        self.canvasAssignmentID = canvasAssignmentID
        self.isDone = isDone
        self.studentDueAt = studentDueAt
        self.label = label
    }
}

/// The separate pass that joins McGraw Hill items onto Canvas rows.
///
/// **Why a separate pass, and not a third side in `AssignmentDeduplicator`.**
/// That type's `Match` is two-sided by construction (`canvasID`,
/// `gradescopeID`) and a merged row carries one `linkedID`; widening it would
/// move every Canvas↔Gradescope pairing, the Chrome extension's port of it,
/// device sync's `linkedID` lookups and the persisted confirmed pairings, for
/// a source that never needs a row of its own when Canvas lists the item. The
/// announcement and exam dedup took the same road (`resolvingAnnouncement
/// Duplicates`) for the same reason.
///
/// **Why it adds no row.** `CLAUDE.md`'s rule: no new `Assignment.Source`
/// (an older build maps an unknown source to `.canvas` with an id that no
/// longer matches) and no new ledger column (a schema change drops an older
/// build to an empty in-memory ledger). A Connect item Canvas lists is the
/// same assignment; it should be one card. Items Canvas does not list come
/// back in `unmatched`; their home (`mh-` rows) waits for recon to show they
/// exist (owners' answer, 2026-11-02).
///
/// **Who may be matched.** Only Canvas rows already recognised as McGraw Hill
/// launches (`mcgrawHillCanvasAssignmentIDs`, from the launch host), so a
/// Connect item titled "Homework 3" can never mark the class's unrelated
/// Canvas "Homework 3" done. Then, in order:
/// 1. McGraw Hill's own link to the Canvas assignment id, when it gives one.
/// 2. Same course, and `AssignmentDeduplicator.isLikelyDuplicate` on title and
///    date (the dashboard's own rule, not a third copy of it).
/// Each Canvas row takes at most one item and each item at most one row,
/// items taken in a fixed order (key), so the result is a function of the
/// inputs.
public enum McGrawHillEnricher {
    public struct Result: Sendable, Equatable {
        /// Keyed by Canvas assignment id.
        public let enrichments: [String: McGrawHillEnrichment]
        /// Items no recognised Canvas row matched.
        public let unmatched: [McGrawHillItem]
    }

    /// Two due dates closer than this are the same date (a seconds-level
    /// difference in how two systems store "11:59 pm").
    public static let sameDueTolerance: TimeInterval = 60

    public static func enrich(
        canvas: [Assignment],
        items: [McGrawHillItem],
        mcgrawHillCanvasAssignmentIDs: Set<String>
    ) -> Result {
        // Recognised Canvas rows, one per Canvas assignment id (an ICS row
        // and a module row can carry the same id; the first by id wins).
        var candidates: [String: Assignment] = [:]
        for row in canvas.sorted(by: { $0.id < $1.id }) {
            guard let canvasID = row.canvasAssignmentID,
                  mcgrawHillCanvasAssignmentIDs.contains(canvasID),
                  candidates[canvasID] == nil else { continue }
            candidates[canvasID] = row
        }

        var taken: Set<String> = []
        var enrichments: [String: McGrawHillEnrichment] = [:]
        var unmatched: [McGrawHillItem] = []

        for item in items.sorted(by: { $0.key < $1.key }) {
            guard let canvasID = match(item, candidates: candidates, taken: taken),
                  let row = candidates[canvasID] else {
                unmatched.append(item)
                continue
            }
            taken.insert(canvasID)
            enrichments[canvasID] = McGrawHillEnrichment(
                canvasAssignmentID: canvasID,
                isDone: item.isDone,
                studentDueAt: differingDue(mcgrawHill: item.dueAt, canvas: row.dueAt),
                label: item.product.label
            )
        }
        return Result(enrichments: enrichments, unmatched: unmatched)
    }

    private static func match(
        _ item: McGrawHillItem,
        candidates: [String: Assignment],
        taken: Set<String>
    ) -> String? {
        if let linked = item.canvasAssignmentID,
           candidates[linked] != nil, !taken.contains(linked) {
            return linked
        }
        let course = foldedCourse(item.course)
        return candidates.keys.sorted().first { canvasID in
            guard !taken.contains(canvasID), let row = candidates[canvasID] else { return false }
            return foldedCourse(row.course) == course
                && AssignmentDeduplicator.isLikelyDuplicate(
                    titleA: row.title, dueA: row.dueAt,
                    titleB: item.title, dueB: item.dueAt
                )
        }
    }

    /// The student's own date when it is not Canvas's.
    static func differingDue(mcgrawHill: Date?, canvas: Date?) -> Date? {
        guard let mcgrawHill else { return nil }
        guard let canvas else { return mcgrawHill }
        return abs(mcgrawHill.timeIntervalSince(canvas)) > sameDueTolerance ? mcgrawHill : nil
    }

    /// "ECON 0100", "econ 0100" and "ECON0100" are one course here; the
    /// reader takes the code from the Canvas course it launched from, so only
    /// case and spacing can differ.
    private static func foldedCourse(_ raw: String) -> String {
        raw.lowercased().filter { !$0.isWhitespace }
    }
}

/// The home of a McGraw Hill item Canvas does not list, agreed with Olisa on
/// 2026-11-02: a `.canvasAnnouncement` ledger row whose `sourceID` starts
/// `mh-`, in the shape of Ed's `ed-` and the syllabus's `syllabus-` rows (no
/// new `Assignment.Source`, no new column; `CLAUDE.md` → "Tasks found in
/// announcements" says why). An older build reads such a row as a Canvas
/// announcement task.
///
/// **Nothing writes these rows yet.** The owners' answer was "once recon
/// shows such items exist" (`docs/mcgraw-hill/RECON.md`). The prefix and the
/// predicate exist now so the boundaries that must never see McGraw Hill data
/// (the ask context document, `AppState.assistantContextDocument`) refuse it
/// before the first row can be written, not after.
public enum McGrawHillRow {
    public static let sourceIDPrefix = "mh-"

    public static func isRow(_ assignment: Assignment) -> Bool {
        assignment.source == .canvasAnnouncement && assignment.sourceID.hasPrefix(sourceIDPrefix)
    }
}
