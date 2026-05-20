import Foundation
import Testing
@testable import PennDashboardKit

@Suite("Canvas ICS parsing")
struct CanvasICSTests {
    static let sampleICS = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Instructure//Canvas//EN
    BEGIN:VEVENT
    UID:event-assignment-12345@canvas.upenn.edu
    SUMMARY:Homework 3 [CIS 5050-001 Software Systems]
    DTSTART:20260520T235900Z
    URL:https://canvas.upenn.edu/courses/1/assignments/12345
    END:VEVENT
    BEGIN:VEVENT
    UID:event-assignment-67890@canvas.upenn.edu
    SUMMARY:Final Project Proposal [ENM 5100-001]
    DTSTART;VALUE=DATE:20260601
    URL:https://canvas.upenn.edu/courses/2/assignments/67890
    END:VEVENT
    END:VCALENDAR
    """

    @Test("parses both events and splits course suffix")
    func parsesEvents() throws {
        let data = Self.sampleICS.data(using: .utf8)!
        let assignments = CanvasICSClient.assignments(from: data)

        #expect(assignments.count == 2)

        let hw = try #require(assignments.first { $0.sourceID.contains("12345") })
        #expect(hw.title == "Homework 3")
        #expect(hw.course == "CIS 5050-001 Software Systems")
        #expect(hw.url?.absoluteString == "https://canvas.upenn.edu/courses/1/assignments/12345")
        #expect(hw.dueAt != nil)
        #expect(hw.source == .canvas)
        #expect(hw.submitted == false)

        let proj = try #require(assignments.first { $0.sourceID.contains("67890") })
        #expect(proj.title == "Final Project Proposal")
        #expect(proj.course == "ENM 5100-001")
        #expect(proj.dueAt != nil)
    }

    @Test("DTSTART with Z suffix is parsed as UTC")
    func dtStartZIsUTC() throws {
        let data = Self.sampleICS.data(using: .utf8)!
        let assignments = CanvasICSClient.assignments(from: data)
        let hw = try #require(assignments.first { $0.sourceID.contains("12345") })
        let due = try #require(hw.dueAt)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 20)
        #expect(comps.hour == 23)
        #expect(comps.minute == 59)
    }

    @Test("date-only DTSTART becomes end-of-day UTC")
    func dateOnlyEndOfDay() throws {
        let data = Self.sampleICS.data(using: .utf8)!
        let assignments = CanvasICSClient.assignments(from: data)
        let proj = try #require(assignments.first { $0.sourceID.contains("67890") })
        let due = try #require(proj.dueAt)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: due)
        #expect(comps.year == 2026)
        #expect(comps.month == 6)
        #expect(comps.day == 1)
        #expect(comps.hour == 23)
    }

    @Test("summary without bracketed course falls back gracefully")
    func summaryWithoutCourse() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:naked
        SUMMARY:Read chapter 4
        DTSTART:20260601T120000Z
        END:VEVENT
        END:VCALENDAR
        """
        let assignments = CanvasICSClient.assignments(from: ics.data(using: .utf8)!)
        #expect(assignments.count == 1)
        #expect(assignments[0].title == "Read chapter 4")
        #expect(assignments[0].course == "(unknown course)")
    }

    @Test("folded continuation lines are unfolded")
    func unfolding() {
        // SUMMARY split across two lines per RFC 5545 §3.1.
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:folded\r\nSUMMARY:Long title that\r\n  continues here [CIS 1200]\r\nDTSTART:20260601T120000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        let assignments = CanvasICSClient.assignments(from: ics.data(using: .utf8)!)
        #expect(assignments.count == 1)
        #expect(assignments[0].title == "Long title that continues here")
        #expect(assignments[0].course == "CIS 1200")
    }
}
