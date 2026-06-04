import Foundation
import LowHangingFruitKit

/// A user-created one-off assignment. Stored separately from scraped data so a
/// Canvas/Gradescope sync never overwrites or removes it.
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
