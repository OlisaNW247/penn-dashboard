import Foundation
import LowHangingFruitKit

/// One per-course answer to the readings/silent-course nudge
/// (docs/READINGS_COURSES_PLAN.md). Persisted through `UserDefaults.lhf` —
/// never `.standard` (project rule) — keyed by `CourseProfileReport.courseKey`.
/// Default is exclude: the *absence* of an entry for a course, not a stored
/// `.exclude`, is what "never asked" and "asked and said no" both look like
/// on disk — `AppState.courseContentIncluded` treats them identically, which
/// is exactly the point (existing users see zero change until they answer).
struct CourseContentDecision: Codable, Equatable {
    enum Choice: String, Codable {
        case include
        case exclude
    }

    var choice: Choice
    /// `CourseProfileReport.fingerprint` at the time this decision was made,
    /// so a later profile change can be measured against it — same CLASS
    /// (the substring before ":") means "don't re-ask", a different class
    /// means the course's shape changed enough to ask again (see
    /// `AppState.queueNudgeIfNeeded`).
    var fingerprint: String
    var decidedAt: Date
}

/// JSON-blob persistence for the whole decision map, the same shape
/// `AppState.persistRecurringTasks`/`persistManualAssignments` already use
/// (one key, the whole collection re-encoded) rather than one UserDefaults
/// key per course — the map stays small and is always read/written as a
/// unit.
enum CourseContentDecisionStore {
    private static let key = "courseContentDecisionsV1"

    static func load() -> [String: CourseContentDecision] {
        guard let data = UserDefaults.lhf.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: CourseContentDecision].self, from: data)
        else { return [:] }
        return decoded
    }

    static func save(_ decisions: [String: CourseContentDecision]) {
        guard let data = try? JSONEncoder().encode(decisions) else { return }
        UserDefaults.lhf.set(data, forKey: key)
    }

    /// Wipes every stored decision — used by `AppState.disconnectCanvas()`,
    /// where a reconnect is meant to re-ask from scratch rather than inherit
    /// decisions tied to a session/fingerprint history the new one may never
    /// reproduce.
    static func clear() {
        UserDefaults.lhf.removeObject(forKey: key)
    }
}
