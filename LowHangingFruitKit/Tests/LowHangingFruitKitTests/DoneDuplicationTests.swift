import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// An assignment a professor posts on both Canvas and Gradescope shows as ONE
/// card on the dashboard (`AssignmentDeduplicator`). Completing it marks both
/// underlying ids done — so the Done tab has to read the merged pool too, or the
/// single tap comes back as two cards.
@MainActor
@Suite("Done tab deduplication")
struct DoneDuplicationTests {
    /// A course code unlikely to collide with the other suites that toggle
    /// class-picker state on the shared `UserDefaults.standard`.
    private static let course = "DONEDUP 9999"

    private func assignment(_ source: Assignment.Source, _ id: String,
                            _ title: String, due: Date) -> Assignment {
        Assignment(source: source, sourceID: id, kind: .assignment,
                   course: Self.course, title: title, dueAt: due, url: nil)
    }

    @Test("completing a cross-posted assignment leaves exactly one card in Done")
    func mergedCompletionAppearsOnceInDone() {
        let state = AppState()
        let due = Date()
        let canvasItem = assignment(.canvas, "donedup-c1", "Homework 4", due: due)
        let gradescopeItem = assignment(.gradescope, "donedup-g1", "HW4", due: due)

        state.canvasItems = [canvasItem]
        state.gradescopeItems = [gradescopeItem]
        // Completion ids persist in UserDefaults between runs — start clean, and
        // hand back a clean slate on the way out.
        state.markActive(canvasItem)
        state.markActive(gradescopeItem)
        defer {
            state.markActive(canvasItem)
            state.markActive(gradescopeItem)
        }

        let vm = DashboardViewModel()
        vm.bind(to: state)

        // The pair collapses to a single active card.
        let active = vm.items.filter { !$0.isCompleted && $0.assignment.course == Self.course }
        #expect(active.count == 1)
        guard let card = active.first else { return }

        vm.complete(card)
        vm.reload()

        // The regression: reading the raw Canvas + Gradescope feeds here put
        // both underlying items in Done, so one tap produced two cards.
        let done = vm.items.filter { $0.isCompleted && $0.assignment.course == Self.course }
        #expect(done.count == 1)
    }

    /// The merge is deliberately conservative, so genuinely different work in the
    /// same course must still land as two separate Done cards.
    @Test("two distinct assignments in one course still show separately in Done")
    func distinctAssignmentsAreNotCollapsed() {
        let state = AppState()
        let due = Date()
        let first = assignment(.canvas, "donedup-c2", "Homework 5", due: due)
        let second = assignment(.canvas, "donedup-c3", "Final project proposal", due: due)

        state.canvasItems = [first, second]
        state.gradescopeItems = []
        state.markActive(first)
        state.markActive(second)
        defer {
            state.markActive(first)
            state.markActive(second)
        }

        let vm = DashboardViewModel()
        vm.bind(to: state)

        let active = vm.items.filter { !$0.isCompleted && $0.assignment.course == Self.course }
        #expect(active.count == 2)
        for card in active { vm.complete(card) }
        vm.reload()

        let done = vm.items.filter { $0.isCompleted && $0.assignment.course == Self.course }
        #expect(done.count == 2)
    }
}
