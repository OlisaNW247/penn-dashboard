import Foundation
import SwiftUI
import LowHangingFruitKit

/// A user-created one-off assignment. Stored separately from scraped data so a
/// Canvas sync never overwrites or removes it.
struct ManualAssignment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var course: String
    var dueAt: Date?

    func asAssignment() -> Assignment {
        Assignment(
            source: .manual,
            sourceID: "manual-\(id.uuidString)",
            kind: .assignment,
            course: course,
            title: title,
            dueAt: dueAt,
            url: nil,
            submitted: false
        )
    }
}

extension Assignment {
    /// Course code for display. Items without a course (e.g. a quick manual add)
    /// fall back to "Misc" so the course slot is never blank.
    var displayCourse: String {
        let trimmed = course.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Misc" : trimmed
    }
}

/// User renames from Settings → Classes, keyed by course code. Passed through
/// the environment rather than read from `AppState` so cards stay usable in
/// previews and in Preview mode, where there are no overrides — an empty map
/// reproduces the old behaviour exactly.
private struct CourseNameOverridesKey: EnvironmentKey {
    static let defaultValue: [String: String] = [:]
}

extension EnvironmentValues {
    var courseNameOverrides: [String: String] {
        get { self[CourseNameOverridesKey.self] }
        set { self[CourseNameOverridesKey.self] = newValue }
    }
}

extension Assignment {
    /// `displayCourse` with the user's rename applied. Renames are keyed on the
    /// raw `course` code, so an item still resolves after Canvas re-sends it.
    func displayCourse(overrides: [String: String]) -> String {
        guard let custom = overrides[course]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !custom.isEmpty
        else { return displayCourse }
        return custom
    }
}
