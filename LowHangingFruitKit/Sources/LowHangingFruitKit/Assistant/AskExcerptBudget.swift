import Foundation

/// How the eight excerpt slots are shared out per kind of question
/// (`docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`, Part 3 step 3), and the
/// computed "due in the asked range" list for a deadline question. Pure: no
/// store, no clock.
///
/// **Why budgets and not a global boost.** A recency boost in the search would
/// put a week-old post above the syllabus for "what is the late policy". Each
/// intent therefore gets its own rule, and `specific` keeps the plain search's
/// excerpts byte for byte.
public enum AskExcerptBudget {
    /// A news question's newest-first picks stop here so two BM25 hits survive
    /// next to them (the research's "cap at 6").
    public static let newsPickLimit = 6

    /// Slots a policy question holds back for the syllabus, pages and files.
    public static let policyReservedSlots = 4

    /// The most work lines the computed list prints.
    public static let dueListLimit = 20

    static func isStandingMaterial(_ kind: CourseDocument.Kind) -> Bool {
        kind == .syllabus || kind == .page || kind == .file
    }

    /// The hits a policy question sends, in their original (score) order.
    ///
    /// A dated post (Ed or announcement) is a candidate only when its text
    /// contains a policy word (`CourseSearch.policyWords`, whole tokens): a
    /// week-old "quiz Monday" post says nothing about the late policy and was
    /// taking a slot from the syllabus. Of what is left, up to
    /// `policyReservedSlots` standing-material hits (syllabus, page, file) are
    /// kept first, when the search has them, and the best of the rest fill the
    /// limit. `candidates` should be a search deeper than `limit`, so the
    /// reservation has something to choose from.
    public static func policySelection(_ candidates: [SearchHit], limit: Int) -> [SearchHit] {
        let eligible = candidates.filter { hit -> Bool in
            switch hit.document.kind {
            case .ed, .announcement:
                return CourseSearch.mentionsPolicyWord(hit.document.text.lowercased())
            default:
                return true
            }
        }
        let reserved = eligible.filter { isStandingMaterial($0.document.kind) }.prefix(min(policyReservedSlots, limit))
        let reservedIDs = Set(reserved.map(\.id))
        let rest = eligible.filter { !reservedIDs.contains($0.id) }.prefix(max(limit - reserved.count, 0))
        let keep = reservedIDs.union(rest.map(\.id))
        return eligible.filter { keep.contains($0.id) }
    }

    /// The work-list items due inside `range`, as lines for the per-question
    /// block (never the cached document): a header, then one line per item,
    /// sorted by due time then title, at most `dueListLimit`. Statuses follow
    /// the context document's own order (done, cancelled, outstanding).
    public static func dueList(work: [WorkItem], range: AskDayRange, timeZone: TimeZone) -> [String] {
        let span = "\(range.firstDay) to \(range.lastDay)"
        var inRange: [(item: WorkItem, due: Date)] = []
        for item in work {
            guard let due = item.dueAt, due >= range.start, due < range.end else { continue }
            inRange.append((item, due))
        }
        inRange.sort { lhs, rhs in
            if lhs.due != rhs.due { return lhs.due < rhs.due }
            if lhs.item.title != rhs.item.title { return lhs.item.title < rhs.item.title }
            return lhs.item.id < rhs.item.id
        }
        guard !inRange.isEmpty else {
            return ["Nothing on the work list is due in the asked range (\(span))."]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        var lines = ["Due in the asked range (\(span)):"]
        for entry in inRange.prefix(dueListLimit) {
            let item = entry.item
            let status = item.isCompleted ? "done" : (item.isCancelled ? "cancelled" : "outstanding")
            let course = item.course.isEmpty ? "(no course)" : item.course
            lines.append("\(course) · \(item.title) · due \(formatter.string(from: entry.due)) · \(status)")
        }
        if inRange.count > dueListLimit { lines.append("(\(inRange.count - dueListLimit) more not shown)") }
        return lines
    }
}
