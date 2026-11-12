import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree overall")
struct DegreeOverallTests {
    private func course(_ code: String, credits: Double = 1) -> AuditCourse {
        AuditCourse(code: code, title: "t \(code)", credits: credits, termCode: nil, isInProgress: false, isTransfer: false)
    }

    private func rule(_ id: String, _ status: RuleStatus, applied: [String] = [],
                      advice: [String] = [], children: [AuditRule] = []) -> AuditRule {
        AuditRule(id: id, label: "rule \(id)", ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: nil, needCredits: nil, appliedCount: nil, appliedCredits: nil,
                  applied: applied.map { course($0) },
                  advice: advice.map { AdviceCourse(code: $0, title: nil, credits: 1) },
                  adviceText: nil, children: children)
    }

    private func audit(_ rules: [AuditRule], courses: [AuditCourse] = []) -> DegreeAudit {
        let block = AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil, rules: rules)
        return DegreeAudit(goals: DegreeGoals(), isWhatIf: false, percentComplete: nil, degreeLabel: nil,
                           catalogYearLabel: nil, blocks: [block], courses: courses,
                           fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func labeled(_ id: String, _ audit: DegreeAudit) -> DegreeLabeledAudit {
        DegreeLabeledAudit(degreeID: id, label: "deg \(id)", audit: audit)
    }

    private func plan(_ codes: [String]) -> DegreePlan {
        DegreePlan(terms: [PlannedTerm(termCode: "202710", courses: codes.map {
            PlannedCourse(code: $0, title: nil, credits: 1)
        })])
    }

    @Test("counts are Penn's rule counts added up")
    func counts() {
        let a = audit([rule("1", .met), rule("2", .open, children: [rule("2a", .inProgress)])])
        let b = audit([rule("1", .met), rule("2", .met), rule("3", .open), rule("4", .info)])
        let total = DegreeOverall.counts([labeled("a", a), labeled("b", b)])
        #expect(total.met == 3)
        #expect(total.inProgress == 1)
        #expect(total.open == 2)
        let none = DegreeOverall.counts([])
        #expect(none.met == 0 && none.inProgress == 0 && none.open == 0)
    }

    @Test("a course applied in two audits is shared once; applied in one is not; children and spacing count")
    func shared() {
        let a = audit([
            rule("1", .met, applied: ["ABCD 1000", "ABCD 2000"]),
            rule("2", .inProgress, children: [rule("2a", .met, applied: ["EFGH 3000"])]),
        ])
        let b = audit([
            rule("1", .met, applied: ["abcd1000"]),
            rule("2", .met, children: [rule("2a", .met, applied: ["EFGH 3000", "IJKL 4000"])]),
        ])
        #expect(DegreeOverall.sharedCourses([labeled("a", a), labeled("b", b)]) == ["ABCD 1000", "EFGH 3000"])
        #expect(DegreeOverall.sharedCourses([labeled("a", a)]).isEmpty)
    }

    @Test("a planned course lists every degree it fits, in audit order, and nothing when it fits none")
    func fits() {
        let a = audit([rule("1", .open, advice: ["ABCD 1000", "ABCD 3000"])])
        let b = audit([rule("1", .inProgress, advice: ["ABCD 3000", "EFGH 1000"])])
        let result = DegreeOverall.fits(
            plan: plan(["ABCD 1000", "abcd3000", "EFGH 1000", "ZZZZ 9999"]),
            audits: [labeled("a", a), labeled("b", b)])
        #expect(result["ABCD 1000"] == [DegreePlanFit(degreeLabel: "deg a", requirement: "rule 1")])
        #expect(result["ABCD 3000"]?.map(\.degreeLabel) == ["deg a", "deg b"])
        #expect(result["EFGH 1000"] == [DegreePlanFit(degreeLabel: "deg b", requirement: "rule 1")])
        #expect(result["ZZZZ 9999"] == nil)
    }

    @Test("with one audit the fit's label is empty")
    func singleAuditFits() {
        let a = audit([rule("1", .open, advice: ["ABCD 1000"])])
        let result = DegreeOverall.fits(plan: plan(["ABCD 1000"]), audits: [labeled("a", a)])
        #expect(result["ABCD 1000"] == [DegreePlanFit(degreeLabel: "", requirement: "rule 1")])
    }

    @Test("open groups keep the audits' order and leave out a degree with nothing open")
    func openGroups() {
        let a = audit([rule("1", .open, advice: ["ABCD 1000"])])
        let done = audit([rule("1", .met, advice: ["ABCD 1000"])])
        let c = audit([rule("9", .inProgress, advice: ["EFGH 1000"])])
        let groups = DegreeOverall.openGroups([labeled("a", a), labeled("d", done), labeled("c", c)])
        #expect(groups.map(\.degreeID) == ["a", "c"])
        #expect(groups.first?.requirements.count == 1)
        #expect(groups.first?.label == "deg a")
    }

    @Test("merged courses keep the first occurrence of a code")
    func merged() {
        let first = AuditCourse(code: "ABCD 1000", title: "first", credits: 1, termCode: nil, isInProgress: false, isTransfer: false)
        let second = AuditCourse(code: "abcd1000", title: "second", credits: 2, termCode: nil, isInProgress: false, isTransfer: false)
        let a = audit([], courses: [first])
        let b = audit([], courses: [second, course("EFGH 1000")])
        let merged = DegreeOverall.mergedCourses([labeled("a", a), labeled("b", b)])
        #expect(merged.map(\.code) == ["ABCD 1000", "EFGH 1000"])
        #expect(merged.first?.title == "first")
    }
}
