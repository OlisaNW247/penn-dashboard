import Foundation
import LowHangingFruitKit

// The degree screen's chat is the one place degree data leaves the phone. It
// happens only when the student sends a message: the audit as text, the
// planned courses, the question and the last few turns go to smooth's server,
// which answers and stores none of it. The model's answer may carry edits to
// the plan (add, remove, move); `DegreeAdvisor.apply` checks each against what
// the phone offered, so a made-up course or term is skipped, never filed.

/// Why the chat could not read a what-if audit from Penn.
enum DegreeAdvisorReadFailure: Equatable, Sendable {
    case duoNotApproved
    case noCanvasSession
    case withinBudget(until: Date)
    case needsPennKey
    /// The student closed the sign-in page before it finished.
    case signInNotFinished
    case other

    /// Words only, for the DEBUG degree log.
    var logWords: String {
        switch self {
        case .duoNotApproved: return "duo not approved"
        case .noCanvasSession: return "no canvas session"
        case .withinBudget: return "within budget"
        case .needsPennKey: return "needs pennkey"
        case .signInNotFinished: return "sign-in not finished"
        case .other: return "other"
        }
    }

    /// Whether asking again can work now: not when something else has to
    /// happen first, and not for a wait of more than two minutes.
    func canRetry(now: Date) -> Bool {
        switch self {
        case .duoNotApproved, .other, .signInNotFinished: return true
        case .noCanvasSession, .needsPennKey: return false
        case let .withinBudget(until): return until.timeIntervalSince(now) <= 120
        }
    }
}

/// What the chat's Penn read came back with.
enum DegreeAdvisorRead {
    /// `keptFrom` is the read date when a kept audit was used without Penn.
    case audit(DegreeAudit, keptFrom: Date?)
    case failed(DegreeAdvisorReadFailure)
}

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
    /// The engine's schedule, when the server ran it, and its drafted advisor email.
    let plan: DegreeEnginePlan?
    let email: String?
    /// A failed reply the student can fix by asking again (the view offers
    /// "try again").
    let canRetry: Bool

    init(answer: String, changes: [DegreeAdvisorChange], planBefore: DegreePlan?, failed: Bool,
         audits: [DegreeLabeledAudit]? = nil, notice: String? = nil,
         plan: DegreeEnginePlan? = nil, email: String? = nil, canRetry: Bool = false) {
        self.canRetry = canRetry
        self.plan = plan
        self.email = email
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
                          onStage: @escaping @MainActor (String) -> Void = { _ in }) async -> DegreeAdvisorReply {
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
            first = try await sendDegreeAdvisor(client, request, onStage: onStage)
        } catch {
            return DegreeAdvisorReply(answer: Self.degreeAdvisorFailureLine(error),
                                      changes: [], planBefore: nil, failed: true, audits: nil, notice: nil)
        }
        Self.noteDegreeAdvisorModel(first.model)

        guard let wanted = first.whatIf,
              let entry = entries.first(where: { $0.listing.code == wanted && $0.degreeID != nil })
        else {
            return await finishDegreeAdvisor(
                first, brief: brief, auditsUsed: audits, replyAudits: nil, notice: nil,
                question: question, turns: turns, client: client, now: now, onStage: onStage)
        }

        onStage("reading path@penn for \(entry.name)…")
        degreeAskActive = true
        degreeAskSignInFailed = false
        degreeAskSubmitted = false
        degreeStageSink = { onStage($0) }
        let read = await fetchDegreeAdvisorWhatIf(entry, now: now)
        degreeAskActive = false
        degreeAskSubmitted = false
        degreeStageSink = nil
        let whatIf: DegreeAudit
        let notice: String
        switch read {
        case let .audit(audit, keptFrom):
            whatIf = audit
            if let keptFrom {
                notice = Self.degreeKeptAuditNotice(name: entry.name, readAt: keptFrom, now: now, calendar: .current)
            } else {
                notice = "read path@penn's audit for \(entry.name)"
            }
        case let .failed(failure):
            #if DEBUG
            DebugDegreeLog.record("advisor read failed: \(failure.logWords)")
            #endif
            return DegreeAdvisorReply(
                answer: Self.degreeAdvisorReadFailureLine(
                    failure, name: entry.name, now: Date(), timeZone: .current),
                changes: [], planBefore: nil, failed: true, audits: nil, notice: nil,
                canRetry: failure.canRetry(now: Date()))
        }
        let degreeID = entry.degreeID ?? ""
        let swapped = Self.degreeAdvisorAudits(audits, replacing: degreeID, with: whatIf, name: entry.name)

        onStage("planning…")
        let secondBrief = DegreeAdvisor.brief(audits: swapped, plan: degreePlan,
                                              history: degree.history, now: now)
        #if DEBUG
        Self.writeDegreeAdvisorDiagnostics(brief: secondBrief, audits: swapped)
        #endif
        let second = DegreeAdvisor.request(question: question, turns: turns, brief: secondBrief,
                                           programs: [], now: now)
        do {
            let response = try await sendDegreeAdvisor(client, second, onStage: onStage)
            Self.noteDegreeAdvisorModel(response.model)
            return await finishDegreeAdvisor(
                response, brief: secondBrief, auditsUsed: swapped, replyAudits: swapped, notice: notice,
                question: question, turns: turns, client: client, now: now, onStage: onStage)
        } catch {
            return DegreeAdvisorReply(answer: Self.degreeAdvisorFailureLine(error),
                                      changes: [], planBefore: nil, failed: true,
                                      audits: swapped, notice: nil)
        }
    }

    /// Most passes one send may make: the answer and two automatic follow-ups.
    nonisolated static let degreeAdvisorMaxRounds = 3

    /// The automatic follow-up's question; the server treats a question that
    /// starts with this phrase as a continuation round.
    nonisolated static func degreeAdvisorContinuation(dropped: [String]) -> String {
        var text = "continue the plan: fill what STILL NEEDED lists."
        if !dropped.isEmpty {
            text += " these codes are not in penn's catalogue: \(dropped.joined(separator: ", "))."
        }
        return text
    }

    /// One request, retried once on a dropped connection or a server error
    /// (the answer may still be on its way). A quota refusal, an update wall
    /// or anything else is never retried.
    private func sendDegreeAdvisor(
        _ client: BackendClient, _ request: DegreeAdvisorRequest,
        onStage: @MainActor (String) -> Void
    ) async throws -> DegreeAdvisorResponse {
        do {
            return try await client.degreeAdvisor(request)
        } catch {
            guard Self.degreeAdvisorShouldRetry(error) else { throw error }
            onStage("still working…")
            return try await client.degreeAdvisor(request)
        }
    }

    nonisolated static func degreeAdvisorShouldRetry(_ error: Error) -> Bool {
        switch error as? BackendError {
        case .transport?: return true
        case .http(let code)?: return code >= 500 && code < 600
        default: return false
        }
    }

    /// Applies a response's edits to the live plan and builds the reply. When
    /// the student asked for a whole plan and the round changed it while the
    /// document still lists needs the model can act on, asks again (at most
    /// three rounds in all). Edits accumulate into one reply, `planBefore` is
    /// the plan before the first round so one undo restores everything, and a
    /// failed follow-up keeps what earlier rounds did.
    private func finishDegreeAdvisor(
        _ response: DegreeAdvisorResponse, brief: DegreeAdvisorBrief,
        auditsUsed: [DegreeLabeledAudit], replyAudits: [DegreeLabeledAudit]?, notice: String?,
        question: String, turns: [DegreeAdvisorTurn], client: BackendClient, now: Date,
        onStage: @MainActor (String) -> Void
    ) async -> DegreeAdvisorReply {
        let planBefore = degreePlan
        var current = response
        var currentBrief = brief
        var currentQuestion = question
        var history = turns
        var changes: [DegreeAdvisorChange] = []
        var answer = response.answer
        var round = 1
        while true {
            let before = degreePlan
            // The engine's plan is complete and replaces the future; without
            // one, the model's edits are applied as before.
            let outcome: DegreeAdvisorOutcome
            if let enginePlan = current.plan {
                outcome = DegreeAdvisor.applyEnginePlan(
                    enginePlan, to: before,
                    currentTerm: currentBrief.structured?.currentTerm ?? Term(date: now).code, now: now)
            } else {
                outcome = DegreeAdvisor.apply(current.actions, to: before, brief: currentBrief)
            }
            let changed = outcome.plan != before
            if changed {
                commitDegreePlan(outcome.plan)
                changes.append(contentsOf: outcome.applied)
            }
            if !current.answer.isEmpty || answer.isEmpty { answer = current.answer }
            // A complete engine plan needs no follow-up rounds.
            guard current.plan == nil else { break }
            guard current.planning, changed, round < Self.degreeAdvisorMaxRounds else { break }
            let nextBrief = DegreeAdvisor.brief(audits: auditsUsed, plan: degreePlan,
                                                history: degree.history, now: now)
            guard nextBrief.fillableNeeds > 0 else { break }
            onStage("filling what's left…")
            #if DEBUG
            Self.writeDegreeAdvisorDiagnostics(brief: nextBrief, audits: auditsUsed)
            #endif
            history.append(DegreeAdvisorTurn(role: "user", content: currentQuestion))
            history.append(DegreeAdvisorTurn(role: "assistant", content: current.answer))
            let nextQuestion = Self.degreeAdvisorContinuation(dropped: current.dropped)
            let request = DegreeAdvisor.request(
                question: nextQuestion, turns: history, brief: nextBrief,
                programs: [], now: now, round: round + 1)
            do {
                let next = try await sendDegreeAdvisor(client, request, onStage: onStage)
                Self.noteDegreeAdvisorModel(next.model)
                current = next
                currentBrief = nextBrief
                currentQuestion = nextQuestion
                round += 1
            } catch {
                break
            }
        }
        let changedOverall = degreePlan != planBefore
        return DegreeAdvisorReply(answer: answer,
                                  changes: changedOverall ? changes : [],
                                  planBefore: changedOverall ? planBefore : nil,
                                  failed: false, audits: replyAudits, notice: notice,
                                  plan: current.plan, email: current.email)
    }

    /// Fetches the what-if audit for one catalogue entry from Penn and returns
    /// it, or nil when it could not be read.
    private func fetchDegreeAdvisorWhatIf(_ entry: DegreeProgramEntry, now: Date) async -> DegreeAdvisorRead {
        lastPathSignIn = nil
        lastPathFillSkip = nil
        lastPathEndedByStudent = false
        if entry.isSibling {
            // A what-if already kept for this option and read within the
            // staleness window is used without asking Penn. Only a switch
            // (`.newProgram`) records the score the lookup needs, so the
            // non-sibling branch below always reads Penn.
            if let degreeID = entry.degreeID {
                let kept = (degree.whatIfs + (degree.shelved[degreeID]?.whatIfs ?? []))
                if let audit = Self.keptWhatIf(
                    optionScores: degree.optionScores, whatIfs: kept, degreeID: degreeID,
                    programCode: entry.listing.code, now: now, maxAge: Self.degreeStaleAfter) {
                    return .audit(audit, keptFrom: audit.fetchedAt)
                }
            }
            let ok = await runDegreeEntry(entry)
            guard ok, let audit = degree.whatIfs.first else {
                return .failed(Self.degreeAdvisorReadFailure(
                signIn: lastPathSignIn, skip: lastPathFillSkip, endedByStudent: lastPathEndedByStudent))
            }
            return .audit(audit, keptFrom: nil)
        }
        // A concentration of the student's own major: select the degree it
        // belongs to, then run the page's add-concentration change.
        if let id = entry.degreeID, id != selectedStudentDegree?.id {
            await selectDegree(id, userInitiated: true)
        }
        let plans = await degreeWhatIfPlans(for: entry.listing.code)
        guard let plan = plans.first(where: { $0.change == .addConcentration })
                ?? plans.first(where: { $0.change == .newProgram })
        else {
            return .failed(Self.degreeAdvisorReadFailure(
                signIn: lastPathSignIn, skip: lastPathFillSkip, endedByStudent: lastPathEndedByStudent))
        }
        await runWhatIf(plan)
        guard let audit = degree.whatIfs.first, audit.goals == plan.goals else {
            return .failed(Self.degreeAdvisorReadFailure(
                signIn: lastPathSignIn, skip: lastPathFillSkip, endedByStudent: lastPathEndedByStudent))
        }
        return .audit(audit, keptFrom: nil)
    }

    /// The kept what-if audit for one option, when its score names the audit's
    /// goals and the audit was read within `maxAge`. Nil otherwise (no score, a
    /// score from before goals were kept, the audit no longer kept, too old).
    nonisolated static func keptWhatIf(
        optionScores: [String: DegreeOptionScore], whatIfs: [DegreeAudit],
        degreeID: String, programCode: String, now: Date, maxAge: TimeInterval
    ) -> DegreeAudit? {
        let key = DegreeOptions.scoreKey(degreeID: degreeID, programCode: programCode)
        guard let goals = optionScores[key]?.goals else { return nil }
        return whatIfs.first { audit in
            audit.goals == goals && now.timeIntervalSince(audit.fetchedAt) < maxAge
        }
    }

    /// "using path@penn's audit for finance from today" / "from yesterday" /
    /// "from nov 24".
    nonisolated static func degreeKeptAuditNotice(name: String, readAt: Date, now: Date, calendar: Calendar) -> String {
        let when: String
        if calendar.isDate(readAt, inSameDayAs: now) {
            when = "today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(readAt, inSameDayAs: yesterday) {
            when = "yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "MMM d"
            when = formatter.string(from: readAt).lowercased()
        }
        return "using path@penn's audit for \(name) from \(when)"
    }

    /// Why the chat's Penn read failed, from the last sign-in of that read.
    nonisolated static func degreeAdvisorReadFailure(
        signIn: PathPortal.SignIn?, skip: PathPortal.FillSkip?, endedByStudent: Bool = false
    ) -> DegreeAdvisorReadFailure {
        if endedByStudent { return .signInNotFinished }
        switch signIn {
        case .needsDuo?: return .duoNotApproved
        case .noCanvasSession?: return .noCanvasSession
        default: break
        }
        switch skip {
        case let .withinBudget(until)?: return .withinBudget(until: until)
        case .noneSaved?, .rejectedOrOff?: return .needsPennKey
        case nil: return .other
        }
    }

    /// The chat line for a failed Penn read. Lower case, the least text.
    nonisolated static func degreeAdvisorReadFailureLine(
        _ failure: DegreeAdvisorReadFailure, name: String, now: Date, timeZone: TimeZone
    ) -> String {
        switch failure {
        case .duoNotApproved:
            return "duo wasn't approved in time. ask again and approve the push on this phone."
        case .noCanvasSession:
            return "sign in to canvas first, then ask again."
        case let .withinBudget(until):
            if until.timeIntervalSince(now) < 120 {
                return "just tried. ask again in a minute."
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "h:mm a"
            return "path@penn sign-in can try again at \(formatter.string(from: until).lowercased())."
        case .needsPennKey:
            return "penn needs your pennkey. update it in profile, then ask again."
        case .signInNotFinished:
            return "sign-in wasn't finished. ask again."
        case .other:
            return "couldn't read path@penn's audit for \(name). ask again."
        }
    }

    /// The audits with the one for `degreeID` replaced by a what-if, labelled so
    /// the model knows it is not declared; appended when no entry has that id.
    nonisolated static func degreeAdvisorAudits(_ audits: [DegreeLabeledAudit], replacing degreeID: String,
                                                with audit: DegreeAudit, name: String) -> [DegreeLabeledAudit] {
        let swap = DegreeLabeledAudit(degreeID: degreeID, label: "\(name)\(DegreeAdvisor.whatIfLabelSuffix)", audit: audit)
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
        case .transport?: return "that took too long. try again."
        default: return "couldn't reach smooth."
        }
    }
}
