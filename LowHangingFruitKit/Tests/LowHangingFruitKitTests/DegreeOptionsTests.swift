import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree options")
struct DegreeOptionsTests {
    private static let catalogue: [PathProgramListing] = [
        PathProgramListing(code: "FNCS-BS", title: "Finance BS"),
        PathProgramListing(code: "ACCT-BS", title: "Accounting BS"),
        PathProgramListing(code: "ACCT-MBA-NCON", title: "Accounting MBA (No Concentration)"),
        PathProgramListing(code: "CSCI-BSE-NCON", title: "Computer Science BSE (No Concentration)"),
        PathProgramListing(code: "CMPE-BSE", title: "Computer Engineering BSE"),
        PathProgramListing(code: "MATH-MINOR", title: "Mathematics Minor"),
        PathProgramListing(code: "EMBA-MBA-BSAI", title: "Wharton MBA MBA (AI for Business)"),
    ]

    private func degree(_ raw: [String: String]) -> StudentDegree { StudentDegree(raw: raw) }

    @Test("a BS student gets the other BS programs, in short-title order")
    func bachelorOfScience() {
        let own = degree(["degc": "BS", "coll": "WU", "levl": "UG", "major": "WUNG"])
        let rows = DegreeOptions.listings(for: own, in: Self.catalogue)
        #expect(rows.map(\.code) == ["ACCT-BS", "FNCS-BS"])
    }

    @Test("a BSE student with major CSCI gets the other engineering rows, not their own program under either spelling")
    func engineering() {
        let own = degree(["degc": "BSE", "coll": "EU", "levl": "UG", "major": "CSCI"])
        let rows = DegreeOptions.listings(for: own, in: Self.catalogue)
        #expect(rows.map(\.code) == ["CMPE-BSE"])
        // Their own major with a real concentration is a different program.
        let withConcentration = Self.catalogue + [
            PathProgramListing(code: "CSCI-BSE-ARIN", title: "Computer Science BSE (Artificial Intelligence)")
        ]
        #expect(DegreeOptions.listings(for: own, in: withConcentration).map(\.code) == ["CMPE-BSE", "CSCI-BSE-ARIN"])
    }

    @Test("a no-concentration row is dropped when the bare row is listed too")
    func noConcentrationTwin() {
        let own = degree(["degc": "BSE", "major": "CSCI"])
        let both = [
            PathProgramListing(code: "ARIN-BSE", title: "Artificial Intelligence BSE"),
            PathProgramListing(code: "ARIN-BSE-NCON", title: "Artificial Intelligence BSE (No Concentration)"),
        ]
        #expect(DegreeOptions.listings(for: own, in: both).map(\.code) == ["ARIN-BSE"])
        #expect(DegreeOptions.listings(for: own, in: [both[1]]).map(\.code) == ["ARIN-BSE-NCON"])
    }

    @Test("the student's own two-part row is not an option")
    func ownRowDropped() {
        let own = degree(["degc": "BS", "major": "FNCS"])
        let rows = DegreeOptions.listings(for: own, in: Self.catalogue)
        #expect(rows.map(\.code) == ["ACCT-BS"])
    }

    @Test("an empty degree code lists nothing")
    func emptyDegree() {
        #expect(DegreeOptions.listings(for: degree(["major": "WUNG"]), in: Self.catalogue).isEmpty)
    }

    @Test("short titles drop the degree word and the no-concentration tail")
    func shortTitles() {
        func short(_ code: String, _ title: String) -> String {
            DegreeOptions.shortTitle(PathProgramListing(code: code, title: title))
        }
        #expect(short("FNCS-BS", "Finance BS") == "finance")
        #expect(short("CSCI-BSE-NCON", "Computer Science BSE (No Concentration)") == "computer science")
        #expect(short("EMBA-MBA-BSAI", "Wharton MBA MBA (AI for Business)") == "wharton mba (ai for business)")
        #expect(short("XXXX-BS", "Plain Title") == "plain title")
        #expect(short("XXXX-BS", "   ") == "xxxx-bs")
    }

    @Test("the heading is concentrations for Wharton and majors otherwise")
    func heading() {
        #expect(DegreeOptions.heading(college: "WU") == "concentrations")
        #expect(DegreeOptions.heading(college: "wu") == "concentrations")
        #expect(DegreeOptions.heading(college: "EU") == "majors")
        #expect(DegreeOptions.heading(college: nil) == "majors")
    }

    @Test("plan is the switch-to change by the page's rule, and nil without a level")
    func plan() {
        let current = [degree(["degc": "BS", "coll": "WU", "levl": "UG", "program": "WU_BS", "major": "WUNG"])]
        func info(level: String) -> PathProgramInfo {
            PathProgramInfo(
                code: "FNCS-BS", name: "Finance BS", type: "major", level: level, degree: "BS",
                major: "FNCS", minor: "", concentration: "", college: "WU", sisProgram: "WU_BS",
                minorSisPrograms: [])
        }
        let plan = DegreeOptions.plan(for: info(level: "UG"), current: current)
        #expect(plan?.change == .newProgram)
        #expect(plan?.programCode == "FNCS-BS")
        #expect(plan?.degreeInfo["major"] == "FNCS")
        #expect(DegreeOptions.plan(for: info(level: ""), current: current) == nil)
    }

    @Test("the score key joins the degree and the program")
    func scoreKey() {
        #expect(DegreeOptions.scoreKey(degreeID: "WU|BS|WUNG|WU_BS", programCode: "FNCS-BS") == "WU|BS|WUNG|WU_BS|FNCS-BS")
    }
}
