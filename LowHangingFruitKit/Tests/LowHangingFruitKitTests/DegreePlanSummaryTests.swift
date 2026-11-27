import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Degree engine slots and plan summary")
struct DegreePlanSummaryTests {
    private func rule(
        _ id: String, _ status: RuleStatus, advice: [String] = [], needCourses: Int? = nil
    ) -> AuditRule {
        AuditRule(id: id, label: "rule \(id)", ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: needCourses, needCredits: nil,
                  appliedCount: nil, appliedCredits: nil, applied: [],
                  advice: advice.map { AdviceCourse(code: $0, title: nil, credits: 1) },
                  adviceText: nil, children: [])
    }

    private func audit(_ rules: [AuditRule]) -> DegreeAudit {
        DegreeAudit(
            goals: DegreeGoals(), isWhatIf: false, percentComplete: nil, degreeLabel: nil,
            catalogYearLabel: nil,
            blocks: [AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil, rules: rules)],
            courses: [], fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func plan(_ courses: [PlannedCourse], summary: DegreePlanSummary? = nil) -> DegreePlan {
        DegreePlan(terms: [PlannedTerm(termCode: "202710", courses: courses)], summary: summary)
    }

    private func course(_ code: String, slots: [String]? = nil) -> PlannedCourse {
        PlannedCourse(code: code, title: nil, credits: 1, slotIds: slots)
    }

    private func summary() -> DegreePlanSummary {
        DegreePlanSummary(
            finishTerm: "202810", scenarioID: "best", scenarioLabel: "best", remainingCredits: 19,
            needsApproval: true, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    // MARK: Slot ids

    @Test("a slot id resolves when the degree id is itself several parts")
    func slotIndexWithRealDegreeID() {
        // Penn's degree id is school|degree|major|program; the block and rule
        // follow it, and a course code may follow them.
        let keys = ["RA0001|10": 0, "RA0002|7": 1]
        #expect(DegreeProjection.slotIndex("WU|BS|WUNG|WU_BS_WUNG|RA0001|10", in: keys) == 0)
        #expect(DegreeProjection.slotIndex("WU|BS|WUNG|WU_BS_WUNG|RA0002|7|CIS 4000", in: keys) == 1)
        #expect(DegreeProjection.slotIndex("d1|RA0001|10", in: keys) == 0)
        #expect(DegreeProjection.slotIndex("d1|RA0001|10|ACCT 1020", in: keys) == 0)
        // The other degree's block, a short id, an empty part: nothing.
        #expect(DegreeProjection.slotIndex("EU|BSE|CSCI|X|RA0009|3", in: keys) == nil)
        #expect(DegreeProjection.slotIndex("RA0001|10", in: keys) == nil)
        #expect(DegreeProjection.slotIndex("d1||10", in: keys) == nil)
        #expect(DegreeProjection.slotIndex("", in: keys) == nil)
        // The first part is never read as a block.
        #expect(DegreeProjection.slotIndex("RA0001|10|x", in: keys) == nil)
    }

    @Test("slot ids read degree, block and rule; a fourth part and anything short are handled")
    func slotParsing() {
        let plain = DegreeProjection.resolveSlotID("d1|B|r1")
        #expect(plain?.degreeID == "d1")
        #expect(plain?.blockID == "B")
        #expect(plain?.ruleID == "r1")
        let withCourse = DegreeProjection.resolveSlotID("d1|B|r1|ACCT 1020")
        #expect(withCourse?.ruleID == "r1")
        #expect(DegreeProjection.resolveSlotID("d1|B") == nil)
        #expect(DegreeProjection.resolveSlotID("garbage") == nil)
        #expect(DegreeProjection.resolveSlotID("d1||r1") == nil)
        #expect(DegreeProjection.resolveSlotID("") == nil)
    }

    // MARK: Projection

    @Test("a slot id lays the course on that rule, even one with no options")
    func wordsOnlyRule() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"]), rule("r2", .open)])
        let p = DegreeProjection.make(plan: plan([course("ZZZZ 1", slots: ["d|B|r2"])]), audit: a)
        #expect(p.rule(blockID: "B", ruleID: "r2")?.fill == 1)
        #expect(p.rule(blockID: "B", ruleID: "r1") == nil)
        #expect(p.placed == ["ZZZZ 1"])
        #expect(p.unplaced.isEmpty)
    }

    @Test("a real degree id, itself joined by bars, still lays the course on its rule")
    func realDegreeID() {
        // 2026-11-27, Olisa's phone: every slot id began "WU|BS|WUNG|…" or the
        // engineering one, the block was read as "BS", nothing resolved, and
        // a full plan drew no arc and no planned count.
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"]), rule("r2", .open)])
        let p = DegreeProjection.make(
            plan: plan([
                course("ZZZZ 1", slots: ["WU|BS|WUNG|WU_BS_WUNG|B|r2"]),
                course("ABCD 1000", slots: ["EU|BSE|CSCI|EU_BSE_CSCI|B|r1|ABCD 1000"]),
            ]), audit: a)
        #expect(p.rule(blockID: "B", ruleID: "r2")?.fill == 1)
        #expect(p.rule(blockID: "B", ruleID: "r1")?.fill == 1)
        #expect(p.placed == ["ZZZZ 1", "ABCD 1000"])
        #expect(p.ringShare > 0)
    }

    @Test("one course can fill two rules when the engine says so")
    func twoRules() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"]), rule("r2", .open)])
        let p = DegreeProjection.make(
            plan: plan([course("ABCD 1000", slots: ["d|B|r1", "d|B|r2|ACCT 1020"])]), audit: a)
        #expect(p.rule(blockID: "B", ruleID: "r1")?.fill == 1)
        #expect(p.rule(blockID: "B", ruleID: "r2")?.fill == 1)
        #expect(p.countedAll["ABCD 1000"] == ["rule r1", "rule r2"])
    }

    @Test("slot ids that do not resolve add nothing and do not fall back to options")
    func unresolved() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"])])
        let p = DegreeProjection.make(plan: plan([course("ABCD 1000", slots: ["d|X|nope"])]), audit: a)
        #expect(p.placed.isEmpty)
        #expect(p.unplaced.isEmpty)
        #expect(p.rules.isEmpty)
    }

    @Test("a plan with no slot ids projects as before")
    func plainUnchanged() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"])])
        let p = DegreeProjection.make(plan: plan([course("ABCD 1000")]), audit: a)
        #expect(p.rule(blockID: "B", ruleID: "r1")?.fill == 1)
        #expect(p.placed == ["ABCD 1000"])
        #expect(abs(p.ringShare - 1) < 1e-9)
    }

    // MARK: With plan

    @Test("the with-plan gain reaches the whole ring for a complete plan")
    func completePlan() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"]), rule("r2", .open), rule("r3", .inProgress)])
        let p = DegreeProjection.make(
            plan: plan([course("ABCD 1000", slots: ["d|B|r1"]), course("ZZZZ 1", slots: ["d|B|r2"])]), audit: a)
        #expect(abs(p.withPlanShare - 1) < 1e-9)
        #expect(abs(p.withPlanGain(base: 0.5) - 0.5) < 1e-9)
        // The arc's own share still leaves the in-progress rule out.
        #expect(abs(p.ringShare - 2.0 / 3.0) < 1e-9)
        #expect(p.withPlanGain(base: 1) == 0)
    }

    @Test("in-progress rules count in the with-plan share only when something is planned")
    func inProgressCounts() {
        let a = audit([rule("r1", .open, advice: ["ABCD 1000"]), rule("r3", .inProgress)])
        let p = DegreeProjection.make(plan: plan([course("ABCD 1000")]), audit: a)
        #expect(abs(p.withPlanShare - 1) < 1e-9)
        let none = DegreeProjection.make(plan: plan([course("QQQQ 9")]), audit: a)
        #expect(none.withPlanShare == 0)
    }

    // MARK: Summary

    @Test("the summary line")
    func summaryLine() {
        #expect(DegreePlanSummary.line(summary()) == "plan · would finish spring 2028 · 19 cu to go · needs approval")
        let bare = DegreePlanSummary(
            finishTerm: nil, scenarioID: "standard", scenarioLabel: "", remainingCredits: nil,
            needsApproval: false, createdAt: Date(timeIntervalSince1970: 0))
        #expect(DegreePlanSummary.line(bare) == "plan · no finish semester")
        let half = DegreePlanSummary(
            finishTerm: "202830", scenarioID: "standard", scenarioLabel: "", remainingCredits: 19.5,
            needsApproval: false, createdAt: Date(timeIntervalSince1970: 0))
        #expect(DegreePlanSummary.line(half) == "plan · would finish fall 2028 · 19.5 cu to go")
    }

    @Test("a hand edit drops the summary and the earlier plan keeps it")
    func editsDropSummary() {
        let start = plan([course("ABCD 1000")], summary: summary())
        let added = DegreePlanMath.adding(course("EFGH 2000"), to: "202710", in: start)
        #expect(added.summary == nil)
        #expect(DegreePlanMath.removing(courseCode: "ABCD 1000", from: "202710", in: start).summary == nil)
        let withTerm = DegreePlan(terms: start.terms + [PlannedTerm(termCode: "202730")], summary: summary())
        #expect(DegreePlanMath.moving(courseCode: "ABCD 1000", to: "202730", before: nil, in: withTerm).summary == nil)
        #expect(DegreePlanMath.withTermAdded(start, now: Date(timeIntervalSince1970: 0)).summary == nil)
        #expect(DegreePlanMath.removingLastTermIfEmpty(withTerm).summary == nil)
        // A refused edit changes nothing, the summary included.
        #expect(DegreePlanMath.removing(courseCode: "NOPE 1", from: "202710", in: start).summary != nil)
        // Undo puts the earlier value back, summary and all.
        #expect(start.summary != nil)
    }

    // MARK: Codable

    @Test("slot ids and the summary round trip; a plan file without them still loads")
    func codable() throws {
        let original = plan([course("ABCD 1000", slots: ["d|B|r1"])], summary: summary())
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(DegreePlan.self, from: data)
        #expect(back == original)
        let old = #"{"terms":[{"termCode":"202710","courses":[{"code":"ABCD 1000","credits":1}]}]}"#
        let loaded = try JSONDecoder().decode(DegreePlan.self, from: Data(old.utf8))
        #expect(loaded.summary == nil)
        #expect(loaded.terms.first?.courses.first?.slotIds == nil)
        let empty = try JSONDecoder().decode(DegreePlan.self, from: Data("{}".utf8))
        #expect(empty == DegreePlan())
    }

    // MARK: Engine plan

    @Test("the engine's slot ids, registered credits and chosen scenario are kept")
    func engineDecodeAndApply() throws {
        let json = """
        {"chosen":"best","remainingCredits":19,
         "scenarios":[{"id":"best","label":"best","maxLoad":6.5,"summer":true,"finishTerm":"202810","meetsTarget":true}],
         "schedule":[
           {"term":"202630","credits":0,"registeredCredits":4,"courses":[]},
           {"term":"202710","credits":0,"courses":[]},
           {"term":"202730","credits":1,"registeredCredits":2,
            "courses":[{"code":"abcd1000","title":"T","credits":1,
                        "countsToward":["a","b"],"slotIds":["d|B|r1","d|B|r2|X 1"]}]}]}
        """
        let engine = try JSONDecoder().decode(DegreeEnginePlan.self, from: Data(json.utf8))
        #expect(engine.schedule[0].registeredCredits == 4)
        #expect(engine.schedule[2].courses[0].slotIds == ["d|B|r1", "d|B|r2|X 1"])
        let outcome = DegreeAdvisor.applyEnginePlan(
            engine, to: .empty, currentTerm: "202630", now: Date(timeIntervalSince1970: 5))
        // A term with no courses never becomes an empty planned term.
        #expect(outcome.plan.terms.map(\.termCode) == ["202730"])
        #expect(outcome.applied.count == 1)
        #expect(outcome.plan.terms[0].courses[0].slotIds == ["d|B|r1", "d|B|r2|X 1"])
        #expect(outcome.plan.summary?.finishTerm == "202810")
        #expect(outcome.plan.summary?.needsApproval == true)
        #expect(outcome.plan.summary?.scenarioID == "best")
    }

    @Test("an old server's plan has no summary")
    func noScenarioNoSummary() {
        let engine = DegreeEnginePlan(
            remainingCredits: 3, remainingCreditsWithoutOverlap: 3, scenarios: [], chosen: "",
            schedule: [DegreeEngineTerm(term: "202730", credits: 1, courses: [DegreeEngineCourse(code: "ABCD 1000", title: "T", credits: 1)])])
        let outcome = DegreeAdvisor.applyEnginePlan(engine, to: .empty, currentTerm: "202630")
        #expect(outcome.plan.summary == nil)
        #expect(outcome.plan.terms.first?.courses.first?.slotIds == nil)
    }

    // MARK: Table helpers

    @Test("a column over the limit")
    func overLimit() {
        #expect(!DegreeTimeline.isOverLimit(termCode: "202710", credits: 6.5))
        #expect(DegreeTimeline.isOverLimit(termCode: "202710", credits: 7))
        #expect(!DegreeTimeline.isOverLimit(termCode: "202720", credits: 4))
        #expect(DegreeTimeline.isOverLimit(termCode: "202720", credits: 4.5))
        let column = TimelineColumn(termCode: "202710", kind: .future, taken: [
            TimelineCourse(code: "ABCD 1000", title: nil, credits: 5),
        ], planned: [PlannedCourse(code: "EFGH 2000", title: nil, credits: 2)])
        #expect(DegreeSemesterTable.loadIsOver(column))
        let past = TimelineColumn(termCode: "202610", kind: .past, taken: [
            TimelineCourse(code: "ABCD 1000", title: nil, credits: 9),
        ], planned: [])
        #expect(!DegreeSemesterTable.loadIsOver(past))
    }

    @Test("best reads differently from approved")
    func scenarioRows() {
        let approved = DegreeEngineScenario(id: "approved", label: "", maxLoad: 6.5, summer: true, finishTerm: "202810", meetsTarget: true)
        let best = DegreeEngineScenario(id: "best", label: "", maxLoad: 6.5, summer: true, finishTerm: "202810", meetsTarget: true)
        #expect(DegreeAdvisorView.scenarioText(approved) == "6.5 cu · summer → spring 2028")
        #expect(DegreeAdvisorView.scenarioText(best) == "6.5 cu · 4 cu summers · approvals → spring 2028")
    }

    @Test("the what-if suffix comes off for display only")
    func labelStripping() {
        #expect(DegreeAdvisor.displayLabel("management (general) (what if, not declared)") == "management (general)")
        #expect(DegreeAdvisor.displayLabel("finance") == "finance")
        let course = PlannedCourse(
            code: "ABCD 1000", title: nil, credits: 1,
            countsToward: ["management (general) (what if, not declared) · core"])
        #expect(DegreeSemesterTable.engineLines(course) == ["management (general) · core"])
        let gain = DegreeGain(
            degreeID: "d", degreeLabel: "finance (what if, not declared)", requirement: "Core",
            points: 1, extraRequirements: ["Math", "Extra"])
        #expect(DegreeSemesterTable.fitLines([gain]) == ["fits · finance · core", "fits · finance · math"])
    }
}
