import Foundation

/// Recovers a Canvas assignment id for a ledger row that `Assignment
/// .canvasAssignmentID` cannot derive on its own — today, a `.canvasModules`
/// row whose module item carried no `/assignments/<id>` URL (a module can
/// list an assignment by a bare content id Canvas never resolved into a
/// clickable link). Without a URL there is nothing structural to key off, but
/// Canvas's own grade snapshot (`GradeCategory.items: [GradeItem]`) names
/// every assignment in the course, so a title (corroborated by due date, the
/// same signal `AssignmentDeduplicator` already trusts for its own
/// same-platform-looking matches) can stand in for the missing id.
///
/// This is deliberately narrower than `AssignmentDeduplicator`: that type
/// merges two *different platforms'* postings of one assignment into a single
/// dashboard card. This one never merges anything — it only fills in an id a
/// single Canvas row is missing, so Grade Watcher's submission side-channel
/// has something to join on. The two are related only in that both reuse
/// `isLikelyDuplicate`/`normalize` as the "are these plausibly the same
/// assignment" test.
///
/// The failure mode a wrong match produces here is worse than the one it
/// fixes: an unmatched row simply keeps reading as "not submitted" (safe —
/// the student sees it as outstanding work, same as before this existed), but
/// a *wrong* match reads as submitted for someone else's assignment and hides
/// real, unsubmitted work behind a false checkmark. Every rule below is
/// written to fail closed — return nil — the moment there is more than one
/// plausible candidate, rather than guess.
public enum SubmissionMatcher {
    /// Resolves every row in `rows` that needs a fallback id (see
    /// `matchCanvasAssignmentID`) against the grade items Canvas reported for
    /// that row's course, and returns only the ones that matched
    /// unambiguously. Rows whose own `canvasAssignmentID` already resolves are
    /// never included here — this map exists purely to cover the gap, so a
    /// caller can do `row.canvasAssignmentID ?? fallbackCanvasAssignmentIDs[row.id]`
    /// without this map ever contradicting the row's own answer.
    public static func fallbackCanvasAssignmentIDs(
        rows: [Assignment],
        gradeItemsByCourse: [String: [GradeItem]]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            guard row.canvasAssignmentID == nil else { continue }
            guard let items = gradeItemsByCourse[row.course], !items.isEmpty else { continue }
            guard let matched = matchCanvasAssignmentID(for: row, gradeItems: items) else { continue }
            result[row.id] = matched
        }
        return result
    }

    /// The single-row form `fallbackCanvasAssignmentIDs` batches. Returns nil
    /// whenever the match would be a guess rather than a certainty:
    /// - the row isn't a Canvas-family source (`.canvas`/`.canvasModules`),
    /// - the row already has its own `canvasAssignmentID` (nothing to fall
    ///   back for — the batch map is additive, never a second opinion),
    /// - the row has an empty title (nothing to match on),
    /// - or the title/due-date test resolves to zero or more-than-one grade
    ///   item and the tie can't be broken by an exact normalized-title match.
    public static func matchCanvasAssignmentID(for row: Assignment, gradeItems: [GradeItem]) -> String? {
        guard row.source == .canvas || row.source == .canvasModules else { return nil }
        guard row.canvasAssignmentID == nil else { return nil }
        guard !row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let candidates = gradeItems.filter {
            AssignmentDeduplicator.isLikelyDuplicate(
                titleA: row.title, dueA: row.dueAt,
                titleB: $0.name, dueB: $0.dueAt
            )
        }
        if candidates.count == 1 { return candidates[0].id }
        guard candidates.count > 1 else { return nil }

        // More than one plausible candidate: only an exact normalized-title
        // match is allowed to break the tie. Anything looser than that is
        // exactly the ambiguity this type exists to refuse — two items with
        // merely SIMILAR titles due the same week are not evidence enough to
        // pick one over the other.
        let rowTokens = AssignmentDeduplicator.normalize(row.title)
        let exact = candidates.filter { AssignmentDeduplicator.normalize($0.name) == rowTokens }
        guard exact.count == 1 else { return nil }
        return exact[0].id
    }
}
