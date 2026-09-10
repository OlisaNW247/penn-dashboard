import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for `GradeCourseCardView`'s two pure, testable rules: the
/// "decided" caption/fraction (the real-phone fix — a pass/fail lab site two
/// weeks into term read "63% of your grade is decided" because that number
/// was only ever measured against what Canvas had posted so far, 2 of a
/// semester's 12 labs) and the "COURSE NAME · SITE" header composition (the
/// fix for two same-named cards, one lecture and one lab, being
/// indistinguishable). This repo doesn't unit-test views themselves — see
/// CLAUDE.md — so these `static func`s are pulled out specifically to be
/// reachable and tested without instantiating any SwiftUI.
///
/// `GradeBreakdown` values below are built directly through its synthesized
/// memberwise initializer (the same one `GradeEngine.compute` itself uses to
/// construct its return value) with hand-picked numbers, rather than routed
/// through `GradeEngine.compute` with a category fixture: nothing here
/// exercises the engine's arithmetic, only how the view formats whatever
/// `decidedFraction`/`semesterDecidedFraction` the engine handed it, so
/// picking the numbers directly keeps each expectation traceable to a single
/// input instead of to a chain of category math.
@Suite("Grade decided text")
struct GradeDecidedTextTests {

    private func breakdown(decidedFraction: Double, semesterDecidedFraction: Double?) -> GradeBreakdown {
        GradeBreakdown(
            mode: .points,
            currentPercent: 91.4,
            decidedFraction: decidedFraction,
            pendingGradingCount: 0,
            categories: [],
            semesterDecidedFraction: semesterDecidedFraction,
            modeSource: .canvas,
            leftOutCategoryIDs: [],
            participatingWeightSum: nil
        )
    }

    // MARK: - decidedFraction / decidedText

    @Test("semester fraction known: reports the semester share, not the posted-only one")
    func decidedTextPrefersSemesterFraction() {
        let result = breakdown(decidedFraction: 0.63, semesterDecidedFraction: 0.165)
        #expect(GradeCourseCardView.decidedFraction(for: result) == 0.165)
        #expect(GradeCourseCardView.decidedText(for: result) == "17% of the semester is decided")
    }

    @Test("semester fraction unknown: falls back to the posted-only share with the caveat")
    func decidedTextFallsBackToPostedOnly() {
        let result = breakdown(decidedFraction: 0.63, semesterDecidedFraction: nil)
        #expect(GradeCourseCardView.decidedFraction(for: result) == 0.63)
        #expect(GradeCourseCardView.decidedText(for: result)
                == "63% of what\u{2019}s posted is graded \u{00b7} semester share unknown")
    }

    @Test("the fraction is clamped into 0...1 before rounding to a percent")
    func decidedTextClampsOutOfRangeFractions() {
        let over = breakdown(decidedFraction: 1.2, semesterDecidedFraction: nil)
        #expect(GradeCourseCardView.decidedText(for: over).hasPrefix("100%"))

        let under = breakdown(decidedFraction: -0.1, semesterDecidedFraction: nil)
        #expect(GradeCourseCardView.decidedText(for: under).hasPrefix("0%"))
    }

    // MARK: - headerText

    @Test("header text: bare course name when there's no site label")
    func headerTextWithoutSiteLabel() {
        #expect(GradeCourseCardView.headerText(courseName: "PHYS 0151", siteLabel: nil) == "PHYS 0151")
    }

    @Test("header text: appends an uppercased site label to disambiguate same-named cards")
    func headerTextWithSiteLabel() {
        #expect(GradeCourseCardView.headerText(courseName: "PHYS 0151", siteLabel: "lab")
                == "PHYS 0151 \u{00b7} LAB")
    }

    @Test("header text: an empty site label reads the same as no label")
    func headerTextWithEmptySiteLabel() {
        #expect(GradeCourseCardView.headerText(courseName: "PHYS 0151", siteLabel: "") == "PHYS 0151")
    }
}
