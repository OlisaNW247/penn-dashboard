import Foundation

/// One observation of whether a piece of work has been handed in, from one
/// source, at one moment. Marco's rule for the Sweeper (2026-11-18): the alarm
/// is armed days ahead exactly as before, and only a *confirmed* "submitted"
/// read cancels it. A failed read, a partial page or an item the source did
/// not list is no read at all or an `.unknown` one, and an unknown read must
/// never arm or disarm anything. `cancels` is therefore true for `.submitted`
/// alone: `.unsubmitted` is information (the work is still open) but it is not
/// a reason to ring either, because the alarm was already set.
///
/// The wrong fix is inferring "unsubmitted" from an item missing from a page:
/// Canvas's planner window and paging mean absence proves nothing.
public struct SubmissionRead: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable { case planner, grades, gradescope }
    public enum Verdict: String, Sendable, Equatable { case submitted, unsubmitted, unknown }

    public let assignmentID: String
    public let readAt: Date
    public let source: Source
    public let verdict: Verdict

    public init(assignmentID: String, readAt: Date, source: Source, verdict: Verdict) {
        self.assignmentID = assignmentID
        self.readAt = readAt
        self.source = source
        self.verdict = verdict
    }

    /// Whether this read is grounds to cancel the item's reminders and alarm.
    public var cancels: Bool { verdict == .submitted }

    /// Reads from a page of Planner items. An item without an `assignmentID`
    /// (a note, a page, a discussion) produces no read. `submitted == true` or
    /// a Planner tick means submitted; an explicit `false` means unsubmitted;
    /// a missing flag is unknown (Canvas sends nothing for work with no
    /// submission, which says nothing about whether it was handed in).
    /// Excused work counts as submitted: it is never handed in, so Canvas
    /// sends `submitted` false or nothing for it, and without this the
    /// last-hour poll could never cancel its alarm. `graded` is deliberately
    /// not treated the same way, because a zero can be graded with no
    /// submission at all.
    public static func verdicts(fromPlanner items: [CanvasPlannerItem], readAt: Date) -> [SubmissionRead] {
        items.compactMap { item in
            guard let id = item.assignmentID else { return nil }
            let verdict: Verdict
            if item.submitted == true || item.markedComplete || item.excused == true {
                verdict = .submitted
            } else if item.submitted == false {
                verdict = .unsubmitted
            } else {
                verdict = .unknown
            }
            return SubmissionRead(assignmentID: id, readAt: readAt, source: .planner, verdict: verdict)
        }
    }
}
