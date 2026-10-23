import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The megaphone sheet's class bubbles, as pure rules: what a tap does to the
/// set of selected classes, which rows a selection keeps, and the one combined
/// list drawn while any class is selected. Nothing here builds a view or an
/// `AppState`; the rules are `nonisolated static`, and these suites are not
/// `@MainActor`, which is how the main-actor isolation trap (CLAUDE.md,
/// `decidedText`) would show up if one were not.

@Suite("Announcements sheet bubbles: what a tap does")
struct AnnouncementSheetTapTests {
    private typealias Sheet = AppState

    @Test("\"all\" clears the selection, whatever it held")
    func allClears() {
        #expect(Sheet.announcementSheetTap(nil, selection: []) == [])
        #expect(Sheet.announcementSheetTap(nil, selection: ["A"]) == [])
        #expect(Sheet.announcementSheetTap(nil, selection: ["A", "B", "C"]) == [])
    }

    @Test("a class tapped while all are shown selects just that class")
    func classFromAll() {
        #expect(Sheet.announcementSheetTap("A", selection: []) == ["A"])
        #expect(Sheet.announcementSheetTap("PHYS 151", selection: []) == ["PHYS 151"])
    }

    @Test("an unselected class tapped while some are selected is added")
    func addAnother() {
        #expect(Sheet.announcementSheetTap("B", selection: ["A"]) == ["A", "B"])
        #expect(Sheet.announcementSheetTap("C", selection: ["A", "B"]) == ["A", "B", "C"])
    }

    @Test("a selected class tapped is removed, and removing the last goes back to all")
    func removeOne() {
        #expect(Sheet.announcementSheetTap("A", selection: ["A", "B"]) == ["B"])
        #expect(Sheet.announcementSheetTap("B", selection: ["A", "B"]) == ["A"])
        #expect(Sheet.announcementSheetTap("A", selection: ["A", "B", "C"]) == ["B", "C"])
        #expect(Sheet.announcementSheetTap("A", selection: ["A"]) == [], "the last one out is all")
    }

    @Test("a sequence of taps lands where each step says")
    func sequence() {
        var selection: Set<String> = []
        func tap(_ course: String?) { selection = Sheet.announcementSheetTap(course, selection: selection) }
        tap("A"); #expect(selection == ["A"])
        tap("B"); #expect(selection == ["A", "B"])
        tap("A"); #expect(selection == ["B"])
        tap("B"); #expect(selection == [])
        tap("C"); #expect(selection == ["C"])
        tap("A"); tap("B"); #expect(selection == ["A", "B", "C"])
        tap(nil); #expect(selection == [])
        tap(nil); #expect(selection == [], "all again is still all")
    }

    @Test("a tap never leaves a class selected that was not tapped, and touches only the tapped class")
    func touchesOnlyTheTappedClass() {
        for start in [Set<String>(), ["A"], ["A", "B"], ["B", "C"]] as [Set<String>] {
            for tapped in ["A", "B", "C"] {
                let next = Sheet.announcementSheetTap(tapped, selection: start)
                if start.isEmpty {
                    #expect(next == [tapped])
                } else {
                    #expect(next.symmetricDifference(start).isSubset(of: [tapped]), "\(start) tap \(tapped)")
                }
            }
        }
    }
}

@Suite("Announcements sheet bubbles: narrowing by a selection of classes")
struct AnnouncementSheetSelectionNarrowingTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String, course: String) -> AnnouncementRecord {
        AnnouncementRecord(
            id: id, courseID: "1", courseCode: course, title: "Post \(id)", postedAt: Self.now,
            url: nil, snippet: "", recordedAt: Self.now
        )
    }

    private func card(_ sourceID: String, course: String) -> DashItem {
        DashItem(
            assignment: Assignment(
                source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment, course: course,
                title: "Task \(sourceID)", dueAt: Self.now, url: nil
            ),
            dueOverride: nil, isCompleted: false, completedAt: nil
        )
    }

    private let records = [
        AnnouncementSheetSelectionNarrowingTests.stub("1", "PHYS 0151"),
        AnnouncementSheetSelectionNarrowingTests.stub("2", "CIS 1200"),
        AnnouncementSheetSelectionNarrowingTests.stub("3", "phys 151"),
        AnnouncementSheetSelectionNarrowingTests.stub("4", "FNAR 0010"),
        AnnouncementSheetSelectionNarrowingTests.stub("5", "PHYS 152"),
    ]

    private static func stub(_ id: String, _ course: String) -> AnnouncementRecord {
        AnnouncementRecord(
            id: id, courseID: "1", courseCode: course, title: "Post \(id)", postedAt: now,
            url: nil, snippet: "", recordedAt: now
        )
    }

    private var cards: [DashItem] {
        [
            card("announcement-1-0", course: "PHYS 0151"), card("announcement-2-0", course: "CIS 1200"),
            card("syllabus-9-final", course: "PHYS 151"), card("announcement-4-0", course: "FNAR 0010"),
        ]
    }

    @Test("an empty selection keeps everything, in order")
    func emptyKeepsAll() {
        #expect(AppState.announcementSheetNarrowed(records, toCourses: []).map(\.id) == ["1", "2", "3", "4", "5"])
        #expect(AppState.announcementSheetNarrowed(cards, toCourses: []).map(\.assignment.sourceID) == cards.map(\.assignment.sourceID))
        #expect(AppState.announcementSheetCourseMatches("anything at all", selection: []))
    }

    @Test("one class keeps that class's rows, by identity: PHYS 0151, phys 151 and PHYS 151 are one class, PHYS 152 is another")
    func oneClass() {
        for spelling in ["PHYS 151", "PHYS 0151", "phys 151"] {
            #expect(AppState.announcementSheetNarrowed(records, toCourses: [spelling]).map(\.id) == ["1", "3"], "\(spelling)")
            #expect(AppState.announcementSheetNarrowed(cards, toCourses: [spelling]).map(\.assignment.sourceID)
                == ["announcement-1-0", "syllabus-9-final"], "\(spelling)")
        }
        #expect(AppState.announcementSheetNarrowed(records, toCourses: ["CIS 1200"]).map(\.id) == ["2"])
        #expect(AppState.announcementSheetNarrowed(records, toCourses: ["PHYS 152"]).map(\.id) == ["5"])
        #expect(AppState.announcementSheetNarrowed(records, toCourses: ["CIS 151"]).isEmpty, "department stays in the identity")
        #expect(AppState.announcementSheetNarrowed(cards, toCourses: ["MATH 1400"]).isEmpty)
    }

    @Test("two classes keep both classes' rows, in the order they came")
    func twoClasses() {
        #expect(AppState.announcementSheetNarrowed(records, toCourses: ["FNAR 10", "PHYS 151"]).map(\.id) == ["1", "3", "4"])
        #expect(AppState.announcementSheetNarrowed(cards, toCourses: ["CIS 1200", "FNAR 0010"]).map(\.assignment.sourceID)
            == ["announcement-2-0", "announcement-4-0"])
        // Two spellings of one class selected together are still that one class.
        #expect(AppState.announcementSheetNarrowed(records, toCourses: ["PHYS 151", "PHYS 0151"]).map(\.id) == ["1", "3"])
    }

    @Test("the single-class helpers are the selection of one")
    func singleClassHelpersRouteThroughTheSet() {
        #expect(AppState.announcementSheetNarrowed(records, toCourse: nil).map(\.id) == AppState.announcementSheetNarrowed(records, toCourses: []).map(\.id))
        #expect(AppState.announcementSheetNarrowed(records, toCourse: "PHYS 151").map(\.id) == AppState.announcementSheetNarrowed(records, toCourses: ["PHYS 151"]).map(\.id))
        #expect(AppState.announcementSheetNarrowed(cards, toCourse: "CIS 1200").map(\.id) == AppState.announcementSheetNarrowed(cards, toCourses: ["CIS 1200"]).map(\.id))
        #expect(AppState.announcementSheetCourseMatches("PHYS 0151", filter: "PHYS 151"))
        #expect(!AppState.announcementSheetCourseMatches("PHYS 0151", filter: "PHYS 152"))
        #expect(AppState.announcementSheetCourseMatches("anything", filter: nil))
        #expect(AppState.announcementSheetCourseMatches("PHYS 0151", selection: ["CIS 1200", "PHYS 151"]))
        #expect(!AppState.announcementSheetCourseMatches("PHYS 0151", selection: ["CIS 1200"]))
    }
}

@Suite("Announcements sheet bubbles: the one list for the selected classes")
struct AnnouncementSheetCompiledTests {
    static let day: TimeInterval = 24 * 60 * 60
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(_ id: String, daysAgo: Double, course: String = "COMP 100", ed: Bool = false) -> AnnouncementRecord {
        let when = Self.now.addingTimeInterval(-daysAgo * Self.day)
        return AnnouncementRecord(
            id: id, courseID: "1", courseCode: course, title: "Post \(id)", postedAt: when,
            url: nil, snippet: "", recordedAt: when
        )
    }

    /// A find: `announcement-<post>-<index>` for a Canvas post, due `dueInDays` from now.
    private func find(
        post: String?,
        index: Int = 0,
        sourceID: String? = nil,
        dueInDays: Double?,
        override: Double? = nil
    ) -> DashItem {
        let id = sourceID ?? "announcement-\(post ?? "none")-\(index)"
        return DashItem(
            assignment: Assignment(
                source: .canvasAnnouncement, sourceID: id, kind: .assignment, course: "COMP 100",
                title: "Task \(id)", dueAt: dueInDays.map { Self.now.addingTimeInterval($0 * Self.day) }, url: nil
            ),
            dueOverride: override.map { Self.now.addingTimeInterval($0 * Self.day) },
            isCompleted: false, completedAt: nil
        )
    }

    private func ids(_ entries: [AnnouncementSheetEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .found(let item): return "find:" + item.assignment.sourceID
            case .post(let record): return "post:" + record.id
            }
        }
    }

    @Test("posts alone come out newest first")
    func postsNewestFirst() {
        let entries = AppState.announcementSheetCompiled(
            found: [], records: [post("1", daysAgo: 5), post("2", daysAgo: 1), post("3", daysAgo: 3)]
        )
        #expect(ids(entries) == ["post:2", "post:3", "post:1"])
    }

    @Test("a find is dated by its post, not by its own due date, and sits directly above that post")
    func findFollowsItsPost() {
        // Task found in the 5-day-old post but due in 9 days; another post sits between.
        let entries = AppState.announcementSheetCompiled(
            found: [find(post: "1", dueInDays: 9)],
            records: [post("2", daysAgo: 1), post("3", daysAgo: 3), post("1", daysAgo: 5), post("4", daysAgo: 7)]
        )
        #expect(ids(entries) == ["post:2", "post:3", "find:announcement-1-0", "post:1", "post:4"])
    }

    @Test("on a tie nothing wedges between a find and its post, and equal dates keep the order they came in")
    func tiesKeepAFindAbovePost() {
        let a = post("1", daysAgo: 2)
        let b = post("2", daysAgo: 2)
        let c = post("3", daysAgo: 2)
        let entries = AppState.announcementSheetCompiled(
            found: [find(post: "3", dueInDays: 1), find(post: "2", dueInDays: 5)],
            records: [a, b, c]
        )
        #expect(ids(entries) == ["post:1", "find:announcement-2-0", "post:2", "find:announcement-3-0", "post:3"])
        // Deterministic: the same inputs, the same list.
        #expect(AppState.announcementSheetCompiled(found: [find(post: "3", dueInDays: 1), find(post: "2", dueInDays: 5)], records: [a, b, c]) == entries)
    }

    @Test("two finds from one post stay together above it, in the order the found list gave them")
    func severalFindsOfOnePost() {
        let entries = AppState.announcementSheetCompiled(
            found: [find(post: "1", index: 1, dueInDays: 3), find(post: "9", dueInDays: 1), find(post: "1", index: 0, dueInDays: 2)],
            records: [post("2", daysAgo: 1), post("1", daysAgo: 4)]
        )
        // "9" is not a listed post: its find is dated by its card (due in 1 day, newer than everything).
        #expect(ids(entries) == [
            "find:announcement-9-0", "post:2",
            "find:announcement-1-1", "find:announcement-1-0", "post:1",
        ])
    }

    @Test("a find with no listed post, like a syllabus exam, is dated by its card, and the student's edited date wins")
    func loneFindsUseTheirCardDate() {
        let exam = find(post: nil, sourceID: "syllabus-1-midterm-1", dueInDays: -2)
        let moved = find(post: nil, sourceID: "syllabus-1-final", dueInDays: -10, override: -4)
        let entries = AppState.announcementSheetCompiled(
            found: [moved, exam],
            records: [post("1", daysAgo: 1), post("2", daysAgo: 3), post("3", daysAgo: 6)]
        )
        // exam: 2 days ago (between posts 1 and 2). moved: edited to 4 days ago (between 2 and 3).
        #expect(ids(entries) == ["post:1", "find:syllabus-1-midterm-1", "post:2", "find:syllabus-1-final", "post:3"])
    }

    @Test("a lone find equal in date to a post comes after the post, and lone finds of equal date keep their order")
    func equalDatesWithLoneFinds() {
        let sameDay = find(post: nil, sourceID: "syllabus-1-a", dueInDays: -2)
        let alsoSame = find(post: nil, sourceID: "syllabus-1-b", dueInDays: -2)
        let entries = AppState.announcementSheetCompiled(
            found: [sameDay, alsoSame], records: [post("1", daysAgo: 2)]
        )
        #expect(ids(entries) == ["post:1", "find:syllabus-1-a", "find:syllabus-1-b"])
    }

    @Test("an entry with no date at all goes last, in order")
    func datelessLast() {
        let undatedA = find(post: nil, sourceID: "syllabus-1-x", dueInDays: nil)
        let undatedB = find(post: nil, sourceID: "syllabus-1-y", dueInDays: nil)
        let dated = find(post: nil, sourceID: "syllabus-1-z", dueInDays: -30)
        let entries = AppState.announcementSheetCompiled(
            found: [undatedA, dated, undatedB], records: [post("1", daysAgo: 20)]
        )
        #expect(ids(entries) == ["post:1", "find:syllabus-1-z", "find:syllabus-1-x", "find:syllabus-1-y"])
    }

    @Test("an undated find of a listed post is dated by the post, so it is not last")
    func undatedFindOfAListedPost() {
        let entries = AppState.announcementSheetCompiled(
            found: [find(post: "1", dueInDays: nil)],
            records: [post("2", daysAgo: 1), post("1", daysAgo: 3), post("3", daysAgo: 6)]
        )
        #expect(ids(entries) == ["post:2", "find:announcement-1-0", "post:1", "post:3"])
    }

    @Test("an Ed find joins its Ed post")
    func edFindJoinsItsPost() {
        let edPost = post("ed:9301:77", daysAgo: 2)
        let entries = AppState.announcementSheetCompiled(
            found: [find(post: nil, sourceID: "ed-9301-77-0", dueInDays: 8)],
            records: [post("1", daysAgo: 1), edPost, post("2", daysAgo: 4)]
        )
        #expect(ids(entries) == ["post:1", "find:ed-9301-77-0", "post:ed:9301:77", "post:2"])
    }

    @Test("nothing in, nothing out; and every entry has its own id")
    func emptyAndIDs() {
        #expect(AppState.announcementSheetCompiled(found: [], records: []).isEmpty)
        let entries = AppState.announcementSheetCompiled(
            found: [find(post: "1", dueInDays: 1), find(post: nil, sourceID: "syllabus-1-final", dueInDays: 4)],
            records: [post("1", daysAgo: 1)]
        )
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.count == 3)
    }
}
