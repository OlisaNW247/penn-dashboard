import Testing
import Foundation
@testable import LowHangingFruitKit

/// Parses a recorded Canvas calendar export rather than a string written to
/// match what the parser already does.
///
/// Every other ICS test builds its feed inline, which means they all agree with
/// the parser by construction and none of them can fail for the reason that
/// matters: Canvas changing the shape of what it sends. This one is a real
/// export's structure — CRLF line endings, folded DESCRIPTION continuations,
/// escaped commas, an all-day `VALUE=DATE` entry, and the mix of assignment /
/// quiz / discussion / calendar-event UIDs a single student's feed carries.
struct RecordedICSFixtureTests {

    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "canvas-calendar", withExtension: "ics"),
            "canvas-calendar.ics is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    @Test("a recorded Canvas export parses into every event it contains")
    func parsesAllEvents() throws {
        let items = CanvasICSClient.calendarItems(from: try fixture())
        #expect(items.count == 6)
    }

    @Test("kinds are classified from the real URL paths, not guessed")
    func classifiesKinds() throws {
        let items = CanvasICSClient.calendarItems(from: try fixture())
        let byTitle = Dictionary(items.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })

        #expect(byTitle["Homework 1: Recursion"]?.kind == .assignment)
        #expect(byTitle["Quiz 2"]?.kind == .quiz)
        #expect(byTitle["Week 2 Reading Response"]?.kind == .discussion)
        #expect(byTitle["Lecture 4"]?.kind == .event)
    }

    @Test("only real coursework survives the assignment filter")
    func filtersToAssignments() throws {
        let assignments = CanvasICSClient.assignments(from: try fixture())
        // The lecture is a calendar event and must not read as work to do.
        #expect(!assignments.contains { $0.title == "Lecture 4" })
        #expect(assignments.contains { $0.title == "Homework 1: Recursion" })
    }

    @Test("the trailing [Course] is split off the summary, not left in the title")
    func splitsCourseOutOfSummary() throws {
        let items = CanvasICSClient.calendarItems(from: try fixture())
        let hw = try #require(items.first { $0.title == "Homework 1: Recursion" })
        #expect(hw.course == "CIS 1200")
        // A colon inside the title must not be mistaken for a field separator.
        #expect(!hw.title.contains("["))
    }

    @Test("a summary with no [Course] suffix still yields a usable item")
    func handlesMissingCourse() throws {
        let items = CanvasICSClient.calendarItems(from: try fixture())
        let orphan = try #require(items.first { $0.title.hasPrefix("Untitled assignment") })
        // The point is that it parses and is still actionable — the course slot
        // falls back rather than the whole event being dropped.
        #expect(orphan.kind == .assignment)
        #expect(orphan.dueAt != nil)
    }

    @Test("every dated event carries a due date the dashboard can sort on")
    func datesParse() throws {
        let items = CanvasICSClient.calendarItems(from: try fixture())
        #expect(items.allSatisfy { $0.dueAt != nil })
    }

    @Test("ids are stable across two parses of the same feed")
    func idsAreStable() throws {
        let first = CanvasICSClient.calendarItems(from: try fixture()).map(\.id).sorted()
        let second = CanvasICSClient.calendarItems(from: try fixture()).map(\.id).sorted()
        // Ledger identity is `source:sourceID`; if that moved between syncs the
        // reconciler would treat every item as new and lose all completion.
        #expect(first == second)
        #expect(Set(first).count == first.count)
    }
}
