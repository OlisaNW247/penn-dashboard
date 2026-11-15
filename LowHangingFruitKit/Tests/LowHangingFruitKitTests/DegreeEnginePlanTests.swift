import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Degree engine plan")
struct DegreeEnginePlanTests {
    // Mid-November 2026: fall 2026 (202630) is the current term.
    private let now = Date(timeIntervalSince1970: 1_794_600_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    private func labeledAudit() -> DegreeLabeledAudit {
        let rule = AuditRule(
            id: "r", label: "rule r", ruleType: "Subset", percentComplete: nil, status: .open,
            needCourses: 1, needCredits: nil, appliedCount: nil, appliedCredits: nil, applied: [],
            advice: [AdviceCourse(code: "ABCD 1000", title: "T", credits: 1)], adviceText: nil, children: [])
        let audit = DegreeAudit(
            goals: DegreeGoals(), isWhatIf: false, percentComplete: 40, degreeLabel: nil,
            catalogYearLabel: nil,
            blocks: [AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil, rules: [rule])],
            courses: [], fetchedAt: Date(timeIntervalSince1970: 0))
        return DegreeLabeledAudit(degreeID: "d1", label: "cs", audit: audit)
    }

    private func decodeResponse(_ json: String) throws -> DegreeAdvisorResponse {
        try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(json.utf8))
    }

    private func planned(_ terms: [(String, [String])]) -> DegreePlan {
        DegreePlan(terms: terms.map { code, courses in
            PlannedTerm(termCode: code, courses: courses.map { PlannedCourse(code: $0, title: nil, credits: 1) })
        })
    }

    private func engineCourse(
        _ code: String, credits: Double = 1, counts: [String] = [], approval: String = "automatic"
    ) -> DegreeEngineCourse {
        DegreeEngineCourse(code: code, title: "t \(code)", credits: credits, countsToward: counts, approval: approval)
    }

    private func enginePlan(_ schedule: [DegreeEngineTerm]) -> DegreeEnginePlan {
        DegreeEnginePlan(
            remainingCredits: 10, remainingCreditsWithoutOverlap: 12, scenarios: [], chosen: "", schedule: schedule)
    }

    // MARK: Request

    @Test("a brief built from audits carries structured data into the request")
    func structuredEncodes() throws {
        let entry = labeledAudit()
        let brief = DegreeAdvisor.brief(
            audits: [entry], plan: .empty, history: ["202610": ["CIS 1100"]], now: now, calendar: calendar)
        let request = DegreeAdvisor.request(question: "q", turns: [], brief: brief, now: now)
        let data = try BackendJSON.encoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let structured = try #require(object["structured"] as? [String: Any])
        #expect(Set(structured.keys) == ["audits", "history", "currentTerm"])
        #expect(structured["currentTerm"] as? String == "202630")
        #expect((structured["history"] as? [String: [String]]) == ["202610": ["CIS 1100"]])
        let audits = try #require(structured["audits"] as? [[String: Any]])
        #expect(audits.count == 1)
        #expect(Set(audits[0].keys) == ["degreeId", "label", "audit"])
        #expect(audits[0]["degreeId"] as? String == "d1")
        #expect(audits[0]["label"] as? String == "cs")

        let back = try BackendJSON.decoder().decode(DegreeAdvisorStructured.self, from: JSONSerialization.data(withJSONObject: structured))
        #expect(back.audits.first?.audit == entry.audit)
        #expect(back == brief.structured)
    }

    @Test("a brief assembled by hand sends no structured key")
    func structuredOmitted() throws {
        let brief = DegreeAdvisorBrief(context: "ctx", terms: [], addable: [:])
        let request = DegreeAdvisor.request(question: "q", turns: [], brief: brief, now: now)
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["structured"] == nil)
    }

    // MARK: Response

    @Test("a full plan decodes")
    func fullPlan() throws {
        let json = """
        {"answer":"a","actions":[],"email":"hi advisor","plan":{
          "remainingCredits":21.5,"remainingCreditsWithoutOverlap":28,
          "scenarios":[{"id":"s1","label":"l","maxLoad":5.5,"summer":false,"finishTerm":"202830","meetsTarget":true}],
          "chosen":"s1",
          "schedule":[{"term":"202710","credits":2,"courses":[
            {"code":"CIS 1100","title":"Intro","credits":1,"countsToward":["major","gen ed"],"approval":"petition","note":"n"}]}],
          "unfilled":[{"degreeLabel":"cs","label":"lab","reason":"none offered"}],
          "petitions":[{"code":"CIS 1100","slots":["a","b"],"savesCredits":1}],
          "notes":["x"]}}
        """
        let response = try decodeResponse(json)
        let plan = try #require(response.plan)
        #expect(response.email == "hi advisor")
        #expect(plan.remainingCredits == 21.5)
        #expect(plan.remainingCreditsWithoutOverlap == 28)
        #expect(plan.chosenScenario?.finishTerm == "202830")
        #expect(plan.schedule.first?.courses.first?.approval == "petition")
        #expect(plan.schedule.first?.courses.first?.countsToward == ["major", "gen ed"])
        #expect(plan.schedule.first?.courses.first?.note == "n")
        #expect(plan.unfilled.first?.reason == "none offered")
        #expect(plan.petitions.first?.slots == ["a", "b"])
        #expect(plan.notes == ["x"])
    }

    @Test("a missing or malformed plan costs the plan only")
    func lenientPlan() throws {
        let none = try decodeResponse(#"{"answer":"a","actions":[]}"#)
        #expect(none.plan == nil && none.email == nil)
        let text = try decodeResponse(#"{"answer":"kept","actions":[],"plan":"oops","email":5}"#)
        #expect(text.plan == nil && text.email == nil && text.answer == "kept")
        let noSchedule = try decodeResponse(#"{"answer":"kept","plan":{"remainingCredits":3}}"#)
        #expect(noSchedule.plan == nil && noSchedule.answer == "kept")
        let scheduleType = try decodeResponse(#"{"answer":"kept","plan":{"schedule":7}}"#)
        #expect(scheduleType.plan == nil)
    }

    @Test("bad elements inside a plan are dropped, the rest kept")
    func badElements() throws {
        let json = """
        {"answer":"a","plan":{"schedule":[
          {"term":"202710","courses":[{"code":"A 1"},{"title":"no code"},7,{"code":"B 2","credits":"x","approval":3}]},
          {"credits":2},"nope"],
         "scenarios":[{"id":"ok"},{"label":"no id"},4],
         "unfilled":[{"label":"x"},{"reason":"no label"}],
         "petitions":[{"code":"C 3","slots":["a",5,"b"]},{"slots":[]}],
         "notes":["n",1]}}
        """
        let plan = try #require(try decodeResponse(json).plan)
        #expect(plan.schedule.count == 1)
        let courses = plan.schedule[0].courses
        #expect(courses.map(\.code) == ["A 1", "B 2"])
        #expect(courses[1].credits == 1)
        #expect(courses[1].approval == "automatic")
        #expect(plan.schedule[0].credits == 2)
        #expect(plan.scenarios.map(\.id) == ["ok"])
        #expect(plan.unfilled.map(\.label) == ["x"])
        #expect(plan.petitions.map(\.code) == ["C 3"])
        #expect(plan.petitions.first?.slots == ["a", "b"])
        #expect(plan.notes == ["n"])
        #expect(plan.remainingCredits == 0)
    }

    // MARK: PlannedCourse

    @Test("a plan file from before the engine fields still decodes")
    func oldPlannedCourse() throws {
        let old = try JSONDecoder().decode(
            PlannedCourse.self, from: Data(#"{"code":"CIS 1100","title":null,"credits":1}"#.utf8))
        #expect(old.countsToward == nil && old.approval == nil)
        let course = PlannedCourse(code: "CIS 1100", title: "t", credits: 1, countsToward: ["a"], approval: "check")
        let back = try JSONDecoder().decode(PlannedCourse.self, from: JSONEncoder().encode(course))
        #expect(back == course)
    }

    @Test("adding a planned course keeps the engine fields")
    func addingCarries() {
        let course = PlannedCourse(code: "cis1100", title: "t", credits: 1, countsToward: ["a"], approval: "petition")
        let plan = DegreePlanMath.adding(course, to: "202710", in: planned([("202710", [])]))
        let held = plan.terms[0].courses.first
        #expect(held?.countsToward == ["a"] && held?.approval == "petition")
        let moved = DegreePlanMath.moving(
            courseCode: "CIS 1100", to: "202730", before: nil, in: DegreePlan(terms: plan.terms + [PlannedTerm(termCode: "202730")]))
        #expect(moved.terms[1].courses.first?.approval == "petition")
    }

    // MARK: applyEnginePlan

    @Test("an engine plan replaces the future and keeps the past")
    func replacesFuture() {
        let existing = planned([("202610", ["OLD 1000"]), ("202630", ["NOW 1000"]),
                                ("202710", ["GONE 1000"]), ("202730", ["GONE 2000"])])
        let schedule = [
            DegreeEngineTerm(term: "202730", credits: 1, courses: [engineCourse("cis3333", counts: ["major"])]),
            DegreeEngineTerm(term: "202710", credits: 1, courses: [engineCourse("CIS 1100")]),
            DegreeEngineTerm(term: "202720", credits: 1,
                             courses: [engineCourse("MATH 1400", counts: ["a", "b", "c"], approval: "petition")]),
            DegreeEngineTerm(term: "202810", credits: 0, courses: []),
        ]
        let outcome = DegreeAdvisor.applyEnginePlan(enginePlan(schedule), to: existing, currentTerm: "202630")
        #expect(outcome.plan.terms.map(\.termCode) == ["202610", "202630", "202710", "202720", "202730"])
        #expect(outcome.plan.terms[0].courses.map(\.code) == ["OLD 1000"])
        #expect(outcome.plan.terms[1].courses.map(\.code) == ["NOW 1000"])
        #expect(!DegreePlanMath.isPlanned("GONE 1000", in: outcome.plan))
        #expect(!DegreePlanMath.isPlanned("GONE 2000", in: outcome.plan))
        let summer = outcome.plan.terms[3].courses[0]
        #expect(summer.code == "MATH 1400" && summer.approval == "petition" && summer.countsToward == ["a", "b", "c"])
        #expect(outcome.plan.terms[4].courses[0].code == "CIS 3333")
        #expect(outcome.plan.terms[2].courses[0].approval == "automatic")
        #expect(outcome.plan.terms[2].courses[0].countsToward == nil)
        #expect(outcome.applied.count == 3 && outcome.skipped == 0)
        #expect(DegreeAdvisor.summary(outcome.applied)
                == ["added CIS 1100 · spring 2027", "added MATH 1400 · summer 2027", "added CIS 3333 · fall 2027"])
    }

    @Test("past terms, repeats and kept codes in a schedule are skipped and counted")
    func skips() {
        let existing = planned([("202610", ["OLD 1000"])])
        let schedule = [
            DegreeEngineTerm(term: "202630", credits: 1, courses: [engineCourse("NOW 1000")]),
            DegreeEngineTerm(term: "202710", credits: 3, courses: [
                engineCourse("OLD 1000"), engineCourse("CIS 1100"), engineCourse("cis1100"), engineCourse("")]),
            DegreeEngineTerm(term: "bad", credits: 1, courses: [engineCourse("X 1")]),
        ]
        let outcome = DegreeAdvisor.applyEnginePlan(enginePlan(schedule), to: existing, currentTerm: "202630")
        #expect(outcome.plan.terms.map(\.termCode) == ["202610", "202710"])
        #expect(outcome.plan.terms[1].courses.map(\.code) == ["CIS 1100"])
        #expect(outcome.skipped == 5)
    }

    @Test("an empty schedule or a bad current term leaves the plan alone")
    func untouched() {
        let existing = planned([("202710", ["KEEP 1000"])])
        let empty = DegreeAdvisor.applyEnginePlan(enginePlan([]), to: existing, currentTerm: "202630")
        #expect(empty.plan == existing && empty.applied.isEmpty)
        let schedule = [DegreeEngineTerm(term: "202710", credits: 1, courses: [engineCourse("A 1000")])]
        let bad = DegreeAdvisor.applyEnginePlan(enginePlan(schedule), to: existing, currentTerm: "nope")
        #expect(bad.plan == existing && bad.skipped == 1)
    }

    @Test("an engine plan that spends more columns than the cap loses its latest ones")
    func capped() {
        var schedule: [DegreeEngineTerm] = []
        var code = "202710"
        for _ in 0..<(DegreePlanMath.maxTerms + 3) {
            schedule.append(DegreeEngineTerm(term: code, credits: 1, courses: [engineCourse("C \(code)")]))
            code = DegreePlanMath.nextTermCode(after: code) ?? code
        }
        let outcome = DegreeAdvisor.applyEnginePlan(enginePlan(schedule), to: .empty, currentTerm: "202630")
        #expect(outcome.plan.terms.count == DegreePlanMath.maxTerms)
        #expect(outcome.skipped == 3)
    }

    // MARK: Table

    @Test("a summer plan term is its own column between spring and fall")
    func summerColumn() {
        let plan = planned([("202710", ["A 1000"]), ("202720", ["B 1000"]), ("202730", ["C 1000"])])
        let columns = DegreeTimeline.columns(history: [:], plan: plan, audit: nil, now: now, calendar: calendar)
        #expect(columns.map(\.termCode) == ["202710", "202720", "202730"])
        #expect(columns[1].kind == .future && columns[1].planned.map(\.code) == ["B 1000"])
    }

    @Test("the table's engine lines and approval tags")
    func tableHelpers() {
        let course = PlannedCourse(code: "A 1", title: nil, credits: 1, countsToward: ["x", "", "y", "z"], approval: "petition")
        #expect(DegreeSemesterTable.engineLines(course) == ["x", "y"])
        #expect(DegreeSemesterTable.engineLines(PlannedCourse(code: "A 1", title: nil, credits: 1)).isEmpty)
        #expect(DegreeSemesterTable.approvalTag("petition") == "ask advisor")
        #expect(DegreeSemesterTable.approvalTag("check") == "check")
        #expect(DegreeSemesterTable.approvalTag("automatic") == nil)
        #expect(DegreeSemesterTable.approvalTag(nil) == nil)
    }

    // MARK: Card lines

    @Test("the card's lines: scenarios, totals, unfilled and petitions with their caps")
    func cardLines() {
        let plan = DegreeEnginePlan(
            remainingCredits: 21.5, remainingCreditsWithoutOverlap: 28,
            scenarios: [
                DegreeEngineScenario(id: "a", label: "", maxLoad: 5.5, summer: false, finishTerm: "202830", meetsTarget: false),
                DegreeEngineScenario(id: "b", label: "", maxLoad: 6.5, summer: true, finishTerm: "202810", meetsTarget: true),
                DegreeEngineScenario(id: "c", label: "", maxLoad: 5, summer: false, finishTerm: nil, meetsTarget: false),
            ],
            chosen: "b", schedule: [],
            unfilled: (1...6).map { DegreeEngineUnfilled(degreeLabel: "d", label: "req \($0)", reason: $0 == 1 ? "" : "no options") },
            petitions: (1...5).map { DegreeEnginePetition(code: "P \($0)", slots: ["a", "b"], savesCredits: 1) })
        let lines = DegreeAdvisorView.planLines(plan)
        #expect(lines.scenarios.map(\.text) == [
            "5.5 cu · no summer → fall 2028", "6.5 cu · summer → spring 2028", "5 cu · no summer"])
        #expect(lines.scenarios.map(\.isChosen) == [false, true, false])
        #expect(lines.scenarios.map(\.meetsTarget) == [false, true, false])
        #expect(lines.totals == "21.5 cu left · 28 without double counting")
        #expect(lines.unfilled == [
            "not planned: req 1", "not planned: req 2 · no options", "not planned: req 3 · no options",
            "not planned: req 4 · no options", "+2 more"])
        #expect(lines.petitions == [
            "ask your advisor: P 1 for a + b", "ask your advisor: P 2 for a + b",
            "ask your advisor: P 3 for a + b", "+2 more"])
    }
}
