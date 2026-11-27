import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

private func sourceText(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(
        contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/\(name)"), encoding: .utf8)
}

@Suite("Degree plan stand-ins and approvals")
struct DegreePlanStandInTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let undeclared = DegreeGoals(school: "WU", majors: ["WUNG"])
    private let management = DegreeGoals(school: "WU", majors: ["MGMT"])

    private func audit(_ goals: DegreeGoals, whatIf: Bool) -> DegreeAudit {
        DegreeAudit(
            goals: goals, isWhatIf: whatIf, percentComplete: nil, degreeLabel: nil,
            catalogYearLabel: nil,
            blocks: [AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil, rules: [])],
            courses: [], fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func enginePlan(chosen: String, maxLoad: Double = 5.5, approvals: [String]? = nil) -> DegreeEnginePlan {
        DegreeEnginePlan(
            remainingCredits: 19, remainingCreditsWithoutOverlap: 22,
            scenarios: [DegreeEngineScenario(
                id: chosen, label: chosen, maxLoad: maxLoad, summer: false,
                finishTerm: "202810", meetsTarget: true)],
            chosen: chosen,
            schedule: [DegreeEngineTerm(term: "202710", credits: 1, courses: [DegreeEngineCourse(code: "ACCT 1020", title: "", credits: 1)])],
            approvals: approvals)
    }

    private var standIn: DegreePlanStandIn {
        DegreePlanStandIn(degreeID: "d2", goals: management, label: "management (general)")
    }

    // MARK: Codable

    @Test("stand-ins and approvals survive a round trip")
    func roundTrip() throws {
        let summary = DegreePlanSummary(
            finishTerm: "202810", scenarioID: "best", scenarioLabel: "best", remainingCredits: 19,
            needsApproval: true, createdAt: now, standIns: [standIn], approvals: ["8 cu in one term"])
        let data = try JSONEncoder().encode(summary)
        let back = try JSONDecoder().decode(DegreePlanSummary.self, from: data)
        #expect(back.standIns == [standIn])
        #expect(back.approvals == ["8 cu in one term"])
        #expect(back.scenarioID == "best")
    }

    @Test("a summary stored before these fields still decodes, and a bad stand-in costs only itself")
    func lenient() throws {
        let old = #"{"scenarioID":"best","scenarioLabel":"best","needsApproval":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DegreePlanSummary.self, from: old)
        #expect(decoded.standIns == nil)
        #expect(decoded.approvals == nil)
        #expect(decoded.needsApproval)

        let bad = #"{"scenarioID":"best","standIns":[7,{"degreeID":"d2"}],"approvals":["a",3]}"#.data(using: .utf8)!
        let partial = try JSONDecoder().decode(DegreePlanSummary.self, from: bad)
        #expect(partial.scenarioID == "best")
        #expect(partial.standIns == [])
        #expect(partial.approvals == ["a"])

        let notAList = #"{"scenarioID":"best","standIns":"x"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(DegreePlanSummary.self, from: notAList).standIns == nil)
    }

    // MARK: The substitution rule

    @Test("a stand-in whose what-if is kept replaces the degree's audit and says so")
    func substitutes() {
        let own = audit(undeclared, whatIf: false)
        let kept = audit(management, whatIf: true)
        let drawn = DegreePlanStandIn.drawing(
            degreeID: "d2", ownLabel: "wharton ung prgm - undeclared", ownAudit: own,
            standIns: [standIn], lookup: { $0 == management ? kept : nil })
        #expect(drawn.audit == kept)
        #expect(drawn.label == "management (general) · what if")
        #expect(drawn.degreeID == "d2")
    }

    @Test("no kept audit, no summary or another degree: the degree's own audit")
    func fallsBack() {
        let own = audit(undeclared, whatIf: false)
        let kept = audit(management, whatIf: true)
        let missing = DegreePlanStandIn.drawing(
            degreeID: "d2", ownLabel: "wharton", ownAudit: own, standIns: [standIn], lookup: { _ in nil })
        #expect(missing.audit == own)
        #expect(missing.label == "wharton")
        let none = DegreePlanStandIn.drawing(
            degreeID: "d2", ownLabel: "wharton", ownAudit: own, standIns: nil, lookup: { _ in kept })
        #expect(none.audit == own)
        let other = DegreePlanStandIn.drawing(
            degreeID: "d1", ownLabel: "cs", ownAudit: own, standIns: [standIn], lookup: { _ in kept })
        #expect(other.audit == own)
        #expect(other.label == "cs")
    }

    @Test("stand-ins come from the what-if audits a plan was made from, once per degree, without the suffix")
    func standInsFromAudits() {
        let own = DegreeLabeledAudit(degreeID: "d1", label: "computer science", audit: audit(undeclared, whatIf: false))
        let swapped = DegreeLabeledAudit(
            degreeID: "d2", label: "management (general)\(DegreeAdvisor.whatIfLabelSuffix)",
            audit: audit(management, whatIf: true))
        let found = DegreePlanStandIn.standIns(from: [own, swapped, swapped])
        #expect(found == [standIn])
        #expect(DegreePlanStandIn.standIns(from: [own]).isEmpty)
    }

    @Test("a hand edit drops the summary, so the drawing reverts to the own audit")
    func handEditReverts() {
        let own = audit(undeclared, whatIf: false)
        let kept = audit(management, whatIf: true)
        let summary = DegreeAdvisor.summary(of: enginePlan(chosen: "best"), now: now, standIns: [standIn])
        let plan = DegreePlan(terms: [PlannedTerm(termCode: "202710")], summary: summary)
        #expect(plan.summary?.standIns == [standIn])
        let edited = DegreePlanMath.withTermAdded(plan, now: now)
        #expect(edited.summary == nil)
        let drawn = DegreePlanStandIn.drawing(
            degreeID: "d2", ownLabel: "wharton", ownAudit: own,
            standIns: edited.summary?.standIns, lookup: { _ in kept })
        #expect(drawn.audit == own)
    }

    // MARK: Approvals

    @Test("the server's approvals decide needsApproval when present")
    func approvalsDecide() {
        let none = DegreeAdvisor.summary(of: enginePlan(chosen: "best", approvals: []), now: now)
        #expect(none?.needsApproval == false)
        #expect(none?.approvals == [])
        let some = DegreeAdvisor.summary(of: enginePlan(chosen: "standard", approvals: ["petition"]), now: now)
        #expect(some?.needsApproval == true)
        #expect(some?.approvals == ["petition"])
    }

    @Test("without approvals the scenario rule stands")
    func approvalsAbsent() {
        #expect(DegreeAdvisor.summary(of: enginePlan(chosen: "best"), now: now)?.needsApproval == true)
        #expect(DegreeAdvisor.summary(of: enginePlan(chosen: "standard"), now: now)?.needsApproval == false)
        #expect(DegreeAdvisor.summary(of: enginePlan(chosen: "student", maxLoad: 6), now: now)?.needsApproval == true)
        #expect(DegreeAdvisor.summary(of: enginePlan(chosen: "best"), now: now)?.approvals == nil)
    }

    @Test("the engine plan decodes approvals as nil when absent and as a list when present")
    func decodeApprovals() throws {
        let absent = #"{"schedule":[]}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(DegreeEnginePlan.self, from: absent).approvals == nil)
        let empty = #"{"schedule":[],"approvals":[]}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(DegreeEnginePlan.self, from: empty).approvals == [])
        let mixed = #"{"schedule":[],"approvals":["a",1]}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(DegreeEnginePlan.self, from: mixed).approvals == ["a"])
    }

    // MARK: Wiring

    @Test("the screen draws degreeAudits and the advisor brief reads the declared ones")
    func wiring() throws {
        let state = try sourceText("AppState+Degree.swift")
        #expect(state.contains("var degreeOwnAudits"))
        #expect(state.contains("DegreePlanStandIn.drawing("))
        let screen = try sourceText("DegreeProgressView.swift")
        #expect(screen.contains("return state.degreeOwnAudits"))
        let advisor = try sourceText("AppState+DegreeAdvisor.swift")
        #expect(advisor.contains("standIns: DegreePlanStandIn.standIns(from: auditsUsed)"))
    }
}
