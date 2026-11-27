import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Degree road state")
struct DegreeRoadStateTests {
    private func notes(answers: [String: DegreeAdvisorAnswer], atLastPlan: [String: DegreeAdvisorAnswer])
        -> DegreeAdvisorNotes {
        DegreeAdvisorNotes(
            questions: [DegreeAdvisorQuestion(id: "a", kind: "load", question: "q")],
            answers: answers, answersAtLastPlan: atLastPlan)
    }

    @Test("closing the questions re-runs the planner only after a change and when idle")
    func autoUpdateGate() {
        let changed = notes(answers: ["a": .yes], atLastPlan: [:])
        let same = notes(answers: ["a": .yes], atLastPlan: ["a": .yes])
        #expect(AppState.degreeShouldAutoUpdate(notes: changed, running: false))
        #expect(!AppState.degreeShouldAutoUpdate(notes: changed, running: true))
        #expect(!AppState.degreeShouldAutoUpdate(notes: same, running: false))
        #expect(!AppState.degreeShouldAutoUpdate(notes: nil, running: false))
    }

    @Test("an answer cleared since the last plan is a change")
    func clearedIsAChange() {
        let cleared = notes(answers: [:], atLastPlan: ["a": .no])
        #expect(AppState.degreeShouldAutoUpdate(notes: cleared, running: false))
    }

    @Test("the plan-the-rest prompt is a plain sentence")
    func prompt() {
        #expect(AppState.degreePlanTheRestPrompt == "plan the rest of my degree")
    }

    @Test("the run states compare")
    func runStates() {
        #expect(DegreePlannerRun.idle == .idle)
        #expect(DegreePlannerRun.running(stage: "a") != .running(stage: "b"))
        #expect(DegreePlannerRun.failed(line: "l", canRetry: true, question: "q")
                == .failed(line: "l", canRetry: true, question: "q"))
    }
}
