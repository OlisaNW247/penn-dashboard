import Foundation
import LowHangingFruitKit

// The road's state: the one-line read of the plan, and a planner run that goes
// on in the background. A run is the chat's own send (`askDegreeAdvisor`) made
// without the sheet, so closing a screen does not end it, and the screens
// watch `degreePlannerRun` to show what it is doing and what it changed.

/// Where a planner run stands.
enum DegreePlannerRun: Equatable {
    case idle
    case running(stage: String)
    /// Done: the finish term before and after, the plan to undo to (nil when
    /// nothing changed) and the model's answer.
    case finished(finishBefore: String?, finishAfter: String?, planBefore: DegreePlan?, answer: String)
    /// Failed: the line to show, whether asking again can help, and the
    /// question to ask again.
    case failed(line: String, canRetry: Bool, question: String)
}

extension AppState {
    /// The fixed message the "plan the rest" button sends.
    nonisolated static let degreePlanTheRestPrompt = "plan the rest of my degree"

    /// Whether closing the advisor questions should re-run the planner: an
    /// answer changed since the plan was made and no run is already going.
    nonisolated static func degreeShouldAutoUpdate(notes: DegreeAdvisorNotes?, running: Bool) -> Bool {
        !running && notes?.hasChanges == true
    }

    /// The road for the plan as the table draws it now.
    var degreeRoad: DegreeRoad {
        let audits = degreeAudits
        var lookup: DegreeAudit?
        if let first = audits.first?.audit {
            if audits.count == 1 {
                lookup = first
            } else {
                lookup = DegreeAudit(
                    goals: first.goals, isWhatIf: first.isWhatIf, percentComplete: first.percentComplete,
                    degreeLabel: first.degreeLabel, catalogYearLabel: first.catalogYearLabel,
                    blocks: first.blocks, courses: DegreeOverall.mergedCourses(audits),
                    fetchedAt: first.fetchedAt)
            }
        }
        let columns = DegreeTimeline.columns(
            history: degree.history, plan: degreePlan, audit: lookup, now: Date())
        return DegreeRoad.make(columns: columns, plan: degreePlan)
    }

    var degreePlannerIsRunning: Bool {
        if case .running = degreePlannerRun { return true }
        return false
    }

    /// Asks the planner `question` the way the chat does, but from here: the
    /// question and the reply join `degreeAdvisorMessages`, and the run's
    /// progress and result are in `degreePlannerRun`. A no-op while a run is
    /// going or for an empty question.
    func runDegreePlanner(question raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !degreePlannerIsRunning, !question.isEmpty else { return }
        let turns: [DegreeAdvisorTurn] = degreeAdvisorMessages.compactMap { message in
            message.failed ? nil
                : DegreeAdvisorTurn(role: message.isUser ? "user" : "assistant", content: message.text)
        }
        degreeAdvisorMessages.append(DegreeAdvisorMessage(
            id: UUID(), isUser: true, text: question, changes: [], planBefore: nil,
            undone: false, failed: false))
        degreePlannerRun = .running(stage: "planning…")
        let finishBefore = degreePlan.summary?.finishTerm
        let audits = degreeAudits
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.askDegreeAdvisor(
                question: question, turns: turns, audits: audits,
                onStage: { [weak self] stage in self?.degreePlannerRun = .running(stage: stage) })
            self.degreeAdvisorMessages.append(DegreeAdvisorMessage(
                id: UUID(), isUser: false, text: reply.answer, changes: reply.changes,
                planBefore: reply.planBefore, undone: false, failed: reply.failed,
                notice: reply.notice,
                planLines: reply.plan.map { DegreeAdvisorView.planLines($0) },
                email: reply.email, canRetry: reply.canRetry))
            if reply.failed {
                self.degreePlannerRun = .failed(
                    line: reply.answer, canRetry: reply.canRetry, question: question)
            } else {
                self.degreePlannerRun = .finished(
                    finishBefore: finishBefore, finishAfter: self.degreePlan.summary?.finishTerm,
                    planBefore: reply.planBefore, answer: reply.answer)
            }
        }
    }

    /// Asks again after a failed run. The failed exchange's lines go first, so
    /// the retry is not a repeat of the failure in the conversation.
    func retryDegreePlanner() {
        guard case let .failed(_, _, question) = degreePlannerRun else { return }
        if let last = degreeAdvisorMessages.last, !last.isUser, last.failed {
            degreeAdvisorMessages.removeLast()
        }
        if let last = degreeAdvisorMessages.last, last.isUser, last.text == question {
            degreeAdvisorMessages.removeLast()
        }
        degreePlannerRun = .idle
        runDegreePlanner(question: question)
    }

    /// Puts the plan back as it was before a finished run, then clears it.
    func undoDegreePlannerRun() {
        guard case let .finished(_, _, planBefore, _) = degreePlannerRun else { return }
        if let planBefore {
            undoDegreeAdvisor(to: planBefore)
            if let index = degreeAdvisorMessages.lastIndex(where: { !$0.isUser && $0.planBefore != nil }) {
                degreeAdvisorMessages[index].undone = true
            }
        }
        degreePlannerRun = .idle
    }

    func dismissDegreePlannerResult() {
        guard !degreePlannerIsRunning else { return }
        degreePlannerRun = .idle
    }

    /// Called when the advisor questions close: if an answer changed since the
    /// plan was made, the planner runs again with them.
    func degreeAdvisorQuestionsClosed() {
        guard Self.degreeShouldAutoUpdate(notes: degreePlan.advisor, running: degreePlannerIsRunning) else { return }
        runDegreePlanner(question: DegreeAdvisorQuestionsSheet.updatePrompt)
    }
}
