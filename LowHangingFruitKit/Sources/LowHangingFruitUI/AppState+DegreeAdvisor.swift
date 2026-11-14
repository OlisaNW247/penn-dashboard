import Foundation
import LowHangingFruitKit

// The degree screen's chat is the one place degree data leaves the phone. It
// happens only when the student sends a message: the audit as text, the
// planned courses, the question and the last few turns go to smooth's server,
// which answers and stores none of it. The model's answer may carry edits to
// the plan (add, remove, move); `DegreeAdvisor.apply` checks each against what
// the phone offered, so a made-up course or term is skipped, never filed.

/// What one question came back with.
struct DegreeAdvisorReply: Sendable, Equatable {
    let answer: String
    let changes: [DegreeAdvisorChange]
    /// The plan as it was before the edits; non-nil only when the plan changed.
    let planBefore: DegreePlan?
    let failed: Bool
}

extension AppState {
    /// Whether the chat can be offered: the degree feature is on and either
    /// this is the demo or a backend client exists.
    var degreeAdvisorAvailable: Bool {
        degreeFeatureAvailable && (isUsingFixtureData || BackendServices.client != nil)
    }

    /// One question. `audits` is what the screen is drawing, so a what-if on
    /// screen is what the advisor reasons about. Edits are applied at once to
    /// the plan as it is after the network round trip (the student may have
    /// dragged a course meanwhile), through the same commit the other plan
    /// edits use.
    func askDegreeAdvisor(question: String, turns: [DegreeAdvisorTurn],
                          audits: [DegreeLabeledAudit]) async -> DegreeAdvisorReply {
        loadDegreePlanIfNeeded()
        if isUsingFixtureData {
            return DegreeAdvisorReply(
                answer: "this is the demo. connect canvas at penn to ask about your own audit.",
                changes: [], planBefore: nil, failed: false)
        }
        guard let client = BackendServices.client else {
            return DegreeAdvisorReply(answer: Self.degreeAdvisorFailureLine(BackendError.notConfigured),
                                      changes: [], planBefore: nil, failed: true)
        }
        let now = Date()
        let brief = DegreeAdvisor.brief(audits: audits, plan: degreePlan,
                                        history: degree.history, now: now)
        let request = DegreeAdvisor.request(question: question, turns: turns, brief: brief, now: now)
        do {
            let response = try await client.degreeAdvisor(request)
            let before = degreePlan
            let outcome = DegreeAdvisor.apply(response.actions, to: before, brief: brief)
            let changed = outcome.plan != before
            if changed { commitDegreePlan(outcome.plan) }
            return DegreeAdvisorReply(answer: response.answer,
                                      changes: changed ? outcome.applied : [],
                                      planBefore: changed ? before : nil,
                                      failed: false)
        } catch {
            return DegreeAdvisorReply(answer: Self.degreeAdvisorFailureLine(error),
                                      changes: [], planBefore: nil, failed: true)
        }
    }

    /// Puts back the plan a reply replaced. It restores unconditionally: the
    /// view offers undo only on the latest edit, and a student who edited by
    /// hand since is asking for the plan as it was.
    func undoDegreeAdvisor(to plan: DegreePlan) {
        commitDegreePlan(plan)
    }

    nonisolated static func degreeAdvisorFailureLine(_ error: Error) -> String {
        switch error as? BackendError {
        case .quotaExceeded?: return "that's today's limit. try again tomorrow."
        case .http(426)?: return "update smooth to use this."
        default: return "couldn't reach smooth."
        }
    }
}
