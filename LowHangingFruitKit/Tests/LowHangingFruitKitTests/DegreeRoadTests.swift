import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree road")
struct DegreeRoadTests {
    private func taken(_ codes: [String], credits: Double = 1) -> [TimelineCourse] {
        codes.map { TimelineCourse(code: $0, title: nil, credits: credits) }
    }

    private func planned(_ codes: [String], credits: Double = 1) -> [PlannedCourse] {
        codes.map { PlannedCourse(code: $0, title: nil, credits: credits) }
    }

    private func past(_ term: String, _ codes: [String]) -> TimelineColumn {
        TimelineColumn(termCode: term, kind: .past, taken: taken(codes), planned: [])
    }

    private func now(_ term: String, _ codes: [String]) -> TimelineColumn {
        TimelineColumn(termCode: term, kind: .current, taken: taken(codes), planned: [])
    }

    private func future(_ term: String, taken t: [String] = [], planned p: [String] = [], credits: Double = 1) -> TimelineColumn {
        TimelineColumn(termCode: term, kind: .future, taken: taken(t, credits: credits), planned: planned(p, credits: credits))
    }

    private func summary(finish: String?, best: DegreePlanBestCase? = nil) -> DegreePlanSummary {
        DegreePlanSummary(
            finishTerm: finish, scenarioID: "standard", scenarioLabel: "standard", remainingCredits: nil,
            needsApproval: false, createdAt: Date(timeIntervalSince1970: 0), bestCase: best)
    }

    private func notes(_ ids: [String], answers: [String: DegreeAdvisorAnswer] = [:]) -> DegreeAdvisorNotes {
        DegreeAdvisorNotes(
            questions: ids.map { DegreeAdvisorQuestion(id: $0, kind: "load", question: "q \($0)") },
            answers: answers, answersAtLastPlan: answers)
    }

    private func termInfo(_ stop: DegreeRoadStop)
        -> (String, DegreeRoadTermState, Int, Double, Bool, Bool)? {
        if case .term(let code, let state, let classes, let credits, let over, let finish) = stop.kind {
            return (code, state, classes, credits, over, finish)
        }
        return nil
    }

    // MARK: Stops

    @Test("every past semester folds into one done stop, first")
    func foldsPast() {
        let road = DegreeRoad.make(
            columns: [past("202410", ["A 1", "A 2"]), past("202430", ["B 1"]), now("202630", ["C 1"])],
            plan: .empty)
        #expect(road.stops.count == 2)
        #expect(road.stops[0].id == "done")
        #expect(road.stops[0].kind == .done(termCodes: ["202410", "202430"], classes: 3))
        #expect(road.stops[1].id == "202630")
    }

    @Test("no past columns, no done stop")
    func noDone() {
        let road = DegreeRoad.make(columns: [now("202630", ["C 1"])], plan: .empty)
        #expect(road.stops.map(\.id) == ["202630"])
    }

    @Test("now, registered, planned and empty states, with classes and credits")
    func states() throws {
        let columns = [
            now("202630", ["C 1", "C 2"]),
            future("202710", taken: ["R 1"]),
            future("202730", planned: ["P 1", "P 2"]),
            future("202810"),
            future("202830", planned: ["P 3"]),
        ]
        let road = DegreeRoad.make(columns: columns, plan: .empty)
        let infos = road.stops.compactMap(termInfo)
        #expect(infos.map(\.1) == [.now, .registered, .planned, .empty, .planned])
        #expect(infos.map(\.2) == [2, 1, 2, 0, 1])
        #expect(infos[2].3 == 2)
        #expect(infos.allSatisfy { !$0.4 })
    }

    @Test("over the limit only on future columns")
    func overLimit() throws {
        let columns = [
            now("202630", ["A", "B", "C", "D", "E", "F", "G", "H"]),
            future("202710", planned: ["A", "B", "C", "D", "E", "F", "G", "H"]),
        ]
        let infos = DegreeRoad.make(columns: columns, plan: .empty).stops.compactMap(termInfo)
        #expect(infos[0].4 == false)
        #expect(infos[1].4 == true)
    }

    // MARK: Finish

    @Test("the finish comes from the summary and is checked")
    func finishFromSummary() {
        let plan = DegreePlan(summary: summary(finish: "202810"))
        let columns = [now("202630", ["C 1"]), future("202710", planned: ["P 1"]), future("202730", planned: ["P 2"]),
                       future("202810", planned: ["P 3"])]
        let road = DegreeRoad.make(columns: columns, plan: plan)
        #expect(road.headline == .finish(termCode: "202810", semestersToGo: 4, checked: true))
        #expect(road.stops.compactMap(termInfo).map(\.5) == [false, false, false, true])
    }

    @Test("with no summary the last planned semester is the finish, unchecked")
    func finishFromLast() {
        let columns = [now("202630", ["C 1"]), future("202710", planned: ["P 1"]), future("202730"),
                       future("202810", planned: ["P 2"]), future("202830")]
        let road = DegreeRoad.make(columns: columns, plan: .empty)
        #expect(road.headline == .finish(termCode: "202810", semestersToGo: 3, checked: false))
    }

    @Test("empty columns after the finish are dropped, earlier ones stay")
    func trailingEmptyDropped() {
        let columns = [now("202630", ["C 1"]), future("202710"), future("202730", planned: ["P 1"]),
                       future("202810"), future("202830")]
        let road = DegreeRoad.make(columns: columns, plan: .empty)
        #expect(road.stops.map(\.id) == ["202630", "202710", "202730"])
    }

    @Test("no plan and nothing ahead is no plan")
    func noPlanHeadline() {
        let road = DegreeRoad.make(columns: [now("202630", ["C 1"]), future("202710")], plan: .empty)
        #expect(road.headline == .noPlan)
        #expect(road.nextStep == .planTheRest)
        #expect(road.nextStepStopID == "202710")
    }

    @Test("registered courses alone are not a plan: no finish, plan the rest")
    func registeredOnlyIsNoPlan() {
        let road = DegreeRoad.make(
            columns: [now("202630", ["C 1"]), future("202710", taken: ["R 1", "R 2"])], plan: .empty)
        #expect(road.headline == .noPlan)
        #expect(road.nextStep == .planTheRest)
        #expect(road.stops.map(\.id) == ["202630", "202710"])
    }

    @Test("semesters to go counts only semesters that hold classes")
    func semestersToGo() {
        let plan = DegreePlan(summary: summary(finish: "202810"))
        let columns = [now("202630", ["C 1"]), future("202710"), future("202730", planned: ["P 1"]),
                       future("202810", planned: ["P 2"])]
        let road = DegreeRoad.make(columns: columns, plan: plan)
        #expect(road.headline == .finish(termCode: "202810", semestersToGo: 3, checked: true))
    }

    @Test("with no current column the first future one starts the count")
    func noCurrent() {
        let columns = [past("202610", ["A 1"]), future("202710", planned: ["P 1"]), future("202730", planned: ["P 2"])]
        let road = DegreeRoad.make(columns: columns, plan: .empty)
        #expect(road.headline == .finish(termCode: "202730", semestersToGo: 2, checked: false))
    }

    // MARK: Advisor

    @Test("the advisor stop sits before the first planned semester, with counts")
    func advisorPlacement() {
        let plan = DegreePlan(advisor: notes(["a", "b", "c"], answers: ["a": .yes]))
        let columns = [now("202630", ["C 1"]), future("202710", taken: ["R 1"]), future("202730", planned: ["P 1"])]
        let road = DegreeRoad.make(columns: columns, plan: plan)
        #expect(road.stops.map(\.id) == ["202630", "202710", "advisor", "202730"])
        #expect(road.stops[2].kind == .advisor(open: 2, total: 3))
    }

    @Test("with no planned semester the advisor stop is last")
    func advisorLast() {
        let plan = DegreePlan(advisor: notes(["a"]))
        let road = DegreeRoad.make(columns: [now("202630", ["C 1"]), future("202710", taken: ["R 1"])], plan: plan)
        #expect(road.stops.last?.id == "advisor")
    }

    @Test("no questions, no advisor stop")
    func noAdvisor() {
        let plan = DegreePlan(advisor: DegreeAdvisorNotes())
        let road = DegreeRoad.make(columns: [now("202630", ["C 1"]), future("202710", planned: ["P"])], plan: plan)
        #expect(!road.stops.contains { $0.id == "advisor" })
    }

    // MARK: Sooner

    @Test("sooner shows only when the best case is strictly earlier")
    func soonerOnlyWhenEarlier() {
        let columns = [now("202630", ["C 1"]), future("202710", planned: ["P"])]
        let earlier = DegreePlan(summary: summary(finish: "202810", best: DegreePlanBestCase(finishTerm: "202730", approvals: ["a", "b"])))
        let same = DegreePlan(summary: summary(finish: "202810", best: DegreePlanBestCase(finishTerm: "202810", approvals: ["a"])))
        let none = DegreePlan(summary: summary(finish: "202810", best: DegreePlanBestCase(finishTerm: nil, approvals: ["a"])))
        #expect(DegreeRoad.make(columns: columns, plan: earlier).sooner == DegreeRoadSooner(termCode: "202730", answersNeeded: 2))
        #expect(DegreeRoad.make(columns: columns, plan: same).sooner == nil)
        #expect(DegreeRoad.make(columns: columns, plan: none).sooner == nil)
        #expect(DegreeRoad.make(columns: columns, plan: .empty).sooner == nil)
    }

    @Test("answers needed come from the advisor's questions when there are any")
    func soonerFromNotes() {
        let best = DegreePlanBestCase(finishTerm: "202730", approvals: ["x"])
        let plan = DegreePlan(
            summary: summary(finish: "202810", best: best),
            advisor: notes(["a", "b", "c"], answers: ["a": .yes, "b": .no]))
        let road = DegreeRoad.make(columns: [now("202630", ["C 1"]), future("202710", planned: ["P"])], plan: plan)
        #expect(road.sooner?.answersNeeded == 2)
    }

    // MARK: Next step

    @Test("plan the rest when no semester is planned, attached to the last stop")
    func nextPlanTheRest() {
        let columns = [now("202630", ["C 1"]), future("202710", taken: ["R 1"])]
        let road = DegreeRoad.make(columns: columns, plan: .empty)
        #expect(road.nextStep == .planTheRest)
        #expect(road.nextStepStopID == "202710")
        #expect(DegreeRoad.make(columns: [], plan: .empty).nextStepStopID == nil)
    }

    @Test("ask your advisor when planned and questions are open")
    func nextAskAdvisor() {
        let plan = DegreePlan(advisor: notes(["a", "b"], answers: ["a": .yes]))
        let road = DegreeRoad.make(columns: [now("202630", ["C 1"]), future("202710", planned: ["P"])], plan: plan)
        #expect(road.nextStep == .askAdvisor)
        #expect(road.nextStepStopID == "advisor")
    }

    @Test("room for more in the first future fall or spring term under the typical load")
    func nextRoom() {
        let columns = [now("202630", ["C 1"]), future("202710", planned: ["P 1", "P 2", "P 3"]),
                       future("202720", planned: ["S 1"]), future("202730", planned: ["P 4", "P 5", "P 6", "P 7", "P 8"])]
        let road = DegreeRoad.make(columns: columns, plan: .empty)
        #expect(road.nextStep == .room(termCode: "202710", more: 2))
        #expect(road.nextStepStopID == "202710")
    }

    @Test("a summer is never offered room, and a full plan has no next step")
    func nextNone() {
        let full = (1...5).map { "P \($0)" }
        let summerOnly = [now("202630", ["C 1"]), future("202710", planned: full), future("202720", planned: ["S 1"])]
        let road = DegreeRoad.make(columns: summerOnly, plan: .empty)
        #expect(road.nextStep == nil)
        #expect(road.nextStepStopID == nil)
    }

    @Test("advisor questions outrank room for more")
    func nextPriority() {
        let plan = DegreePlan(advisor: notes(["a"]))
        let road = DegreeRoad.make(columns: [now("202630", ["C 1"]), future("202710", planned: ["P"])], plan: plan)
        #expect(road.nextStep == .askAdvisor)
    }

    // MARK: Words

    @Test("the words, singular and plural")
    func words() {
        #expect(DegreeRoad.semestersText(1) == "1 semester to go")
        #expect(DegreeRoad.semestersText(5) == "5 semesters to go")
        #expect(DegreeRoad.semestersText(0) == "last semester")
        #expect(DegreeRoad.soonerText(DegreeRoadSooner(termCode: "202830", answersNeeded: 1)) == "fall 2028 if 1 answer is yes")
        #expect(DegreeRoad.soonerText(DegreeRoadSooner(termCode: "202830", answersNeeded: 2)) == "fall 2028 if 2 answers are yes")
        #expect(DegreeRoad.soonerText(DegreeRoadSooner(termCode: "202830", answersNeeded: 0)) == "fall 2028 with your advisor's yes")
        #expect(DegreeRoad.stateWord(.now) == "now")
        #expect(DegreeRoad.stateWord(.registered) == "registered")
        #expect(DegreeRoad.stateWord(.planned) == "planned")
        #expect(DegreeRoad.stateWord(.empty) == "nothing planned")
        #expect(DegreeRoad.nextStepText(.planTheRest) == "plan the rest")
        #expect(DegreeRoad.nextStepText(.askAdvisor) == "ask your advisor")
        #expect(DegreeRoad.nextStepText(.room(termCode: "202710", more: 1)) == "room for 1 more")
        #expect(DegreeRoad.nextStepText(.room(termCode: "202710", more: 2)) == "room for 2 more")
        #expect(DegreeRoad.classesText(1) == "1 class")
        #expect(DegreeRoad.classesText(5) == "5 classes")
    }

    @Test("no word the copy rules forbid")
    func forbiddenWords() {
        let forbidden = ["graduate", "recommend", "on track", "eligible", "average"]
        var all: [String] = [DegreeRoad.semestersText(3), DegreeRoad.classesText(2)]
        all.append(DegreeRoad.soonerText(DegreeRoadSooner(termCode: "202830", answersNeeded: 2)))
        all += [DegreeRoadTermState.now, .registered, .planned, .empty].map(DegreeRoad.stateWord)
        all += [DegreeRoadNextStep.planTheRest, .askAdvisor, .room(termCode: "202710", more: 2)].map(DegreeRoad.nextStepText)
        for text in all {
            #expect(text == text.lowercased())
            for word in forbidden { #expect(!text.contains(word)) }
        }
    }

    // MARK: Best case wire

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test("best case decodes leniently")
    func bestCaseDecoding() throws {
        let full = try decode(DegreePlanBestCase.self, #"{"finishTerm":"202730","approvals":["a","b"]}"#)
        #expect(full == DegreePlanBestCase(finishTerm: "202730", approvals: ["a", "b"]))
        let missing = try decode(DegreePlanBestCase.self, #"{"finishTerm":null}"#)
        #expect(missing == DegreePlanBestCase(finishTerm: nil, approvals: []))
        let mixed = try decode(DegreePlanBestCase.self, #"{"finishTerm":"202730","approvals":["a",3,null,"b"]}"#)
        #expect(mixed.approvals == ["a", "b"])
    }

    @Test("a malformed best case on a summary costs only itself")
    func bestCaseOnSummary() throws {
        let good = try decode(
            DegreePlanSummary.self,
            #"{"finishTerm":"202810","scenarioID":"s","scenarioLabel":"l","needsApproval":false,"bestCase":{"finishTerm":"202730","approvals":["x"]}}"#)
        #expect(good.bestCase == DegreePlanBestCase(finishTerm: "202730", approvals: ["x"]))
        let bad = try decode(
            DegreePlanSummary.self,
            #"{"finishTerm":"202810","scenarioID":"s","scenarioLabel":"l","needsApproval":true,"bestCase":"soon"}"#)
        #expect(bad.bestCase == nil && bad.finishTerm == "202810" && bad.needsApproval)
        let absent = try decode(DegreePlanSummary.self, #"{"finishTerm":"202810"}"#)
        #expect(absent.bestCase == nil)
    }

    @Test("a malformed best case on an engine plan leaves the schedule")
    func bestCaseOnEnginePlan() throws {
        let ok = try decode(DegreeEnginePlan.self, #"{"schedule":[],"bestCase":{"finishTerm":"202730","approvals":["x"]}}"#)
        #expect(ok.bestCase == DegreePlanBestCase(finishTerm: "202730", approvals: ["x"]))
        let bad = try decode(DegreeEnginePlan.self, #"{"schedule":[],"bestCase":[1,2]}"#)
        #expect(bad.bestCase == nil)
        let absent = try decode(DegreeEnginePlan.self, #"{"schedule":[]}"#)
        #expect(absent.bestCase == nil)
    }

    @Test("a summary survives an encode and decode with its best case")
    func bestCaseRoundTrip() throws {
        let original = summary(finish: "202810", best: DegreePlanBestCase(finishTerm: "202730", approvals: ["x"]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DegreePlanSummary.self, from: encoder.encode(original))
        #expect(back.bestCase == original.bestCase)
    }

    @Test("applyEnginePlan copies the best case onto the summary")
    func applyCopiesBestCase() {
        let scenario = DegreeEngineScenario(
            id: "standard", label: "standard", maxLoad: 5.5, summer: false, finishTerm: "202810", meetsTarget: true)
        let plan = DegreeEnginePlan(
            remainingCredits: 4, remainingCreditsWithoutOverlap: 4, scenarios: [scenario], chosen: "standard",
            schedule: [DegreeEngineTerm(
                term: "202710", credits: 1,
                courses: [DegreeEngineCourse(code: "CIS 1100", title: "t", credits: 1, countsToward: [], approval: "automatic")])],
            bestCase: DegreePlanBestCase(finishTerm: "202730", approvals: ["load"]))
        let outcome = DegreeAdvisor.applyEnginePlan(plan, to: .empty, currentTerm: "202630")
        #expect(outcome.plan.summary?.bestCase == DegreePlanBestCase(finishTerm: "202730", approvals: ["load"]))
    }
}
