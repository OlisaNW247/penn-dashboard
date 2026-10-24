import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A task found in an announcement leaves the megaphone's found list once the
/// real Canvas assignment it restates is finished (2026-10-23: "combined
/// worksheet 6-7" stayed in "found" after the student turned in the worksheet).
///
/// Pure: `announcementRealTwins` and `announcementFindsWithFinishedTwin` are
/// `nonisolated static` and take the finds, the real items and an
/// `isFinished` closure, so no `AppState`, ledger or `UserDefaults` is
/// involved. `rebuildDashboardItems` passes the same inputs with
/// `isCompleted(_:)`, and the dashboard's own carry-a-tick loop uses the same
/// `announcementRealTwins`, so the sheet and the dashboard cannot disagree
/// about what a twin is.
@Suite("Announcement finds: a finished real twin takes the find off the list")
struct AnnouncementFindTwinTests {
    static let day: TimeInterval = 24 * 60 * 60
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func find(
        _ sourceID: String,
        title: String,
        course: String = "PHYS 0151",
        due: Date?
    ) -> Assignment {
        Assignment(
            source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment, course: course,
            title: title, dueAt: due, url: nil
        )
    }

    private func real(
        _ sourceID: String,
        title: String,
        course: String = "PHYS 0151",
        due: Date?
    ) -> Assignment {
        Assignment(
            source: .canvas, sourceID: sourceID, kind: .assignment, course: course,
            title: title, dueAt: due, url: nil
        )
    }

    /// The finds left over once the finished twins' finds are taken out, the
    /// way `rebuildDashboardItems` filters `announcementPageItems`.
    private func remaining(
        _ finds: [Assignment],
        among reals: [Assignment],
        finished: Set<String>
    ) -> [String] {
        let hidden = AppState.announcementFindsWithFinishedTwin(
            finds, among: reals, isFinished: { finished.contains($0.id) }
        )
        return finds.filter { !hidden.contains($0.id) }.map(\.id)
    }

    // MARK: The brief's cases

    @Test("a dated find and its dated Canvas twin: finished hides the find, unfinished keeps it")
    func finishedTwinHidesTheFind() {
        // "Combined worksheet 6-7" is the announcement's wording of the
        // assignment "Worksheet 6-7". With both dated within the tolerance the
        // title tier accepts them (3 of 4 tokens shared).
        let due = Self.now + 3 * Self.day
        let announced = find("announcement-1-0", title: "Combined worksheet 6-7", due: due)
        let canvas = real("w67", title: "Worksheet 6-7", due: due + 3600)

        #expect(remaining([announced], among: [canvas], finished: [canvas.id]).isEmpty)
        #expect(remaining([announced], among: [canvas], finished: []) == [announced.id])
    }

    @Test("an undated find with the real assignment's own title: finished hides it, unfinished keeps it")
    func undatedFindWithTheSameTitle() {
        let announced = find("announcement-2-0", title: "Worksheet 6-7", due: nil)
        let canvas = real("w67", title: "Worksheet 6-7", due: Self.now + 3 * Self.day)

        #expect(remaining([announced], among: [canvas], finished: [canvas.id]).isEmpty)
        #expect(remaining([announced], among: [canvas], finished: []) == [announced.id])
    }

    @Test("known limit of today's matcher: an undated \"Combined worksheet 6-7\" is not recognised as \"Worksheet 6-7\", so its find stays")
    func undatedCombinedTitleIsNotATwin() {
        // `isLikelyAnnouncementDuplicate` needs both dates for a title that is
        // merely similar, and an undated find has none. This pins the matcher
        // as it is for these two wordings (the matcher is shared with the
        // dashboard's collapse and is deliberately conservative: a false merge
        // is worse than a missed one); flip the expectation if it ever learns
        // this case. The owner's real Canvas title is spelled with no spaces,
        // "CombinedWorksheets6-7", and that one does match
        // (`ownersCombinedWorksheetPair`).
        let announced = find("announcement-3-0", title: "Combined worksheet 6-7", due: nil)
        let canvas = real("w67", title: "Worksheet 6-7", due: Self.now + 3 * Self.day)

        #expect(AppState.announcementRealTwins(of: [announced], among: [canvas]).isEmpty)
        #expect(remaining([announced], among: [canvas], finished: [canvas.id]) == [announced.id])
    }

    @Test("the owner's real pair: an undated \"Combined worksheet 6-7\" find is hidden once Canvas's CombinedWorksheets6-7 is finished")
    func ownersCombinedWorksheetPair() {
        // Read off the owner's phone 2026-10-23: the Canvas assignment is
        // titled exactly "CombinedWorksheets6-7", due 2026-10-20T03:59:59Z,
        // and the post that announced it left the find undated.
        let canvas = real(
            "combined-6-7", title: "CombinedWorksheets6-7",
            due: Date(timeIntervalSince1970: 1_792_468_799)
        )
        for (index, title) in ["Combined worksheet 6-7", "Try combined worksheet 6-7"].enumerated() {
            let announced = find("announcement-\(20 + index)-0", title: title, due: nil)
            #expect(remaining([announced], among: [canvas], finished: [canvas.id]).isEmpty, "\(title)")
            #expect(remaining([announced], among: [canvas], finished: []) == [announced.id], "\(title)")
        }
        // Not the other worksheets of the same class.
        let single = find("announcement-22-0", title: "Worksheet 6", due: nil)
        #expect(remaining([single], among: [canvas], finished: [canvas.id]) == [single.id])
    }

    @Test("a finished item in another class is not a twin, even with the same title")
    func twinInAnotherClassIsKept() {
        let announced = find("announcement-4-0", title: "Worksheet 6-7", course: "PHYS 0151", due: nil)
        let elsewhere = real("w67", title: "Worksheet 6-7", course: "CIS 1200", due: nil)

        #expect(remaining([announced], among: [elsewhere], finished: [elsewhere.id]) == [announced.id])
    }

    @Test("a dated find and a same-titled twin further apart than the tolerance are two tasks: the find stays")
    func datesBeyondToleranceKeepTheFind() {
        let tolerance = AssignmentDeduplicator.similarTitleDueDateTolerance
        let due = Self.now + 3 * Self.day
        let announced = find("announcement-5-0", title: "Worksheet 6-7", due: due)
        let otherWeek = real("w67", title: "Worksheet 6-7", due: due + tolerance + 60)
        let edge = real("w67-edge", title: "Worksheet 6-7", due: due + tolerance)

        // The titles are identical, so the title tier alone accepts it (it
        // allows 21 days); it is the second predicate that refuses.
        #expect(AssignmentDeduplicator.isLikelyAnnouncementDuplicate(
            announcementTitle: announced.title, announcementDue: announced.dueAt,
            existingTitle: otherWeek.title, existingDue: otherWeek.dueAt
        ))
        #expect(remaining([announced], among: [otherWeek], finished: [otherWeek.id]) == [announced.id])
        // Exactly at the tolerance is still the same day's task.
        #expect(remaining([announced], among: [edge], finished: [edge.id]).isEmpty)
    }

    // MARK: Pinned to the dashboard's own loop

    @Test("classes are compared by identity, so PHYS 0151 and PHYS 151 are one class")
    func spellingsOfOneClassAreOneClass() {
        let announced = find("announcement-6-0", title: "Worksheet 6-7", course: "PHYS 0151", due: nil)
        let canvas = real("w67", title: "Worksheet 6-7", course: "PHYS 151", due: nil)

        #expect(remaining([announced], among: [canvas], finished: [canvas.id]).isEmpty)
    }

    @Test("the twin is the first title match in the order the real items came, and its date is judged after: a later, closer-dated item is not reached for")
    func firstTitleMatchThenDateCheck() {
        // The same rule the carry-a-tick loop has always had (`first(where:)`
        // on the title, then `announcementDatesCompatible` on that one item).
        let due = Self.now + 3 * Self.day
        let announced = find("announcement-7-0", title: "Worksheet 6-7", due: due)
        let nextWeek = real("w67-b", title: "Worksheet 6-7", due: due + 7 * Self.day)
        let sameDay = real("w67-a", title: "Worksheet 6-7", due: due)

        #expect(AppState.announcementRealTwins(of: [announced], among: [nextWeek, sameDay]).isEmpty)
        #expect(AppState.announcementRealTwins(of: [announced], among: [sameDay, nextWeek]).map(\.real.id) == [sameDay.id])
    }

    @Test("only the real twin is asked whether it is finished, never the find, and each find is judged on its own twin")
    func finishedIsAskedOfTheRealItemOnly() {
        let due = Self.now + 3 * Self.day
        let done = find("announcement-8-0", title: "Worksheet 6-7", due: due)
        let notDone = find("announcement-9-0", title: "Lab 3 report", due: due)
        let noTwin = find("announcement-10-0", title: "Bring a calculator", due: nil)
        let doneReal = real("w67", title: "Worksheet 6-7", due: due)
        let notDoneReal = real("lab3", title: "Lab 3 report", due: due)

        var asked: [String] = []
        let hidden = AppState.announcementFindsWithFinishedTwin(
            [done, notDone, noTwin], among: [doneReal, notDoneReal],
            isFinished: { item in
                asked.append(item.id)
                return item.id == doneReal.id
            }
        )
        #expect(hidden == [done.id])
        #expect(asked == [doneReal.id, notDoneReal.id], "only real twins, in the finds' order")
    }

    @Test("with no finds, no real items, or no match, nothing is hidden")
    func emptyInputsHideNothing() {
        let announced = find("announcement-11-0", title: "Worksheet 6-7", due: nil)
        let canvas = real("w67", title: "Worksheet 6-7", due: nil)
        func everythingFinished(_: Assignment) -> Bool { true }

        #expect(AppState.announcementFindsWithFinishedTwin([], among: [canvas], isFinished: everythingFinished).isEmpty)
        #expect(AppState.announcementFindsWithFinishedTwin([announced], among: [], isFinished: everythingFinished).isEmpty)
        #expect(AppState.announcementRealTwins(of: [], among: []).isEmpty)
    }
}
