import Foundation
import Testing
import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The degree screens' copy rules (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md):
/// lowercase, no verdict words, the official audit always named, and every
/// status sentence read from `DegreeStatus.line` rather than written here.
@Suite("Degree copy")
struct DegreeCopyTests {
    private static let files = ["DegreeProgressView.swift", "DegreeWhatIfSheet.swift", "DegreePlanView.swift", "DegreeSemesterTable.swift"]

    private func uiSource(_ filename: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        return try String(contentsOf: sources.appendingPathComponent(filename), encoding: .utf8)
    }

    @Test("no verdict words anywhere in the degree views")
    func noVerdictWords() throws {
        for file in Self.files {
            let source = try uiSource(file).lowercased()
            for word in ["graduate", "on track", "eligible"] {
                #expect(!source.contains(word), "\(file) contains \(word)")
            }
        }
    }

    @Test("the title beside the ring never carries the catalog term")
    func noCatalogTerm() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(!source.contains("catalogYearLabel"))
    }

    @Test("the bars have a three-word key: done, in progress, left")
    func legend() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("DegreeLegend()"))
        for word in ["\"done\"", "\"in progress\"", "\"left\""] {
            #expect(source.contains(word), "legend is missing \(word)")
        }
    }

    @Test("the footer names the official audit")
    func footer() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("path@penn's reading · official audit ↗"))
        #expect(source.contains("PathPage.officialAuditURL"))
    }

    @Test("no capitalised literal in a visible string")
    func lowercaseLiterals() throws {
        let pattern = try NSRegularExpression(pattern: #"(Text|Button|Link|TextField|Label)\("[A-Z]"#)
        for file in Self.files {
            let source = try uiSource(file)
            let range = NSRange(source.startIndex..., in: source)
            #expect(pattern.firstMatch(in: source, range: range) == nil, "\(file) has a capitalised string")
        }
    }

    @Test("the status sentence comes from DegreeStatus.line, not the view")
    func statusFromLine() throws {
        let source = try uiSource("DegreeProgressView.swift")
        #expect(source.contains("degreeStatus.line(now:"))
        for phrase in ["reading path@penn…", "approve the duo push", "couldn't read path@penn"] {
            #expect(!source.contains(phrase), "\(phrase) belongs to DegreeStatus")
        }
    }

    @Test("the what-if sheet is a searchable list wired to the three data calls")
    func sheetIsASearchableList() throws {
        let source = try uiSource("DegreeWhatIfSheet.swift")
        #expect(source.contains("search programs"))
        #expect(source.contains("loadDegreePrograms"))
        #expect(source.contains("degreeWhatIfPlans"))
        #expect(source.contains("runWhatIf("))
        #expect(source.contains("degreeStatus.line(now:"))
    }

    @Test("the plan view carries its four fixed phrases")
    func planPhrases() throws {
        // The table's phrases moved with it to DegreeSemesterTable.swift; the
        // add sheet stayed in DegreePlanView.swift.
        let source = try uiSource("DegreePlanView.swift") + uiSource("DegreeSemesterTable.swift")
        for phrase in ["+ course", "+ semester", "fits · ", "still open on your audit"] {
            #expect(source.contains(phrase), "the plan views are missing \(phrase)")
        }
    }

    @Test("the strip has a full view button and the page hosts the table in page layout")
    func fullView() throws {
        let source = try uiSource("DegreeSemesterTable.swift")
        #expect(source.contains("struct DegreeSemesterPage"))
        #expect(source.contains("Text(\"full view\")"))
        #expect(source.contains(".accessibilityLabel(\"full view\")"))
        #expect(source.contains("DegreeSemesterTable(audits: audits, layout: .page)"))
        #expect(source.contains("Text(\"semesters\")"))
    }

    @Test("the combined view: both chip, Penn's counts, shared courses, no combined percent")
    func combinedView() throws {
        let progress = try uiSource("DegreeProgressView.swift")
        #expect(progress.contains("Text(\"both\")"))
        #expect(progress.contains(".accessibilityLabel(\"both degrees\")"))
        #expect(progress.contains("DegreeOverall.counts("))
        #expect(progress.contains("DegreeOverall.sharedCourses("))
        #expect(progress.contains("ensureAllDegreeAudits()"))
        #expect(!progress.lowercased().contains("average"))
        #expect(try uiSource("DegreeSemesterTable.swift").contains("DegreeOverall.fits("))
        #expect(try uiSource("DegreePlanView.swift").contains("DegreeOverall.openGroups("))
    }

    @Test("a fits line names the degree only when there is one to name")
    func fitLine() {
        let single = DegreePlanFit(degreeLabel: "", requirement: "Free Electives")
        #expect(DegreeSemesterTable.fitLine(single) == "fits · free electives")
        let dual = DegreePlanFit(degreeLabel: "finance", requirement: "Core Math")
        #expect(DegreeSemesterTable.fitLine(dual) == "fits · finance · core math")
    }
}
