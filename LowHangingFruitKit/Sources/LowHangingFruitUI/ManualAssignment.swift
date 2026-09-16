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
            sourceID: "\(Self.sourceIDPrefix)\(id.uuidString)",
            kind: .assignment,
            course: course,
            title: title,
            dueAt: dueAt,
            url: nil,
            submitted: false
        )
    }
}

extension ManualAssignment {
    /// The `sourceID` prefix `asAssignment()` writes. Round-tripping through it
    /// is what lets manual work live on the ledger and still be edited here.
    static let sourceIDPrefix = "manual-"

    /// Rebuilds the editable model from a ledger row's value type. Nil when the
    /// row isn't one this type produced — a `.manual` item from anywhere else
    /// isn't ours to hand to the edit sheet.
    init?(_ assignment: Assignment) {
        guard assignment.source == .manual,
              assignment.sourceID.hasPrefix(Self.sourceIDPrefix),
              let uuid = UUID(uuidString: String(
                  assignment.sourceID.dropFirst(Self.sourceIDPrefix.count)))
        else { return nil }
        self.id = uuid
        self.title = assignment.title
        self.course = assignment.course
        self.dueAt = assignment.dueAt
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
