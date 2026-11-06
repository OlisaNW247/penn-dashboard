import Testing
import Foundation
@testable import LowHangingFruitKit

@Suite struct FactTitleTests {
    @Test(arguments: [
        ("Take the final exam (Dec 14, 4-8, anns....)", "Final exam"),
        ("Take the final exam (Dec 14, 4-8 pm, Annenberg)", "Final exam"),
        ("Take the final exam (Dec 14, 4-8, anns....", "Final exam"),
        ("Turn in lab report [Canvas]", "Lab report"),
        ("Submit Problem Set 7: due Friday", "Problem Set 7"),
        ("Read chapter 5", "Chapter 5"),
        ("PSet 3", "PSet 3"),
        ("CIS 2400 project", "CIS 2400 project"),
        ("Reading: chapter 5", "Reading: chapter 5"),
        ("Final exam", "Final exam"),
        ("  ", "  "),
        ("Attend", "Attend"),
        ("Take the", "Take the"),
        ("Doctor visit", "Doctor visit"),
        ("Quiz 2 - moved to Monday", "Quiz 2"),
        ("Quiz 2 \u{2014} moved to Monday", "Quiz 2"),
    ])
    func shortens(input: String, expected: String) {
        #expect(FactTitle.short(input) == expected)
    }

    @Test func cardShortensOnlyFactRows() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/AssignmentCardView.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        #expect(src.contains("FactTitle.short(item.assignment.title)"))
        #expect(src.contains("AppState.isFactRow(item.assignment)"))
    }
}
