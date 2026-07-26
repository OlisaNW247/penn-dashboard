import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for docs/grades.md §13 — syllabus grading-scheme extraction.
///
/// Every fixture here is **synthetic**, written to match the shapes real
/// syllabi take. The repo rule against committing real Canvas/Gradescope data
/// applies to course documents too.
@Suite("Syllabus parsing")
struct SyllabusParserTests {

    // MARK: - Shapes that should parse

    @Test("a clean weight list parses at high confidence")
    func cleanList() throws {
        let text = """
        Grading
        Problem Sets: 40%
        Midterm: 25%
        Final Exam: 25%
        Participation: 10%
        """

        let scheme = try #require(SyllabusParser.parse(text))
        #expect(scheme.confidence == .high)
        #expect(scheme.categories.count == 4)
        #expect(abs(scheme.rawWeightSum - 100) < 0.001)
        #expect(scheme.categories.first?.name == "Problem Sets")
        #expect(abs((scheme.categories.first?.weightPercent ?? 0) - 40) < 0.001)
    }

    @Test("a flattened HTML table row parses (name and weight separated by a cell break)")
    func htmlTable() throws {
        let html = """
        <h2>Grading</h2>
        <table>
          <tr><td>Homework</td><td>30%</td></tr>
          <tr><td>Quizzes</td><td>20%</td></tr>
          <tr><td>Midterm</td><td>20%</td></tr>
          <tr><td>Final</td><td>30%</td></tr>
        </table>
        """

        let text = SyllabusTextExtractor.text(fromHTML: html)
        let scheme = try #require(SyllabusParser.parse(text))
        #expect(scheme.categories.count == 4)
        #expect(scheme.confidence == .high)
    }

    @Test("percent-first ordering parses")
    func percentFirst() throws {
        let text = """
        Course grades are determined as follows:
        30% - Problem Sets
        20% - Labs
        20% - Midterm Exam
        30% - Final Exam
        """

        let scheme = try #require(SyllabusParser.parse(text))
        #expect(scheme.categories.count == 4)
        #expect(scheme.categories.contains { $0.name == "Labs" })
    }

    @Test("bulleted prose with dot leaders parses")
    func bulletedProse() throws {
        let text = """
        Grade Breakdown
        • Weekly Reading Responses ......... 15%
        • Class Participation .............. 10%
        • Two Papers ....................... 45%
        • Final Project .................... 30%
        """

        let scheme = try #require(SyllabusParser.parse(text))
        #expect(scheme.categories.count == 4)
        #expect(abs(scheme.rawWeightSum - 100) < 0.001)
    }

    @Test("a sum in the 90-110 band parses at medium confidence")
    func mediumConfidence() throws {
        let text = """
        Homework 30%
        Midterm 30%
        Final 35%
        """

        let scheme = try #require(SyllabusParser.parse(text))
        #expect(scheme.confidence == .medium)
        #expect(abs(scheme.rawWeightSum - 95) < 0.001)
        // Normalization scales the shortfall away for the weight editor.
        let normalizedSum = scheme.normalizedCategories.reduce(0) { $0 + $1.weightPercent }
        #expect(abs(normalizedSum - 100) < 0.05)
    }

    @Test("extra credit pushing the total slightly over 100 still parses")
    func slightlyOver() throws {
        let text = """
        Problem Sets 40%
        Exams 55%
        Extra Credit 10%
        """

        let scheme = try #require(SyllabusParser.parse(text))
        #expect(abs(scheme.rawWeightSum - 105) < 0.001)
    }

    // MARK: - Shapes that must NOT parse

    @Test("a syllabus with no weights yields nothing rather than a guess")
    func noWeights() {
        let text = """
        Course Description
        This course covers algorithms and data structures. Attendance is
        expected. Late work is not accepted without prior arrangement.
        """

        #expect(SyllabusParser.parse(text) == nil)
    }

    @Test("percentages that aren't a grading scheme are rejected by the sum gate")
    func decoyPercentages() {
        let text = """
        Attendance below 80% will affect your participation grade.
        Students scoring above 90% on the diagnostic may skip the review session.
        The pass rate last year was 95%.
        """

        #expect(SyllabusParser.parse(text) == nil)
    }

    @Test("a 'Total 100%' row does not double the sum and blow the gate")
    func totalRowIgnored() throws {
        let text = """
        Homework 40%
        Midterm 25%
        Final 35%
        Total 100%
        """

        let scheme = try #require(SyllabusParser.parse(text))
        #expect(scheme.categories.count == 3)
        #expect(!scheme.categories.contains { $0.name.lowercased() == "total" })
        #expect(scheme.confidence == .high)
    }

    @Test("comparison phrasing is not read as a category")
    func comparisonPhrasingRejected() {
        #expect(!SyllabusParser.isPlausibleCategoryName("attendance below"))
        #expect(!SyllabusParser.isPlausibleCategoryName("students scoring at least"))
        #expect(SyllabusParser.isPlausibleCategoryName("Problem Sets"))
    }

    @Test("a single category is not enough to be a grading scheme")
    func singleCategoryRejected() {
        #expect(SyllabusParser.parse("Final Exam: 100%") == nil)
    }

    // MARK: - Drop rules, counts, curve

    @Test("drop-lowest prose attaches to the right category")
    func dropRules() throws {
        let text = """
        Problem Sets 40%
        Quizzes 20%
        Final 40%

        Your lowest two quizzes are dropped at the end of the term.
        """

        let scheme = try #require(SyllabusParser.parse(text))
        let quizzes = try #require(scheme.categories.first { $0.name == "Quizzes" })
        #expect(quizzes.dropLowest == 2)
        let psets = try #require(scheme.categories.first { $0.name == "Problem Sets" })
        #expect(psets.dropLowest == 0)
    }

    @Test("an unqualified drop means one")
    func singleDrop() throws {
        let text = """
        Homework 50%
        Final 50%

        The lowest homework score will be dropped.
        """

        let scheme = try #require(SyllabusParser.parse(text))
        let homework = try #require(scheme.categories.first { $0.name == "Homework" })
        #expect(homework.dropLowest == 1)
    }

    @Test("expected item counts are read from prose — the thing Canvas cannot tell us")
    func expectedCounts() throws {
        let text = """
        Problem Sets 40%
        Exams 60%

        There will be 10 problem sets over the course of the semester.
        """

        let scheme = try #require(SyllabusParser.parse(text))
        let psets = try #require(scheme.categories.first { $0.name == "Problem Sets" })
        #expect(psets.expectedItemCount == 10)
    }

    @Test("number words count too")
    func numberWords() throws {
        let text = """
        Papers 60%
        Participation 40%

        You will write four papers this semester.
        """

        let scheme = try #require(SyllabusParser.parse(text))
        let papers = try #require(scheme.categories.first { $0.name == "Papers" })
        #expect(papers.expectedItemCount == 4)
    }

    @Test("a weight sentence is not mistaken for a count")
    func weightIsNotACount() throws {
        let text = """
        Problem Sets 40%
        Final 60%
        """

        let scheme = try #require(SyllabusParser.parse(text))
        let psets = try #require(scheme.categories.first { $0.name == "Problem Sets" })
        #expect(psets.expectedItemCount == nil)
    }

    @Test("curve language is detected, boilerplate is not")
    func curveDetection() {
        #expect(SyllabusParser.mentionsCurve("Final grades may be curved at the end of the term."))
        #expect(SyllabusParser.mentionsCurve("Cutoffs are at the instructor's discretion."))
        #expect(!SyllabusParser.mentionsCurve("This syllabus is subject to change."))
        #expect(!SyllabusParser.mentionsCurve("Problem sets are due on Fridays."))
    }

    // MARK: - Cutoffs

    @Test("a letter cutoff table is read and marked custom")
    func cutoffTable() throws {
        let text = """
        Grading Scale
        A  93-100
        A- 90-92
        B+ 87-89
        B  83-86
        C  73-82
        """

        let cutoffs = try #require(SyllabusParser.cutoffs(in: text))
        #expect(cutoffs.isCustom)
        #expect(cutoffs.letter(forPercent: 91) == "A-")
        #expect(cutoffs.letter(forPercent: 95) == "A")
    }

    @Test("'A ≥ 90' style cutoffs are read")
    func greaterThanCutoffs() throws {
        let text = """
        A: 90 and above
        B: 80 and above
        C: 70 and above
        D: 60 and above
        """

        let cutoffs = try #require(SyllabusParser.cutoffs(in: text))
        #expect(cutoffs.letter(forPercent: 85) == "B")
        #expect(cutoffs.letter(forPercent: 90) == "A")
    }

    @Test("a non-monotonic table is a misread and is rejected")
    func nonMonotonicRejected() {
        let text = """
        A 70
        B 85
        C 95
        """

        #expect(SyllabusParser.cutoffs(in: text) == nil)
    }

    @Test("too few bands is not a cutoff table")
    func tooFewBands() {
        #expect(SyllabusParser.cutoffs(in: "You need an A: 93 or better.\nB is 85.") == nil)
    }

    // MARK: - Realistic end-to-end

    @Test("a full realistic syllabus parses weights, drops, counts, cutoffs and curve together")
    func fullSyllabus() throws {
        let text = """
        CIS 1210: Data Structures and Algorithms

        Course Description
        An introduction to algorithm design and analysis.

        Grading
        Problem Sets       40%
        Midterm Exam       25%
        Final Exam         25%
        Participation      10%

        There will be 8 problem sets. The lowest two problem sets are dropped.

        Grading Scale
        A   93-100
        A-  90-92
        B+  87-89
        B   83-86
        B-  80-82

        Final grades may be curved upward at the instructor's discretion.
        """

        let scheme = try #require(SyllabusParser.parse(text))
        #expect(scheme.confidence == .high)
        #expect(scheme.categories.count == 4)
        #expect(scheme.mentionsCurve)

        let psets = try #require(scheme.categories.first { $0.name == "Problem Sets" })
        #expect(psets.expectedItemCount == 8)
        #expect(psets.dropLowest == 2)
        #expect(!psets.evidence.isEmpty)

        let cutoffs = try #require(scheme.cutoffs)
        #expect(cutoffs.isCustom)
        #expect(cutoffs.letter(forPercent: 91.4) == "A-")
    }
}
