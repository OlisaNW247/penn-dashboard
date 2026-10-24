import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// "TAP 2028 should never be a class" (the owner, 2026-10-23): the rule, and
/// the two places it is wired in (`allCourseCodes`, `isCourseSelected`).
@Suite("Program sites are never a class")
struct NonClassCanvasSiteTests {
    @Test("TAP and a class year is a program site, as a raw Canvas name or a parsed key")
    func tapYearMatches() {
        #expect(NonClassCanvasSite.matches("TAP 2028"))
        #expect(NonClassCanvasSite.matches("TAP 2029"))
        #expect(NonClassCanvasSite.matches(" tap 2028 "))
        #expect(NonClassCanvasSite.matches("TAP 1999"))
        // Parses to the course key "TAP 2028", which is the class identity
        // everything else keys on, so it is the same site.
        #expect(NonClassCanvasSite.matches("TAP 2028 Seminar"))
    }

    @Test("real classes, other numbers and look-alikes are not")
    func realClassesDoNot() {
        for name in [
            "PHYS 0151", "CIS 2620", "CIS 3990-001 202630 Software Development with AI Coding Agents",
            "ACCT 1010 (Hail) - Fall 2026", "TAP 1010", "TAPS 2028", "",
        ] {
            #expect(!NonClassCanvasSite.matches(name), "\(name) must stay a class")
        }
    }

    @MainActor
    @Test("a program site is never listed and never selected, while a real class is both")
    func wiring() {
        let state = AppState()
        let now = Date()
        state.canvasItems = [
            Assignment(source: .canvas, sourceID: "tap-1", kind: .assignment, course: "TAP 2028",
                       title: "Cohort survey", dueAt: now.addingTimeInterval(86_400), url: nil),
            Assignment(source: .canvas, sourceID: "phys-1", kind: .assignment, course: "PHYS 0151",
                       title: "Worksheet 7", dueAt: now.addingTimeInterval(86_400), url: nil),
        ]
        let codes = state.allCourseCodes()
        #expect(!codes.contains("TAP 2028"))
        #expect(codes.contains("PHYS 0151"))
        #expect(!state.isCourseSelected("TAP 2028"))
    }
}
