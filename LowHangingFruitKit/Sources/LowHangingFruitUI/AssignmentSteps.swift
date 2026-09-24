import Foundation
import LowHangingFruitKit

/// One step the student broke an assignment into ("outline", "draft",
/// "check the rubric"). Their own words, their own order.
struct AssignmentStep: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var isDone: Bool = false
}

/// **Prototype** (v8-features, 2026-09-24): per-assignment steps, keyed by
/// `Assignment.id`, so a big assignment can be broken into pieces without
/// adding anything to the already-full dashboard — the steps live inside the
/// expanded card, and the collapsed card shows only a thin progress bar once
/// steps exist.
///
/// Stored in `UserDefaults.lhf` for now, which is the wrong tier for the
/// real thing: steps are the student's own work, and CLAUDE.md's ledger rule
/// is that nothing the student did is ever lost. If this graduates it moves
/// onto `StoredAssignment` (with a default, so the CloudKit-eligible schema
/// holds). Kept to one JSON blob here so that move is a single migration.
@MainActor
final class AssignmentStepsStore: ObservableObject {
    static let shared = AssignmentStepsStore()
    static let key = "assignmentStepsV1"

    @Published private(set) var stepsByAssignment: [String: [AssignmentStep]]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .lhf) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: [AssignmentStep]].self, from: data) {
            stepsByAssignment = decoded
        } else {
            stepsByAssignment = [:]
        }
    }

    func steps(for assignmentID: String) -> [AssignmentStep] {
        stepsByAssignment[assignmentID] ?? []
    }

    func add(_ title: String, to assignmentID: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stepsByAssignment[assignmentID, default: []].append(AssignmentStep(title: trimmed))
        persist()
    }

    func toggle(_ stepID: UUID, in assignmentID: String) {
        guard let index = stepsByAssignment[assignmentID]?.firstIndex(where: { $0.id == stepID }) else { return }
        stepsByAssignment[assignmentID]?[index].isDone.toggle()
        persist()
    }

    func remove(_ stepID: UUID, from assignmentID: String) {
        stepsByAssignment[assignmentID]?.removeAll { $0.id == stepID }
        if stepsByAssignment[assignmentID]?.isEmpty == true {
            stepsByAssignment[assignmentID] = nil
        }
        persist()
    }

    nonisolated static func progress(_ steps: [AssignmentStep]) -> (done: Int, total: Int) {
        (steps.filter(\.isDone).count, steps.count)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(stepsByAssignment) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
