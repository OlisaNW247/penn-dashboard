import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree projection")
struct DegreeProjectionTests {
    private func rule(
        _ id: String, _ status: RuleStatus, advice: [String] = [],
        needCourses: Int? = nil, needCredits: Double? = nil,
        appliedCount: Int? = nil, appliedCredits: Double? = nil,
        applied: [AuditCourse] = [], children: [AuditRule] = []
    ) -> AuditRule {
        AuditRule(id: id, label: "rule \(id)", ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: needCourses, needCredits: needCredits,
                  appliedCount: appliedCount, appliedCredits: appliedCredits,
                  applied: applied,
                  advice: advice.map { AdviceCourse(code: $0, title: nil, credits: 1) },
                  adviceText: nil, children: children)
    }

    private func block(_ rules: [AuditRule]) -> AuditBlock {
        AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil, rules: rules)
    }

    private func audit(_ rules: [AuditRule], courses: [AuditCourse] = []) -> DegreeAudit {
        DegreeAudit(goals: DegreeGoals(), isWhatIf: false, percentComplete: nil, degreeLabel: nil,
                    catalogYearLabel: nil, blocks: [block(rules)], courses: courses,
                    fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func plan(_ codes: [String], credits: Double = 1) -> DegreePlan {
        DegreePlan(terms: [PlannedTerm(termCode: "202710", courses: codes.map {
            PlannedCourse(code: $0, title: nil, credits: credits)
        })])
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    @Test("an empty plan and a missing audit give the empty projection")
    func empties() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"])])
        #expect(DegreeProjection.make(plan: .empty, audit: a) == .empty)
        #expect(DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: nil) == .empty)
        #expect(DegreeProjection.empty.isEmpty)
    }

    @Test("a requirement with no stated need is filled by one option; a second is overflow")
    func singleNeedAndOverflow() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000", "ABCD 2000"])])
        let p = DegreeProjection.make(plan: plan(["ABCD 1000", "ABCD 2000"]), audit: a)
        let entry = p.rule(blockID: "B", ruleID: "r1")
        #expect(entry?.fill == 1)
        #expect(entry?.isFilled == true)
        #expect(entry?.planned.map(\.code) == ["ABCD 1000", "ABCD 2000"])
        #expect(p.placed == ["ABCD 1000", "ABCD 2000"])
        #expect(p.unplaced.isEmpty)
        #expect(!p.isEmpty)
    }

    @Test("a count need counts what is still missing")
    func courseCounts() {
        let r = rule("r1", .open, advice: ["ABCD 1000", "ABCD 2000", "ABCD 3000"], needCourses: 4, appliedCount: 1)
        let a = audit([r])
        let one = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: a)
        #expect(close(one.rule(blockID: "B", ruleID: "r1")?.fill ?? -1, 1.0 / 3))
        let three = DegreeProjection.make(plan: plan(["ABCD 1000", "ABCD 2000", "ABCD 3000"]), audit: a)
        #expect(close(three.rule(blockID: "B", ruleID: "r1")?.fill ?? -1, 1))
    }

    @Test("a credit need does not fill on the first course")
    func creditNeed() {
        let r = rule("r1", .open, advice: ["ABCD 1000"], needCredits: 14, appliedCredits: 2)
        let p = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: audit([r]))
        #expect(close(p.rule(blockID: "B", ruleID: "r1")?.fill ?? -1, 1.0 / 12))
    }

    @Test("a course spills to the second requirement once the first is full")
    func spill() {
        let a = audit([
            rule("r1", .open, advice: ["ABCD 1000", "ABCD 2000"]),
            rule("r2", .open, advice: ["ABCD 1000", "ABCD 2000"]),
        ])
        let p = DegreeProjection.make(plan: plan(["ABCD 1000", "ABCD 2000"]), audit: a)
        #expect(p.rule(blockID: "B", ruleID: "r1")?.planned.map(\.code) == ["ABCD 1000"])
        #expect(p.rule(blockID: "B", ruleID: "r2")?.planned.map(\.code) == ["ABCD 2000"])
        #expect(p.rule(blockID: "B", ruleID: "r2")?.fill == 1)
    }

    @Test("a course stays on the first requirement when both are full")
    func overflowStaysFirst() {
        let a = audit([
            rule("r1", .open, advice: ["ABCD 1000", "ABCD 2000", "ABCD 3000"]),
            rule("r2", .open, advice: ["ABCD 1000", "ABCD 2000", "ABCD 3000"]),
        ])
        let p = DegreeProjection.make(plan: plan(["ABCD 1000", "ABCD 2000", "ABCD 3000"]), audit: a)
        #expect(p.rule(blockID: "B", ruleID: "r1")?.planned.map(\.code) == ["ABCD 1000", "ABCD 3000"])
        #expect(p.rule(blockID: "B", ruleID: "r1")?.fill == 1)
        #expect(p.rule(blockID: "B", ruleID: "r2")?.planned.map(\.code) == ["ABCD 2000"])
        #expect(p.placed == ["ABCD 1000", "ABCD 2000", "ABCD 3000"])
    }

    @Test("a course Penn already counts is skipped, however its code is typed")
    func alreadyTaken() {
        let taken = AuditCourse(code: "CIS 1210", title: "t", credits: 1, termCode: nil, isInProgress: false, isTransfer: false)
        let a = audit([rule("r1", .open, advice: ["CIS 1210"])], courses: [taken])
        let p = DegreeProjection.make(plan: plan(["cis1210"]), audit: a)
        #expect(p.placed.isEmpty)
        #expect(p.unplaced.isEmpty)
        #expect(p.rules.isEmpty)
        #expect(p.isEmpty)
    }

    @Test("a course nothing lists is unplaced")
    func unplacedCourse() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"])])
        let p = DegreeProjection.make(plan: plan(["ABCD 1000", "zzzz9999"]), audit: a)
        #expect(p.placed == ["ABCD 1000"])
        #expect(p.unplaced == ["ZZZZ 9999"])
    }

    @Test("a course planned in two terms counts once")
    func duplicates() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"], needCourses: 2)])
        let twice = DegreePlan(terms: [
            PlannedTerm(termCode: "202710", courses: [PlannedCourse(code: "ABCD 1000", title: nil, credits: 1)]),
            PlannedTerm(termCode: "202730", courses: [PlannedCourse(code: "abcd1000", title: nil, credits: 1)]),
        ])
        let p = DegreeProjection.make(plan: twice, audit: a)
        #expect(p.placed == ["ABCD 1000"])
        #expect(p.rule(blockID: "B", ruleID: "r1")?.planned.count == 1)
        #expect(close(p.rule(blockID: "B", ruleID: "r1")?.fill ?? -1, 0.5))
    }

    @Test("a parent with no options is as full as its unmet children on average; a met child is ignored")
    func parentFill() {
        let parent = rule("p", .open, children: [
            rule("c1", .open, advice: ["ABCD 1000"]),
            rule("c2", .open, advice: ["ABCD 2000"]),
            rule("c3", .met),
        ])
        let p = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: audit([parent]))
        let derived = p.rule(blockID: "B", ruleID: "p")
        #expect(derived?.planned.isEmpty == true)
        #expect(close(derived?.fill ?? -1, 0.5))
        #expect(p.rule(blockID: "B", ruleID: "c2") == nil)
    }

    @Test("open fill and ring share count only open rules over open and in-progress ones")
    func ringMath() {
        let a = audit([
            rule("m", .met),
            rule("ip", .inProgress),
            rule("o1", .open, advice: ["ABCD 1000"]),
            rule("o2", .open, advice: ["ABCD 2000"]),
        ])
        let p = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: a)
        #expect(close(p.openFill, 1))
        #expect(close(p.ringShare, 1.0 / 3))
        #expect(close(p.ringGain(base: 0.4), 0.6 / 3))
        #expect(p.ringGain(base: 1) == 0)
        for base in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(p.ringGain(base: base) <= 1 - base + 1e-12)
            #expect(p.ringGain(base: base) >= 0)
        }
    }

    @Test("an in-progress rule takes a planned course but adds nothing to the shares")
    func inProgressNotDoubled() {
        let a = audit([
            rule("ip", .inProgress, advice: ["ABCD 1000"]),
            rule("o", .open, advice: ["ABCD 9000"]),
        ])
        let p = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: a)
        let entry = p.rule(blockID: "B", ruleID: "ip")
        #expect(entry != nil)
        #expect((entry?.fill ?? 0) > 0)
        #expect(p.openFill == 0)
        #expect(p.ringShare == 0)
        let blockResult = p.block(block(a.blocks[0].rules))
        #expect(blockResult.courses == 1)
        #expect(blockResult.share == 0)
    }

    @Test("a block reports its distinct planned courses and the share they add")
    func blockShare() {
        let rules = [
            rule("m", .met),
            rule("o1", .open, advice: ["ABCD 1000"]),
            rule("o2", .open, advice: ["ABCD 2000"]),
            rule("o3", .open, advice: ["ABCD 3000"]),
        ]
        let a = audit(rules)
        let p = DegreeProjection.make(plan: plan(["ABCD 1000", "ABCD 2000"]), audit: a)
        let result = p.block(a.blocks[0])
        #expect(result.courses == 2)
        #expect(close(result.share, 0.5))
    }

    @Test("adding a planned course never lowers the ring share")
    func monotone() {
        let a = audit([
            rule("o1", .open, advice: ["ABCD 1000", "ABCD 1100"], needCourses: 2),
            rule("o2", .open, advice: ["ABCD 2000"], needCredits: 4),
            rule("o3", .open, advice: ["ABCD 1000", "ABCD 3000"]),
            rule("ip", .inProgress, advice: ["ABCD 4000"]),
        ])
        let sequence = ["ABCD 1000", "ABCD 2000", "ZZZZ 1", "ABCD 1100", "ABCD 3000", "ABCD 4000"]
        var last = 0.0
        for count in 0...sequence.count {
            let p = DegreeProjection.make(plan: plan(Array(sequence.prefix(count))), audit: a)
            #expect(p.ringShare >= last - 1e-12)
            #expect(p.ringShare >= 0 && p.ringShare <= 1)
            last = p.ringShare
        }
    }
}
