import Foundation
import LowHangingFruitKit

/// One per-course answer to whether a class's opted-in content — calendar
/// `.event` items, Modules-imported readings — shows on the dashboard.
/// Persisted through `UserDefaults.lhf` — never `.standard` (project rule) —
/// keyed by `CourseProfileReport.courseKey`. Default is INCLUDE: the
/// *absence* of an entry for a course means its content already shows and
/// its readings already auto-import — `AppState.courseContentIncluded` and
/// `AppState.shouldAutoImportReadings` both treat "no entry" as "included".
/// This decision now only ever gets written one way: the student flipping
/// Settings' "Courses & content" toggle (`AppState.setCourseContentIncluded`).
/// It used to also get written by answering a one-ask consent popup the
/// first time a silent course's Modules readings were found; that popup was
/// removed 2026-08-27 (docs/decisions.md) because the data is the student's
/// own and the ask was pure friction, not meaningful consent.
struct CourseContentDecision: Codable, Equatable {
    enum Choice: String, Codable {
        case include
        case exclude
    }

    var choice: Choice
    /// `CourseProfileReport.fingerprint` at the time this decision was made.
    /// Originally used to decide whether a course's shape had changed enough
    /// to re-ask (same CLASS — the substring before ":" — meant "don't
    /// re-ask"); that re-asking logic went away with the popup it served
    /// (2026-08-27, docs/decisions.md). Kept on the model as a historical
    /// record of what the decision was measured against, and because
    /// dropping the field would be a lossy migration of on-disk data for no
    /// present benefit.
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
    /// where a reconnect is meant to re-probe and re-import from scratch
    /// rather than inherit decisions tied to a session/fingerprint history
    /// the new one may never reproduce.
    static func clear() {
        UserDefaults.lhf.removeObject(forKey: key)
    }
}
