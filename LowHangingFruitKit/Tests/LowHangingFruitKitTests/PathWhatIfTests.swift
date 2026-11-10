import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Path@Penn what-if rules")
struct PathWhatIfTests {
    // All codes are invented.
    private static func demoDegree(
        degc: String = "BSX", coll: String = "EC", major: String = "AAAA", conc: String = "NCON",
        minor: String = "", program: String = "XX_BA"
    ) -> StudentDegree {
        var raw: [String: String] = [
            "degc": degc, "levl": "UG", "coll": coll, "major": major, "conc": conc,
            "program": program, "ctlg": "202610",
        ]
        if !minor.isEmpty { raw["minor"] = minor }
        return StudentDegree(raw: raw)
    }

    private static func entry(
        code: String = "DEMO-1", degree: String = "BSX", level: String = "UG", major: String = "",
        minor: String = "", concentration: String = "", college: String = "EC", sis: String = "XX_BA",
        minorSis: [String] = []
    ) -> PathProgramInfo {
        PathProgramInfo(
            code: code, name: "Demo", type: "major", level: level, degree: degree, major: major,
            minor: minor, concentration: concentration, college: college, sisProgram: sis,
            minorSisPrograms: minorSis)
    }

    @Test("a record entry is read from its strings: comma majors, NCON dropped")
    func fromRaw() {
        let degree = StudentDegree(raw: [
            "degc": "BSX", "levl": "UG", "coll": "EC", "major": "AAAA, BBBB,", "conc": "NCON",
            "program": "XX_BA", "ctlg": "202610", "minor": "MMMM",
        ])
        #expect(degree.majors == ["AAAA", "BBBB"])
        #expect(degree.concentrations.isEmpty)
        #expect(degree.minors == ["MMMM"])
        #expect(degree.catalogTerm == "202610")
        #expect(degree.id == "EC|BSX|AAAA,BBBB|XX_BA")
        let goals = degree.goals
        #expect(goals.school == "UG")
        #expect(goals.college == "EC")
        #expect(goals.degree == "BSX")
        #expect(goals.program == "XX_BA")
        #expect(goals.majors == ["AAAA", "BBBB"])
        #expect(goals.catalogYear == "202610")
    }

    @Test("missing keys become empty values and nil goals")
    func emptyRaw() {
        let degree = StudentDegree(raw: [:])
        #expect(degree.majors.isEmpty)
        #expect(degree.catalogTerm == nil)
        #expect(degree.goals.school == nil)
        #expect(degree.goals.degree == nil)
    }

    @Test("switch to: needs a degree that is not a minor, and a level")
    func newProgram() {
        let plans = PathWhatIf.plans(for: Self.entry(major: "ZZZZ", concentration: "CCCC"), current: [])
        #expect(plans.map(\.change) == [.newProgram])
        let info = plans[0].degreeInfo
        #expect(info["degc"] == "BSX")
        #expect(info["levl"] == "UG")
        #expect(info["coll"] == "EC")
        #expect(info["major"] == "ZZZZ")
        #expect(info["conc"] == "CCCC")
        #expect(info["program"] == "XX_BA")
        #expect(plans[0].goals.majors == ["ZZZZ"])
        #expect(plans[0].id == "newProgram|DEMO-1")
    }

    @Test("a MINOR degree code is never a new program, and no level means no plan")
    func newProgramNegatives() {
        #expect(PathWhatIf.plans(for: Self.entry(degree: "MINOR", major: "ZZZZ"), current: []).isEmpty)
        #expect(PathWhatIf.plans(for: Self.entry(level: "", major: "ZZZZ"), current: []).isEmpty)
    }

    @Test("switch to leaves out keys whose value is empty")
    func newProgramOmitsEmpty() {
        let plans = PathWhatIf.plans(for: Self.entry(college: "", sis: ""), current: [])
        let info = plans[0].degreeInfo
        #expect(Set(info.keys) == ["degc", "levl"])
    }

    @Test("add major: same degree and college, and the major is new")
    func addMajor() {
        let current = [Self.demoDegree()]
        let plans = PathWhatIf.plans(for: Self.entry(major: "BBBB"), current: current)
        let plan = plans.first { $0.change == .addMajor }
        #expect(plan?.degreeInfo["major"] == "AAAA,BBBB")
        #expect(plan?.degreeInfo["degc"] == "BSX")
        #expect(plan?.goals.majors == ["AAAA", "BBBB"])
    }

    @Test("add major refuses another degree, another college, and a major already held")
    func addMajorNegatives() {
        let current = [Self.demoDegree()]
        let otherDegree = PathWhatIf.plans(for: Self.entry(degree: "BAX", major: "BBBB"), current: current)
        #expect(!otherDegree.contains { $0.change == .addMajor })
        let otherCollege = PathWhatIf.plans(for: Self.entry(major: "BBBB", college: "XC"), current: current)
        #expect(!otherCollege.contains { $0.change == .addMajor })
        let held = PathWhatIf.plans(for: Self.entry(major: "AAAA"), current: current)
        #expect(!held.contains { $0.change == .addMajor })
    }

    @Test("add minor: the entry lists the student's program, and the code is new")
    func addMinor() {
        let current = [Self.demoDegree()]
        let plans = PathWhatIf.plans(for: Self.entry(degree: "MINOR", major: "MMMM", minorSis: ["XX_BA", "YY_BA"]), current: current)
        #expect(plans.map(\.change) == [.addMinor])
        #expect(plans[0].degreeInfo["minor"] == "MMMM")
        #expect(plans[0].goals.minors == ["MMMM"])
    }

    @Test("add minor needs a program match and refuses a code already a major or minor")
    func addMinorNegatives() {
        let current = [Self.demoDegree(minor: "NNNN")]
        let noMatch = PathWhatIf.plans(for: Self.entry(degree: "MINOR", major: "MMMM", minorSis: ["YY_BA"]), current: current)
        #expect(noMatch.isEmpty)
        let asMajor = PathWhatIf.plans(for: Self.entry(degree: "MINOR", major: "AAAA", minorSis: ["XX_BA"]), current: current)
        #expect(asMajor.isEmpty)
        let asMinor = PathWhatIf.plans(for: Self.entry(degree: "MINOR", major: "NNNN", minorSis: ["XX_BA"]), current: current)
        #expect(asMinor.isEmpty)
        let noList = PathWhatIf.plans(for: Self.entry(degree: "MINOR", major: "MMMM"), current: current)
        #expect(noList.isEmpty)
    }

    @Test("add concentration replaces NCON and needs a major the student holds")
    func addConcentration() {
        let current = [Self.demoDegree()]
        let plans = PathWhatIf.plans(for: Self.entry(major: "AAAA", concentration: "CCCC"), current: current)
        let plan = plans.first { $0.change == .addConcentration }
        #expect(plan?.degreeInfo["conc"] == "CCCC")
        #expect(plan?.goals.concentrations == ["CCCC"])

        let wrongMajor = PathWhatIf.plans(for: Self.entry(major: "BBBB", concentration: "CCCC"), current: current)
        #expect(!wrongMajor.contains { $0.change == .addConcentration })
        let held = PathWhatIf.plans(for: Self.entry(major: "AAAA", concentration: "CCCC"), current: [Self.demoDegree(conc: "CCCC")])
        #expect(!held.contains { $0.change == .addConcentration })
    }

    @Test("with two degrees the last qualifying one wins, as the page's loop does")
    func lastWins() {
        let first = Self.demoDegree(program: "ONE_BA")
        let second = Self.demoDegree(program: "TWO_BA")
        let plans = PathWhatIf.plans(for: Self.entry(major: "BBBB"), current: [first, second])
        let plan = plans.first { $0.change == .addMajor }
        #expect(plan?.degreeInfo["program"] == "TWO_BA")
        #expect(plans.filter { $0.change == .addMajor }.count == 1)
    }

    @Test("plans come in the order minor, concentration, major, switch")
    func order() {
        let current = [Self.demoDegree()]
        let program = Self.entry(major: "AAAA", concentration: "CCCC", minorSis: ["XX_BA"])
        let both = PathWhatIf.plans(for: program, current: current)
        // The major is held, so no add-major and no add-minor (a held major).
        #expect(both.map(\.change) == [.addConcentration, .newProgram])

        let rich = PathWhatIf.plans(for: Self.entry(major: "BBBB", concentration: "CCCC", minorSis: ["XX_BA"]), current: current)
        #expect(rich.map(\.change) == [.addMinor, .addMajor, .newProgram])
    }

    @Test("labels are lowercase UI copy")
    func labels() {
        #expect(PathWhatIfChange.newProgram.label == "switch to")
        #expect(PathWhatIfChange.addMajor.label == "add major")
        #expect(PathWhatIfChange.addMinor.label == "add minor")
        #expect(PathWhatIfChange.addConcentration.label == "add concentration")
        #expect(PathWhatIfChange.allCases.count == 4)
    }
}
