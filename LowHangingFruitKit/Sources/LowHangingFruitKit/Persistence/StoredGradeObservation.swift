import Foundation
import SwiftData

/// One observed course grade, on one calendar day.
///
/// Grade history is the only *real* record the app keeps of what a grade
/// actually was at a point in time. Everything else on the grades screen is
/// reconstructed: `GradeEngine.trajectory` replays today's items against their
/// due dates, which answers "how did this term build up" but cannot answer
/// "what changed since I last looked" — a regrade, a late posting, or a
/// dropped-lowest kicking in all move the current number without moving any due
/// date. That question is what the week-delta chip asks, and these rows are the
/// only thing that can answer it.
///
/// Per *course*, not per assignment — the observation is of the course grade as
/// a whole — so it gets its own model rather than a field on `StoredAssignment`.
/// Keyed by the Canvas numeric course id, the same key `GradeWatcherStore` uses
/// throughout.
///
/// Every property is defaulted rather than merely non-optional, which is what
/// CloudKit requires of a syncable model: grade history is near the top of the
/// list of things worth carrying to a new phone.
@Model
public final class StoredGradeObservation {
    /// Canvas numeric course id.
    public var courseID: String = ""
    /// When the observation was taken — the refresh's `now`, not midnight, so
    /// the 24h-old baseline rule in `weekDelta` keeps working against real
    /// times. At most one row per course per calendar day survives; a second
    /// refresh the same day overwrites this in place.
    public var observedAt: Date = Date.distantPast
    /// The course grade at that moment, as a percentage (e.g. `91.4`).
    public var percent: Double = 0

    public init(courseID: String, observedAt: Date, percent: Double) {
        self.courseID = courseID
        self.observedAt = observedAt
        self.percent = percent
    }
}
