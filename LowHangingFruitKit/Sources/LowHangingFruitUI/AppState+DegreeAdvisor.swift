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
    /// Non-nil only when a what-if audit was fetched: the audits the answer was
    /// planned against, for the view to keep using on the next question.
    let audits: [DegreeLabeledAudit]?
    /// A line for the chat when a what-if was read, e.g. "read path@penn's audit for finance".
    let notice: String?

    init(answer: String, changes: [DegreeAdvisorChange], planBefore: DegreePlan?, failed: Bool,
         audits: [DegreeLabeledAudit]? = nil, notice: String? = nil) {
        self.answer = answer
        self.changes = changes
        self.planBefore = planBefore
        self.failed = failed
        self.audits = audits
        self.notice = notice
    }
}

extension AppState {
    /// Whether the chat can be offered: the degree feature is on and either
    /// this is the demo or a backend client exists.
    var degreeAdvisorAvailable: Bool {
        degreeFeatureAvailable && (isUsingFixtureData || BackendServices.client != nil)
    }

    /// One question, in up to two passes. `audits` is what the screen is
    /// drawing, so a what-if on screen is what the advisor reasons about.
    ///
    /// Pass one sends the question with the list of programs the phone could
    /// fetch an audit for. If the server answers `whatIf` (a program code
    /// instead of a plan), the phone fetches that what-if from Penn, swaps it
    /// in for the degree it stands in for, and asks the same question again.
    /// The phone does the fetching and not the server because only the phone
    /// holds the Penn session; the server never sees a credential. The second
    /// request sends `programs: []`, so the model cannot ask again: that is the
    /// loop guard, and a send costs at most one Penn read and two requests.
    /// Edits are applied at once to the plan as it is after the network round
    /// trip (the student may have dragged a course meanwhile), through the same
    /// commit the other plan edits use.
    func askDegreeAdvisor(question: String, turns: [DegreeAdvisorTurn],
                          audits: [DegreeLabeledAudit],
                          onStage: @MainActor (String) -> Void = { _ in }) async -> DegreeAdvisorReply {
        loadDegreePlanIfNeeded()
        if isUsingFixtureData {
            return DegreeAdvisorReply(
                answer: "this is the demo. connect canvas at penn to ask about your own audit.",
                changes: [], planBefore: nil, failed: false, audits: nil, notice: nil)
        }
        guard let client = BackendServices.client else {
            return DegreeAdvisorReply(answer: Self.degreeAdvisorFailureLine(BackendError.notConfigured),
                                      changes: [], planBefore: nil, failed: true, audits: nil, notice: nil)
        }
        let now = Date()
        let brief = DegreeAdvisor.brief(audits: audits, plan: degreePlan,
                                        history: degree.history, now: now)
        #if DEBUG
        Self.writeDegreeAdvisorDiagnostics(brief: brief, audits: audits)
        #endif
        // The catalogue is only used if already loaded: asking for it here
        // would start a Penn sign-in before the student has asked for anything
        // that needs one. An empty catalogue means no what-if can be offered.
        let catalogue = degree.programs
        let entries = catalogue.isEmpty ? [] : degreeProgramEntries(catalogue)
        let programs = DegreeAdvisor.programs(from: entries)
        let request = DegreeAdvisor.request(question: question, turns: turns, brief: brief,
                                            programs: programs, now: now)
        let first: DegreeAdvisorResponse
        do {
            first = try await client.degreeAdvisor(request)
        } catch {
            return DegreeAdvisorReply(answer: Self.degreeAdvisorFailureLine(error),
                                      changes: [], planBefore: nil, failed: true, audits: nil, notice: nil)
        }
        Self.noteDegreeAdvisorModel(first.model)

        guard let wanted = first.whatIf,
              let entry = entries.first(where: { $0.listing.code == wanted && $0.degreeID != nil })
        else {
            return finishDegreeAdvisor(first, brief: brief, audits: nil, notice: nil)
        }

        onStage("reading path@penn for \(entry.name)…")
        guard let whatIf = await fetchDegreeAdvisorWhatIf(entry) else {
            return DegreeAdvisorReply(
                answer: "couldn't read path@penn's audit for \(entry.name).",
                changes: [], planBefore: nil, failed: true, audits: nil, notice: nil)
        }
        let degreeID = entry.degreeID ?? ""
        let swapped = Self.degreeAdvisorAudits(audits, replacing: degreeID, with: whatIf, name: entry.name)
        let notice = "read path@penn's audit for \(entry.name)"

        onStage("planning…")
        let secondBrief = DegreeAdvisor.brief(audits: swapped, plan: degreePlan,
                                              history: degree.history, now: now)
        #if DEBUG
        Self.writeDegreeAdvisorDiagnostics(brief: secondBrief, audits: swapped)
        #endif
        let second = DegreeAdvisor.request(question: question, turns: turns, brief: secondBrief,
                                           programs: [], now: now)
        do {
            let response = try await client.degreeAdvisor(second)
            Self.noteDegreeAdvisorModel(response.model)
            return finishDegreeAdvisor(response, brief: secondBrief, audits: swapped, notice: notice)
        } catch {
            return DegreeAdvisorReply(answer: Self.degreeAdvisorFailureLine(error),
                                      changes: [], planBefore: nil, failed: true,
                                      audits: swapped, notice: nil)
        }
    }

    /// Applies a response's edits to the live plan and builds the reply.
    private func finishDegreeAdvisor(_ response: DegreeAdvisorResponse, brief: DegreeAdvisorBrief,
                                     audits: [DegreeLabeledAudit]?, notice: String?) -> DegreeAdvisorReply {
        let before = degreePlan
        let outcome = DegreeAdvisor.apply(response.actions, to: before, brief: brief)
        let changed = outcome.plan != before
        if changed { commitDegreePlan(outcome.plan) }
        return DegreeAdvisorReply(answer: response.answer,
                                  changes: changed ? outcome.applied : [],
                                  planBefore: changed ? before : nil,
                                  failed: false, audits: audits, notice: notice)
    }

    /// Fetches the what-if audit for one catalogue entry from Penn and returns
    /// it, or nil when it could not be read.
    private func fetchDegreeAdvisorWhatIf(_ entry: DegreeProgramEntry) async -> DegreeAudit? {
        if entry.isSibling {
            let ok = await runDegreeEntry(entry)
            guard ok, let audit = degree.whatIfs.first else { return nil }
            return audit
        }
        // A concentration of the student's own major: select the degree it
        // belongs to, then run the page's add-concentration change.
        if let id = entry.degreeID, id != selectedStudentDegree?.id {
            await selectDegree(id)
        }
        let plans = await degreeWhatIfPlans(for: entry.listing.code)
        guard let plan = plans.first(where: { $0.change == .addConcentration })
                ?? plans.first(where: { $0.change == .newProgram })
        else { return nil }
        await runWhatIf(plan)
        guard let audit = degree.whatIfs.first, audit.goals == plan.goals else { return nil }
        return audit
    }

    /// The audits with the one for `degreeID` replaced by a what-if, labelled so
    /// the model knows it is not declared; appended when no entry has that id.
    nonisolated static func degreeAdvisorAudits(_ audits: [DegreeLabeledAudit], replacing degreeID: String,
                                                with audit: DegreeAudit, name: String) -> [DegreeLabeledAudit] {
        let swap = DegreeLabeledAudit(degreeID: degreeID, label: "\(name) (what if, not declared)", audit: audit)
        var out = audits
        if let index = out.firstIndex(where: { $0.degreeID == degreeID }) {
            out[index] = swap
        } else {
            out.append(swap)
        }
        return out
    }

    #if DEBUG
    /// DEBUG only: the brief's document, a dump of every audit rule and the
    /// requirement tags, in one file under Application Support, so the chat's
    /// "why could it not fill this" can be read off the phone
    /// (`scripts/read-advisor-brief.sh`). It holds the same text the server
    /// gets plus rule fields the document leaves out; a Release build never
    /// writes it.
    private nonisolated static func writeDegreeAdvisorDiagnostics(
        brief: DegreeAdvisorBrief, audits: [DegreeLabeledAudit]
    ) {
        var lines: [String] = [brief.context, "", "RULES"]
        func dump(_ rules: [AuditRule], depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            for rule in rules {
                var parts = ["\(rule.status)", rule.ruleType, rule.label.isEmpty ? "requirement" : rule.label]
                if let credits = rule.needCredits { parts.append("needCredits \(credits)") }
                if let courses = rule.needCourses { parts.append("needCourses \(courses)") }
                let codes = rule.advice.prefix(8).map { $0.code }.joined(separator: ", ")
                parts.append("advice \(rule.advice.count) [\(codes)]")
                if let words = rule.adviceText, !words.isEmpty {
                    parts.append("adviceText: " + String(words.prefix(300)))
                }
                lines.append(indent + "- " + parts.joined(separator: " | "))
                dump(rule.children, depth: depth + 1)
            }
        }
        for entry in audits {
            lines.append("DEGREE \(entry.label)")
            for block in entry.audit.blocks {
                lines.append("[\(block.title)]")
                dump(block.rules, depth: 0)
            }
        }
        lines.append("")
        lines.append("REQUIREMENT TAGS")
        for info in brief.requirements.values.sorted(by: { $0.requirement.tag < $1.requirement.tag }) {
            lines.append("\(info.requirement.tag) | \(info.requirement.degree) | \(info.requirement.label)")
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let directory = base.appendingPathComponent("LowHangingFruit", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("degree-advisor-last.txt")
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
    #endif

    /// A breadcrumb readable off the phone: which model answered. An id only.
    private nonisolated static func noteDegreeAdvisorModel(_ model: String?) {
        guard let model, !model.isEmpty else { return }
        UserDefaults.lhf.set(model, forKey: "lastDegreeAdvisorModelV1")
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
