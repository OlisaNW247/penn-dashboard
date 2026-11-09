import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree what-if")
struct DegreeWhatIfTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func course(_ code: String, term: String? = "202430") -> AuditCourse {
        AuditCourse(code: code, title: code, credits: 1, termCode: term, isInProgress: false, isTransfer: false)
    }

    private func rule(_ id: String, _ status: RuleStatus, applied: [AuditCourse] = [], children: [AuditRule] = []) -> AuditRule {
        AuditRule(
            id: id, label: id, ruleType: "Course", percentComplete: nil, status: status, needCourses: nil,
            needCredits: nil, appliedCount: nil, appliedCredits: nil, applied: applied, advice: [],
            adviceText: nil, children: children)
    }

    private func block(_ type: String, _ value: String, _ rules: [AuditRule]) -> AuditBlock {
        AuditBlock(id: "\(type):\(value)", type: type, value: value, title: value, percentComplete: nil, rules: rules)
    }

    private func audit(_ goals: DegreeGoals, blocks: [AuditBlock], courses: [AuditCourse], whatIf: Bool) -> DegreeAudit {
        DegreeAudit(goals: goals, isWhatIf: whatIf, percentComplete: nil, degreeLabel: nil, catalogYearLabel: nil,
                    blocks: blocks, courses: courses, fetchedAt: Self.now)
    }

    @Test("summary counts the target, lists already-counting courses once, and finds new blocks")
    func summary() {
        let owned = [course("CIS 1200"), course("MATH 1400", term: "202510"), course("ECON 0100", term: nil), course("CIS 1200", term: "202530")]
        let current = audit(DegreeGoals(degree: "BSE", majors: ["CIS"]),
                            blocks: [block("MAJOR", "CIS", [rule("a", .met)])], courses: owned, whatIf: false)
        let target = audit(
            DegreeGoals(degree: "BSE", majors: ["CIS"], minors: ["MATH"]),
            blocks: [
                block("MAJOR", "cis", [rule("b", .met, applied: [course("CIS 1200")])]),
                block("MINOR", "MATH", [
                    rule("c", .inProgress, children: [rule("d", .open, applied: [course("MATH 1400", term: "202510")])]),
                    rule("e", .info),
                ]),
            ],
            courses: owned, whatIf: true)
        let summary = DegreeWhatIf.summarize(current: current, target: target)
        #expect(summary.met == 1)
        #expect(summary.inProgress == 1)
        #expect(summary.open == 1)
        #expect(summary.alreadyCounting.map(\.code) == ["CIS 1200", "MATH 1400"])
        #expect(summary.alreadyCounting[0].termCode == "202430")
        #expect(summary.newBlocks.map(\.value) == ["MATH"])
        #expect(summary.target == target.goals)
    }

    @Test("no current audit: the target's own courses stand in and there are no new blocks")
    func noCurrent() {
        let target = audit(DegreeGoals(), blocks: [block("MAJOR", "X", [rule("a", .met, applied: [course("CIS 1200")])])],
                           courses: [course("CIS 1200"), course("HIST 0100")], whatIf: true)
        let summary = DegreeWhatIf.summarize(current: nil, target: target)
        #expect(summary.alreadyCounting.map(\.code) == ["CIS 1200"])
        #expect(summary.newBlocks.isEmpty)
    }

    @Test("headline: added minor, added major and concentration, and a switch")
    func headline() {
        let names = ["MATH": "Mathematics", "ECON": "Economics", "BA": "BA", "AI": "Artificial Intelligence"]
        let current = DegreeGoals(degree: "BSE", majors: ["CIS"])
        #expect(DegreeWhatIf.headline(current: current, target: DegreeGoals(degree: "BSE", majors: ["CIS"], minors: ["MATH"]), descriptions: names) == "+ mathematics minor")
        #expect(DegreeWhatIf.headline(current: current, target: DegreeGoals(degree: "BSE", majors: ["CIS", "ECON"]), descriptions: names) == "+ economics major")
        #expect(DegreeWhatIf.headline(current: current, target: DegreeGoals(degree: "BSE", majors: ["CIS"], concentrations: ["AI"], minors: ["MATH"]), descriptions: names)
                == "+ artificial intelligence concentration + mathematics minor")
        #expect(DegreeWhatIf.headline(current: current, target: DegreeGoals(degree: "BA", majors: ["ECON"]), descriptions: names) == "switch to economics, ba")
        #expect(DegreeWhatIf.headline(current: nil, target: DegreeGoals(degree: "BA", majors: ["ECON"]), descriptions: names) == "switch to economics, ba")
        // Dropping the current major is a switch even on the same degree.
        #expect(DegreeWhatIf.headline(current: current, target: DegreeGoals(degree: "BSE", majors: ["ECON"]), descriptions: names) == "switch to economics, bse")
        // Identical goals: nothing added, so it reads as a switch to the same thing.
        #expect(DegreeWhatIf.headline(current: current, target: current, descriptions: [:]) == "switch to cis, bse")
    }

    @Test("goals title: lowercase, descriptions then codes, majors joined")
    func title() {
        let goals = DegreeGoals(program: "EU_BSE", degree: "BSE", majors: ["CIS", "MATH"])
        #expect(goals.title(descriptions: ["CIS": "Computer Science"]) == "computer science + math, bse")
        #expect(DegreeGoals(program: "EU_BSE").title(descriptions: [:]) == "eu_bse")
        #expect(DegreeGoals().title(descriptions: [:]) == "")
    }
}
