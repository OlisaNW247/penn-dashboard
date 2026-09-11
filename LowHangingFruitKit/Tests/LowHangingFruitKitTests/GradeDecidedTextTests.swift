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

    private func breakdown(
        decidedFraction: Double,
        semesterDecidedFraction: Double?,
        categoriesMissingExpectedCount: [String] = [],
        currentPercent: Double? = 91.4,
        attendanceOnlyPercent: Double? = nil
    ) -> GradeBreakdown {
        GradeBreakdown(
            mode: .points,
            currentPercent: currentPercent,
            decidedFraction: decidedFraction,
            pendingGradingCount: 0,
            categories: [],
            semesterDecidedFraction: semesterDecidedFraction,
            modeSource: .canvas,
            leftOutCategoryIDs: [],
            participatingWeightSum: nil,
            attendanceOnlyPercent: attendanceOnlyPercent,
            categoriesMissingExpectedCount: categoriesMissingExpectedCount
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

    // `GradeCountPredictor` means every category the engine builds now
    // predicts SOME expected count -- a stated syllabus count, its own name,
    // or a pace projection -- so `GradeEngine.compute` can no longer produce
    // a non-empty `categoriesMissingExpectedCount` alongside a known
    // `semesterDecidedFraction`; that combination belongs to history, not to
    // anything a real `GradeBreakdown` can carry today (the always-empty-list
    // case below, `decidedTextWithNoMissingCategoriesNamed`, is the only
    // shape the engine emits now). The view function itself is untouched
    // (it's in `LowHangingFruitUI`, out of this change's scope) and still
    // honors a hand-fed list, so this documents that a known semester
    // fraction wins outright regardless.
    @Test("semester fraction known wins outright, even if a hand-built breakdown also carries a (now-impossible) missing-categories list")
    func decidedTextKnownFractionWinsOverMissingCategoriesList() {
        let known = breakdown(
            decidedFraction: 0.63,
            semesterDecidedFraction: 0.17,
            categoriesMissingExpectedCount: ["Quizzes", "HomeWorks"] // fed by hand; a real breakdown never carries this alongside a known fraction
        )
        #expect(GradeCourseCardView.decidedText(for: known) == "17% of the semester is decided")
    }

    @Test("semester fraction unknown, no named categories: falls back to the plain caveat")
    func decidedTextWithNoMissingCategoriesNamed() {
        let result = breakdown(decidedFraction: 0.63, semesterDecidedFraction: nil, categoriesMissingExpectedCount: [])
        #expect(GradeCourseCardView.decidedText(for: result)
                == "63% of what\u{2019}s posted is graded \u{00b7} semester share unknown")
    }

    // MARK: - headlineText

    @Test("headline: a computed percent is the primary line, with no secondary line")
    func headlineTextPercentCase() {
        let result = breakdown(decidedFraction: 0.5, semesterDecidedFraction: nil, currentPercent: 91.4)
        let headline = GradeCourseCardView.headlineText(for: result)
        #expect(headline.primary == "91.4%")
        #expect(headline.secondary == nil)
    }

    @Test("headline: nothing scored at all reads as plain 'no scores yet'")
    func headlineTextNoScoresCase() {
        let result = breakdown(decidedFraction: 0, semesterDecidedFraction: nil, currentPercent: nil, attendanceOnlyPercent: nil)
        let headline = GradeCourseCardView.headlineText(for: result)
        #expect(headline.primary == "no scores yet")
        #expect(headline.secondary == nil)
    }

    @Test("headline: every scored item is attendance-only -- 'no graded work yet' plus the attendance percent")
    func headlineTextAttendanceOnlyCase() {
        let result = breakdown(decidedFraction: 0, semesterDecidedFraction: nil, currentPercent: nil, attendanceOnlyPercent: 100)
        let headline = GradeCourseCardView.headlineText(for: result)
        #expect(headline.primary == "no graded work yet")
        #expect(headline.secondary == "attendance 100%")
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
