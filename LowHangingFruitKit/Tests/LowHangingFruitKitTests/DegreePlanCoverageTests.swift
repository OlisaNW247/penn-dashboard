import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Planner coverage")
struct DegreePlanCoverageTests {
    private let undeclared = DegreeGoals(school: "WU", majors: ["WUNG"])
    private let management = DegreeGoals(school: "WU", majors: ["MGMT"])
    private let finance = DegreeGoals(school: "WU", majors: ["FNCE"])

    private func rule(_ id: String, _ status: RuleStatus, advice: [String] = []) -> AuditRule {
        AuditRule(id: id, label: "rule \(id)", ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: nil, needCredits: nil,
                  appliedCount: nil, appliedCredits: nil, applied: [],
                  advice: advice.map { AdviceCourse(code: $0, title: nil, credits: 1) },
                  adviceText: nil, children: [])
    }

    private func audit(whatIf: Bool, goals: DegreeGoals, percent: Double? = 67) -> DegreeAudit {
        DegreeAudit(
            goals: goals, isWhatIf: whatIf, percentComplete: percent, degreeLabel: nil,
            catalogYearLabel: nil,
            blocks: [AuditBlock(
                id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil,
                rules: [rule("met", .met), rule("a", .open, advice: ["ABCD 1000"]),
                        rule("b", .open), rule("p", .inProgress, advice: ["ZZZZ 1"])])],
            courses: [], fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func plan(_ codes: [String], summary: DegreePlanSummary? = nil) -> DegreePlan {
        DegreePlan(
            terms: [PlannedTerm(termCode: "202710", courses: codes.map {
                PlannedCourse(code: $0, title: nil, credits: 1)})],
            summary: summary)
    }

    private func summary(
        coverage: [DegreePlanCoverage]?, standIns: [DegreePlanStandIn]? = nil
    ) -> DegreePlanSummary {
        DegreePlanSummary(
            finishTerm: "202810", scenarioID: "standard", scenarioLabel: "standard",
            remainingCredits: 4, needsApproval: false, createdAt: Date(timeIntervalSince1970: 0),
            standIns: standIns, approvals: nil, coverage: coverage)
    }

    private func decode(_ json: String?) throws -> DegreeEnginePlan {
        var text = "{\"schedule\":[]"
        if let json { text += ",\"coverage\":\(json)" }
        text += "}"
        return try JSONDecoder().decode(DegreeEnginePlan.self, from: Data(text.utf8))
    }

    // MARK: Wire

    @Test("a good coverage list decodes")
    func good() throws {
        let p = try decode("[{\"degreeId\":\"d1\",\"slots\":20,\"filled\":20,\"complete\":true}]")
        #expect(p.coverage == [DegreeEngineCoverage(degreeId: "d1", slots: 20, filled: 20, complete: true)])
    }

    @Test("absent or malformed reads as none, a bad element is dropped")
    func absentMalformed() throws {
        #expect(try decode(nil).coverage.isEmpty)
        #expect(try decode("7").coverage.isEmpty)
        let p = try decode("[{\"slots\":3}, 5, {\"degreeId\":\"d2\",\"slots\":3,\"filled\":1,\"complete\":false}]")
        #expect(p.coverage.map { $0.degreeId } == ["d2"])
    }

    @Test("counts are never negative and filled is clamped to slots")
    func clamp() throws {
        let p = try decode("""
        [{"degreeId":"a","slots":4,"filled":9,"complete":false},
         {"degreeId":"b","slots":-2,"filled":-1,"complete":false},
         {"degreeId":"c","complete":true}]
        """)
        #expect(p.coverage[0].filled == 4)
        #expect(p.coverage[1].slots == 0 && p.coverage[1].filled == 0)
        #expect(p.coverage[2].slots == 0 && p.coverage[2].complete)
    }

    @Test("the summary takes coverage from the engine plan, nil when empty")
    func summaryFromEngine() {
        let engine = DegreeEnginePlan(
            remainingCredits: 3, remainingCreditsWithoutOverlap: 3,
            scenarios: [DegreeEngineScenario(id: "standard", label: "s", maxLoad: 5.5, summer: false,
                                             finishTerm: "202810", meetsTarget: true)],
            chosen: "standard", schedule: [],
            coverage: [DegreeEngineCoverage(degreeId: "d1", slots: 5, filled: 4, complete: false)])
        let s = DegreeAdvisor.summary(of: engine, now: Date(timeIntervalSince1970: 0))
        #expect(s?.coverage == [DegreePlanCoverage(degreeID: "d1", slots: 5, filled: 4, complete: false)])
        let none = DegreeEnginePlan(
            remainingCredits: 3, remainingCreditsWithoutOverlap: 3,
            scenarios: engine.scenarios, chosen: "standard", schedule: [])
        #expect(DegreeAdvisor.summary(of: none, now: Date(timeIntervalSince1970: 0))?.coverage == nil)
    }

    @Test("a summary round-trips with coverage, and an old one without it still loads")
    func roundTrip() throws {
        let s = summary(coverage: [DegreePlanCoverage(degreeID: "d1", slots: 5, filled: 5, complete: true)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DegreePlanSummary.self, from: encoder.encode(s))
        #expect(back.coverage == s.coverage)
        let old = try decoder.decode(
            DegreePlanSummary.self,
            from: Data("{\"scenarioID\":\"x\",\"scenarioLabel\":\"x\",\"needsApproval\":false}".utf8))
        #expect(old.coverage == nil)
    }

    // MARK: Applicability

    private let full = DegreePlanCoverage(degreeID: "d1", slots: 4, filled: 4, complete: true)

    private func standIn() -> DegreePlanStandIn {
        DegreePlanStandIn(degreeID: "d1", goals: management, label: "management")
    }

    @Test("with no stand-in it applies to a declared audit and not to a what-if")
    func noStandIn() {
        let s = summary(coverage: [full])
        #expect(DegreePlanCoverage.applicable(
            for: "d1", audit: audit(whatIf: false, goals: undeclared), summary: s) == full)
        #expect(DegreePlanCoverage.applicable(
            for: "d1", audit: audit(whatIf: true, goals: management), summary: s) == nil)
    }

    @Test("with a stand-in it applies only to the matching what-if")
    func withStandIn() {
        let s = summary(coverage: [full], standIns: [standIn()])
        #expect(DegreePlanCoverage.applicable(
            for: "d1", audit: audit(whatIf: true, goals: management), summary: s) == full)
        #expect(DegreePlanCoverage.applicable(
            for: "d1", audit: audit(whatIf: false, goals: undeclared), summary: s) == nil)
        #expect(DegreePlanCoverage.applicable(
            for: "d1", audit: audit(whatIf: true, goals: finance), summary: s) == nil)
    }

    @Test("another degree, or no summary, gives nil")
    func otherDegree() {
        let s = summary(coverage: [full])
        #expect(DegreePlanCoverage.applicable(
            for: "d2", audit: audit(whatIf: false, goals: undeclared), summary: s) == nil)
        #expect(DegreePlanCoverage.applicable(
            for: "d1", audit: audit(whatIf: false, goals: undeclared), summary: nil) == nil)
        #expect(DegreePlanCoverage.applicable(
            for: "d1", audit: audit(whatIf: false, goals: undeclared), summary: summary(coverage: nil)) == nil)
    }

    // MARK: Adjusting

    @Test("complete fills every open rule, the ring and the text read whole")
    func complete() {
        let a = audit(whatIf: false, goals: undeclared)
        let plain = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: a)
        #expect(plain.ringShare < 1)
        let adjusted = plain.adjusted(by: full, audit: a)
        #expect(abs(adjusted.ringGain(base: 0.67) - 0.33) < 1e-9)
        #expect(abs(adjusted.withPlanGain(base: 0.67) - 0.33) < 1e-9)
        #expect(DegreeProgressMath.withPlanText(
            base: 0.67, gain: adjusted.withPlanGain(base: 0.67)) == "≈ 100% with plan")
        #expect(adjusted.rule(blockID: "B", ruleID: "a")?.fill == 1)
        #expect(adjusted.rule(blockID: "B", ruleID: "b")?.fill == 1)
        // The chips already laid are kept, none are invented.
        #expect(adjusted.rule(blockID: "B", ruleID: "a")?.planned.map { $0.code } == ["ABCD 1000"])
        #expect(adjusted.rule(blockID: "B", ruleID: "b")?.planned.isEmpty == true)
        #expect(adjusted.placed == plain.placed)
        // In progress is left to its own segment: no entry added, and the block
        // share counts the two open rules of four countable.
        #expect(adjusted.rule(blockID: "B", ruleID: "p") == plain.rule(blockID: "B", ruleID: "p"))
        #expect(adjusted.openFill == 2)
        let share = adjusted.block(a.blocks[0]).share
        #expect(abs(share - 0.5) < 1e-9)
    }

    @Test("a partial claim lifts the arc to filled over slots, never lowers it")
    func partial() {
        let a = audit(whatIf: false, goals: undeclared)
        let plain = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: a)
        let half = DegreePlanCoverage(degreeID: "d1", slots: 10, filled: 9, complete: false)
        let adjusted = plain.adjusted(by: half, audit: a)
        #expect(abs(adjusted.ringShare - max(plain.ringShare, 0.9)) < 1e-9)
        #expect(abs(adjusted.withPlanShare - max(plain.withPlanShare, 0.9)) < 1e-9)
        #expect(adjusted.rules == plain.rules)
        let low = DegreePlanCoverage(degreeID: "d1", slots: 10, filled: 0, complete: false)
        #expect(plain.adjusted(by: low, audit: a).ringShare == plain.ringShare)
    }

    @Test("nil coverage, or nothing claimed, changes nothing")
    func unchanged() {
        let a = audit(whatIf: false, goals: undeclared)
        let plain = DegreeProjection.make(plan: plan(["ABCD 1000"]), audit: a)
        #expect(plain.adjusted(by: nil, audit: a) == plain)
        let none = DegreePlanCoverage(degreeID: "d1", slots: 0, filled: 0, complete: false)
        #expect(plain.adjusted(by: none, audit: a) == plain)
    }

    @Test("a hand edit drops the summary, and with it the adjustment")
    func handEdit() {
        let a = audit(whatIf: false, goals: undeclared)
        let withSummary = plan(["ABCD 1000"], summary: summary(coverage: [full]))
        let edited = DegreePlanMath.adding(
            PlannedCourse(code: "EFGH 2000", title: nil, credits: 1), to: "202710", in: withSummary)
        #expect(edited.summary == nil)
        let coverage = DegreePlanCoverage.applicable(for: "d1", audit: a, summary: edited.summary)
        #expect(coverage == nil)
        let plain = DegreeProjection.make(plan: edited, audit: a)
        #expect(plain.adjusted(by: coverage, audit: a) == plain)
    }

    // MARK: Target cases

    private func targeted(slots: Int = 20, filled: Int = 20, target: Int?, best: Int?) -> DegreePlanCoverage {
        DegreePlanCoverage(degreeID: "d1", slots: slots, filled: filled, complete: false,
                           filledByTarget: target, bestFilledByTarget: best)
    }

    @Test("target fields decode, clamp and stay absent when absent")
    func targetDecode() throws {
        let p = try decode("""
        [{"degreeId":"a","slots":20,"filled":18,"complete":false,"filledByTarget":25,"bestFilledByTarget":99},
         {"degreeId":"b","slots":20,"filled":18,"complete":false,"filledByTarget":-3,"bestFilledByTarget":2},
         {"degreeId":"c","slots":20,"filled":18,"complete":false}]
        """)
        #expect(p.coverage[0].filledByTarget == 18)
        #expect(p.coverage[0].bestFilledByTarget == 20)
        #expect(p.coverage[1].filledByTarget == 0)
        #expect(p.coverage[1].bestFilledByTarget == 2)
        #expect(p.coverage[2].filledByTarget == nil && p.coverage[2].bestFilledByTarget == nil)
        // The best case is never below the granted one.
        let low = targeted(target: 15, best: 3)
        #expect(low.bestFilledByTarget == 15)
    }

    @Test("the target term decodes leniently and reaches the summary only when valid")
    func targetTerm() throws {
        let text = "{\"schedule\":[],\"targetTerm\":\"202810\"}"
        let p = try JSONDecoder().decode(DegreeEnginePlan.self, from: Data(text.utf8))
        #expect(p.targetTerm == "202810")
        let bad = try JSONDecoder().decode(
            DegreeEnginePlan.self, from: Data("{\"schedule\":[],\"targetTerm\":7}".utf8))
        #expect(bad.targetTerm == nil)
        let scenario = DegreeEngineScenario(id: "standard", label: "s", maxLoad: 5.5, summer: false,
                                            finishTerm: "202810", meetsTarget: true)
        func summaryFor(_ term: String?) -> DegreePlanSummary? {
            DegreeAdvisor.summary(
                of: DegreeEnginePlan(
                    remainingCredits: 1, remainingCreditsWithoutOverlap: 1, scenarios: [scenario],
                    chosen: "standard", schedule: [], targetTerm: term),
                now: Date(timeIntervalSince1970: 0))
        }
        #expect(summaryFor("202810")?.targetTerm == "202810")
        #expect(summaryFor("garbage")?.targetTerm == nil)
        #expect(summaryFor(nil)?.targetTerm == nil)
    }

    @Test("ring cases: granted and best are fractions of the remainder")
    func ringCases() throws {
        let cases = try #require(DegreeRingCases.make(
            coverage: targeted(target: 15, best: 20), base: 0.67))
        #expect(abs(cases.granted - 0.2475) < 1e-9)
        #expect(abs(cases.best - 0.33) < 1e-9)
        #expect(cases.showsBest)
        let same = try #require(DegreeRingCases.make(
            coverage: targeted(target: 15, best: 15), base: 0.67))
        #expect(!same.showsBest)
        // Under half a percent of the ring apart is not a second case.
        let close = try #require(DegreeRingCases.make(
            coverage: targeted(slots: 400, filled: 400, target: 100, best: 101), base: 0.67))
        #expect(!close.showsBest)
        // Best missing: granted only.
        let single = try #require(DegreeRingCases.make(
            coverage: targeted(target: 15, best: nil), base: 0.67))
        #expect(!single.showsBest)
    }

    @Test("ring cases fall back to nothing without target data or slots")
    func ringCasesFallback() {
        #expect(DegreeRingCases.make(coverage: targeted(target: nil, best: nil), base: 0.67) == nil)
        #expect(DegreeRingCases.make(coverage: nil, base: 0.67) == nil)
        #expect(DegreeRingCases.make(
            coverage: targeted(slots: 0, filled: 0, target: 0, best: 0), base: 0.67) == nil)
    }

    @Test("the lines under the ring, exactly")
    func ringLines() throws {
        let both = try #require(DegreeRingCases.make(coverage: targeted(target: 15, best: 20), base: 0.67))
        #expect(DegreeProgressMath.ringLines(base: 0.67, cases: both, targetTerm: "202810")
                == ["≈ 92% by spring 2028", "≈ 100% if approved"])
        let one = try #require(DegreeRingCases.make(coverage: targeted(target: 15, best: 15), base: 0.67))
        #expect(DegreeProgressMath.ringLines(base: 0.67, cases: one, targetTerm: "202810")
                == ["≈ 92% by spring 2028"])
        #expect(DegreeProgressMath.ringLines(base: 0.67, cases: one, targetTerm: nil)
                == ["≈ 92% with plan"])
        let nothing = try #require(DegreeRingCases.make(coverage: targeted(target: 0, best: 0), base: 0.67))
        #expect(DegreeProgressMath.ringLines(base: 0.67, cases: nothing, targetTerm: "202810").isEmpty)
    }

    @Test("the ring fades the best case and the legend shows it only when one is drawn")
    func bestSource() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(
            contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/DegreeProgressView.swift"),
            encoding: .utf8)
        #expect(source.contains("Color.smoothCobalt.opacity(0.35)"))
        #expect(source.contains("\"if approved\""))
        #expect(source.contains("if showsApproved {"))
        #expect(source.contains("showsApproved: figures.bestExtra > 0"))
        let lowered = source.lowercased()
        #expect(!lowered.contains("recommend"))
        #expect(!lowered.contains("graduate"))
    }

    @Test("every drawing goes through the one helper")
    func wiring() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let state = try String(
            contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/AppState+Degree.swift"),
            encoding: .utf8)
        #expect(state.contains("func degreeProjection(degreeID:"))
        #expect(state.contains("DegreePlanCoverage.applicable("))
        let table = try String(
            contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/DegreeSemesterTable.swift"),
            encoding: .utf8)
        #expect(table.contains(".fixedSize(horizontal: true, vertical: false)"))
    }
}
