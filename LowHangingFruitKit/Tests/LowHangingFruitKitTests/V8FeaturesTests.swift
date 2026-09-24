import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The v8-features additions: unread announcement tracking and filing a
/// classless recurring task under the class its title names. Every test that persists uses its
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

    // MARK: Recurring tasks with no class

    private func task(title: String, course: String) -> RecurringTask {
        RecurringTask(title: title, course: course, weekday: 3, hour: 23, minute: 59,
                      startDate: Date(timeIntervalSince1970: 1_800_000_000), endDate: nil, origin: .manual)
    }

    @Test("a classless recurring task is filed under the one class its title names, ignoring case and spacing")
    func classlessTaskAdoptsCourseFromTitle() {
        let known = ["CIS 2620", "CIS 3990", "PHYS 0151"]
        #expect(task(title: "Cis 3990 recurring lab", course: "").adoptingCourse(from: known).course == "CIS 3990")
        #expect(task(title: "cis3990 lab", course: "").adoptingCourse(from: known).course == "CIS 3990")
    }

    @Test("a recurring task keeps its own class, and stays classless when the title names none or two")
    func adoptionNeverOverridesOrGuesses() {
        let known = ["CIS 2620", "CIS 3990"]
        #expect(task(title: "CIS 3990 lab", course: "CIS 2620").adoptingCourse(from: known).course == "CIS 2620")
        #expect(task(title: "weekly reading", course: "").adoptingCourse(from: known).course == "")
        #expect(task(title: "CIS 2620 + CIS 3990 study group", course: "").adoptingCourse(from: known).course == "")
    }

}
