import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The v8-features additions: unread announcement tracking, the per-card
/// steps prototype, and the "?" pick pool. Every test that persists uses its
/// own scratch `UserDefaults` suite — CLAUDE.md's shared-defaults trap.
@MainActor
@Suite("v8 features")
struct V8FeaturesTests {
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "v8-features-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func assignment(_ id: String, course: String, due: Date?) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: id, dueAt: due, url: nil)
    }

    private func dashItem(_ id: String, course: String, due: Date?, done: Bool = false) -> DashItem {
        DashItem(assignment: assignment(id, course: course, due: due),
                 dueOverride: nil, isCompleted: done, completedAt: done ? due : nil)
    }

    // MARK: Announcements

    @Test("announcements are unread until the sheet has been opened, then only new ones count")
    func unreadAnnouncements() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let readState = AnnouncementReadState(defaults: defaults)
        let first = [assignment("a", course: "CIS 1200", due: nil),
                     assignment("b", course: "CIS 1200", due: nil)]

        #expect(AnnouncementReadState.unread(first, seen: readState.seenIDs).count == 2)

        readState.markAllSeen(first)
        #expect(AnnouncementReadState.unread(first, seen: readState.seenIDs).isEmpty)

        let later = first + [assignment("c", course: "PHYS 0151", due: nil)]
        #expect(AnnouncementReadState.unread(later, seen: readState.seenIDs).map(\.id) == [later[2].id])
    }

    @Test("marking seen keeps only ids still on the page, so the stored set can't grow forever")
    func seenSetIsBoundedToThePage() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let readState = AnnouncementReadState(defaults: defaults)
        let old = assignment("old", course: "CIS 1200", due: nil)
        let current = assignment("current", course: "CIS 1200", due: nil)

        readState.markAllSeen([old, current])
        readState.markAllSeen([current])

        #expect(readState.seenIDs == [current.id])
    }

    // MARK: Steps

    @Test("steps add, toggle, remove and survive a fresh store on the same defaults")
    func stepsRoundTrip() throws {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AssignmentStepsStore(defaults: defaults)

        store.add("outline", to: "hw1")
        store.add("  draft  ", to: "hw1")
        store.add("   ", to: "hw1")
        #expect(store.steps(for: "hw1").map(\.title) == ["outline", "draft"])

        let outline = try #require(store.steps(for: "hw1").first)
        store.toggle(outline.id, in: "hw1")
        #expect(AssignmentStepsStore.progress(store.steps(for: "hw1")) == (1, 2))

        let reloaded = AssignmentStepsStore(defaults: defaults)
        #expect(reloaded.steps(for: "hw1") == store.steps(for: "hw1"))

        for step in reloaded.steps(for: "hw1") { reloaded.remove(step.id, from: "hw1") }
        #expect(reloaded.stepsByAssignment["hw1"] == nil)
    }

    // MARK: "?" pick

    @Test("the pick pool is the soonest unfinished item per class, upcoming only, inside the horizon")
    func pickCandidates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let items = [
            dashItem("cis-soon", course: "CIS 1200", due: now.addingTimeInterval(1 * day)),
            dashItem("cis-later", course: "CIS 1200", due: now.addingTimeInterval(3 * day)),
            dashItem("phys-overdue", course: "PHYS 0151", due: now.addingTimeInterval(-1 * day)),
            dashItem("phys-next", course: "PHYS 0151", due: now.addingTimeInterval(2 * day)),
            dashItem("econ-done", course: "ECON 0100", due: now.addingTimeInterval(1 * day), done: true),
            dashItem("math-far", course: "MATH 1400", due: now.addingTimeInterval(30 * day)),
            dashItem("undated", course: "WRIT 0020", due: nil),
        ]

        let ids = DashboardViewModel.pickCandidates(from: items, now: now).map(\.assignment.sourceID)

        #expect(ids == ["cis-soon", "phys-next"])
    }
}
