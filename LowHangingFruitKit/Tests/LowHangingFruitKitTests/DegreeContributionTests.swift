import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree contribution")
struct DegreeContributionTests {
    private let a = "ABCD 1000"
    private let b = "ABCD 2000"
    private let c = "ABCD 3000"

    private func rule(
        _ id: String, _ status: RuleStatus, advice: [String] = [], label: String? = nil,
        needCourses: Int? = nil
    ) -> AuditRule {
        AuditRule(id: id, label: label ?? "rule \(id)", ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: needCourses, needCredits: nil,
                  appliedCount: nil, appliedCredits: nil,
                  applied: [],
                  advice: advice.map { AdviceCourse(code: $0, title: nil, credits: 1) },
                  adviceText: nil, children: [])
    }

    private func block(_ rules: [AuditRule]) -> AuditBlock {
        AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil, rules: rules)
    }

    private func audit(_ rules: [AuditRule], percent: Double? = nil, courses: [AuditCourse] = []) -> DegreeAudit {
        DegreeAudit(goals: DegreeGoals(), isWhatIf: false, percentComplete: percent, degreeLabel: nil,
                    catalogYearLabel: nil, blocks: [block(rules)], courses: courses,
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

    private func close(_ x: Double, _ y: Double) -> Bool { abs(x - y) < 1e-9 }

    @Test("counted holds a course laid with room; overflow, unplaced absent; empty label uses the block title")
    func countedMap() {
        let withLabel = audit([rule("r1", .open, advice: [a, b])])
        let p = DegreeProjection.make(plan: plan([a, b, "zzzz9999"]), audit: withLabel)
        // r1 needs one course: a takes it, b is overflow, zzzz is unplaced.
        #expect(p.counted == [a: "rule r1"])
        let unlabeled = audit([rule("r1", .open, advice: [a, b], label: "")])
        let q = DegreeProjection.make(plan: plan([a, b]), audit: unlabeled)
        #expect(q.counted == [a: "Major"])
        #expect(DegreeProjection.empty.counted.isEmpty)
    }

    @Test("baseFraction from Penn's percent, from rule counts, and with no rules")
    func baseFractions() {
        #expect(close(DegreeProjection.baseFraction(of: audit([], percent: 67)), 0.67))
        #expect(close(DegreeProjection.baseFraction(of: audit([], percent: 250)), 1))
        let rules = [
            rule("m", .met), rule("ip", .inProgress),
            rule("o1", .open, advice: [a]), rule("o2", .open, advice: [b]),
        ]
        // 1 met of 4 countable rules.
        #expect(close(DegreeProjection.baseFraction(of: audit(rules)), 0.25))
        #expect(DegreeProjection.baseFraction(of: audit([])) == 0)
    }

    @Test("planned: one planned course is worth the whole ring gain of the plan")
    func plannedPoints() {
        let rules = [rule("m", .met), rule("r1", .open, advice: [a]), rule("r2", .open, advice: [b])]
        let result = DegreeContribution.planned(plan: plan([a]), audits: [labeled("x", audit(rules))])
        let gains = result[a]
        #expect(gains?.count == 1)
        #expect(gains?.first?.degreeLabel == "")
        #expect(gains?.first?.degreeID == "x")
        #expect(gains?.first?.requirement == "rule r1")
        // base = 1 met / 3 rules = 1/3; with a: openFill 1 over 2 open rules = 1/2;
        // ringGain = (1 - 1/3) * 1/2 = 1/3; without the plan 0. Points = 100/3.
        #expect(close(gains?.first?.points ?? -1, 100.0 / 3))
    }

    @Test("planned: an overflow course and an unplaced course get no entry")
    func plannedSkipsOverflowAndUnplaced() {
        let result = DegreeContribution.planned(
            plan: plan([a, b, "zzzz9999"]),
            audits: [labeled("x", audit([rule("r1", .open, advice: [a, b])]))])
        // r1 needs one course: a counts, b overflows, zzzz lists nowhere.
        #expect(Set(result.keys) == [a])
    }

    @Test("planned with two audits: one gain per audit that counts it, in audits order")
    func plannedTwoAudits() {
        let first = labeled("a", audit([rule("r1", .open, advice: [a])]))
        let second = labeled("b", audit([rule("r2", .open, advice: [a])]))
        let gains = DegreeContribution.planned(plan: plan([a]), audits: [first, second])[a]
        #expect(gains?.map(\.degreeLabel) == ["deg a", "deg b"])
        #expect(gains?.map(\.requirement) == ["rule r1", "rule r2"])
        // Each audit: base 0, its single open rule filled, share 1: 100 points.
        #expect(close(gains?[0].points ?? -1, 100))
        #expect(close(gains?[1].points ?? -1, 100))
    }

    @Test("gains(for:) is empty for a code nothing lists or one already planned, and matches typed codes")
    func gainsFor() {
        let target = [labeled("x", audit([rule("r1", .open, advice: [a]), rule("r2", .open, advice: [b])]))]
        #expect(DegreeContribution.gains(for: "zzzz9999", credits: 1, plan: .empty, audits: target).isEmpty)
        #expect(DegreeContribution.gains(for: a, credits: 1, plan: plan([a]), audits: target).isEmpty)
        #expect(DegreeContribution.gains(for: "   ", credits: 1, plan: .empty, audits: target).isEmpty)
        let typed = DegreeContribution.gains(for: "abcd1000", credits: 0, plan: .empty, audits: target)
        #expect(typed.count == 1)
        #expect(typed.first?.requirement == "rule r1")
        // base 0; with a: openFill 1 over 2 open rules = 1/2; gain 1 * 1/2 = 50 points.
        #expect(close(typed.first?.points ?? -1, 50))
    }

    @Test("suggestions leave out planned, taken, history and filled-requirement courses")
    func suggestionExclusions() {
        let taken = AuditCourse(code: b, title: "t", credits: 1, termCode: nil, isInProgress: false, isTransfer: false)
        let rules = [
            rule("r1", .open, advice: [a, b, c, "ABCD 4000"]),
            rule("r5", .open, advice: ["ABCD 5000", "ABCD 6000"]),
            rule("r6", .open, advice: ["ABCD 8000"]),
            rule("r7", .open, advice: ["ABCD 9000"]),
        ]
        let target = [labeled("x", audit(rules, courses: [taken]))]
        let result = DegreeContribution.suggestions(
            plan: plan([a, "ABCD 5000"]), audits: target, history: ["202610": ["abcd3000"]])
        // a planned, b on the audit, c in history; "ABCD 4000" is listed only by r1, which
        // a already fills, and "ABCD 6000" only by r5, which "ABCD 5000" fills: no gain.
        #expect(result.map(\.id) == ["ABCD 8000", "ABCD 9000"])
        // base 0; 4 open rules; two filled now = 1/2; with a third = 3/4; gain 25 points each,
        // so the tie keeps Penn's order.
        #expect(close(result[0].points, 25))
        #expect(close(result[1].points, 25))
    }

    @Test("suggestions rank a course that counts in two degrees above one that counts in one")
    func suggestionOrder() {
        let first = labeled("a", audit([rule("r1", .open, advice: [b, a])]))
        let second = labeled("b", audit([rule("r2", .open, advice: [a])]))
        let result = DegreeContribution.suggestions(plan: .empty, audits: [first, second], history: [:])
        // b: 100 in "a" only. a: 100 in "a" plus 100 in "b" = 200, so it leads despite Penn's order.
        #expect(result.map(\.id) == [a, b])
        #expect(result[0].gains.count == 2)
        #expect(close(result[0].points, 200))
        #expect(close(result[1].points, 100))
    }

    @Test("equal suggestions keep Penn's order")
    func suggestionTies() {
        let target = [labeled("x", audit([rule("r1", .open, advice: [b, a, c])]))]
        let result = DegreeContribution.suggestions(plan: .empty, audits: target, history: [:])
        // Each alone fills the single open rule: 100 points apiece.
        #expect(result.map(\.id) == [b, a, c])
    }

    @Test("a course that counts only toward an in-progress rule has zero points and sorts last")
    func inProgressZero() {
        let rules = [rule("ip", .inProgress, advice: [a]), rule("o", .open, advice: [b])]
        let result = DegreeContribution.suggestions(
            plan: .empty, audits: [labeled("x", audit(rules))], history: [:])
        // base 0; ip adds nothing to openFill; b: 1 open of 2 open-or-in-progress = 1/2 = 50 points.
        #expect(result.map(\.id) == [b, a])
        #expect(close(result[0].points, 50))
        #expect(result[1].points == 0)
        #expect(result[1].gains.first?.requirement == "rule ip")
    }

    @Test("every suggestion's points are within 0...100 per gain")
    func bounds() {
        let rules = [
            rule("m", .met),
            rule("o1", .open, advice: [a, b, c], needCourses: 2),
            rule("o2", .open, advice: [a, "ABCD 4000"]),
            rule("ip", .inProgress, advice: ["ABCD 5000"]),
        ]
        let result = DegreeContribution.suggestions(
            plan: plan([c]), audits: [labeled("x", audit(rules))], history: [:])
        #expect(!result.isEmpty)
        for suggestion in result {
            #expect(suggestion.points >= 0)
            #expect(!suggestion.gains.isEmpty)
            for gain in suggestion.gains {
                #expect(gain.points >= 0 && gain.points <= 100)
            }
        }
    }
}
