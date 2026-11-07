import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The megaphone sheet's class filter, as pure rules: which rows a selection
/// keeps. Nothing here builds a view or an
/// `AppState`; the rules are `nonisolated static`, and these suites are not
/// `@MainActor`, which is how the main-actor isolation trap (CLAUDE.md,
/// `decidedText`) would show up if one were not.

@Suite("Announcements sheet class filter: narrowing by a selection of classes")
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
