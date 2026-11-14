import Foundation

// The degree advisor's pure half: the text document the phone sends with a
// question, the wire types, and the validation and application of the plan
// edits an answer proposes. No clock beyond the `now` a caller passes, no
// store, no network.
//
// The document is deterministic on purpose. The server keeps the front of a
// prompt in a cache that is a byte-for-byte prefix match, so a document that
// differs by one byte between two identical questions is silently a cache
// miss. That is why every collection is walked in source or sorted order, no
// date is printed, and `now` is used only to tell past terms from future
// ones. The wrong fix for "the model should know today's date" is to print
// it into the document: it would change every day for every student.
//
// What must never be in the document: a grade, a GPA, a name, an id of any
// kind (Penn's, the student's, the app's), a course's letter result, or any
// text the audit model has no field for. The audit types cannot hold a grade
// or a name, and this file only reads what they hold; a test searches a
// normal fixture's document for the words "gpa" and "grade" so a later
// edit that starts printing one fails loudly.
//
// The estimate numbers in the WORTH section are the app's own
// (`DegreeContribution`), never Penn's word on what counts, and the section
// says so to the model in a line of its own.

/// One earlier exchange in the chat.
public struct DegreeAdvisorTurn: Codable, Sendable, Equatable {
    /// "user" or "assistant".
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// A semester the advisor may put a course in.
public struct DegreeAdvisorTerm: Codable, Sendable, Hashable {
    /// Six digits, "202730".
    public let code: String
    /// "fall 2027".
    public let label: String

    public init(code: String, label: String) {
        self.code = code
        self.label = label
    }
}

/// A program the phone could fetch a what-if audit for, offered to the server
/// so the model can ask for it by code.
public struct DegreeAdvisorProgram: Codable, Sendable, Hashable {
    public let code: String
    public let name: String
    public let kind: String

    public init(code: String, name: String, kind: String) {
        self.code = code
        self.name = name
        self.kind = kind
    }
}

public struct DegreeAdvisorRequest: Encodable, Sendable, Equatable {
    public let question: String
    public let history: [DegreeAdvisorTurn]
    public let context: String
    public let terms: [DegreeAdvisorTerm]
    public let addable: [String]
    public let programs: [DegreeAdvisorProgram]
    public let now: Date

    public init(
        question: String, history: [DegreeAdvisorTurn], context: String,
        terms: [DegreeAdvisorTerm], addable: [String],
        programs: [DegreeAdvisorProgram] = [], now: Date
    ) {
        self.question = question
        self.history = history
        self.context = context
        self.terms = terms
        self.addable = addable
        self.programs = programs
        self.now = now
    }
}

public enum DegreeAdvisorOp: String, Codable, Sendable { case add, remove, move }

public struct DegreeAdvisorAction: Codable, Sendable, Hashable {
    public let op: DegreeAdvisorOp
    public let code: String
    public let term: String
    public let toTerm: String?

    public init(op: DegreeAdvisorOp, code: String, term: String, toTerm: String?) {
        self.op = op
        self.code = code
        self.term = term
        self.toTerm = toTerm
    }
}

public struct DegreeAdvisorResponse: Decodable, Sendable, Equatable {
    public let answer: String
    public let actions: [DegreeAdvisorAction]
    /// The `code` of a program the server wants the audit for, or nil.
    public let whatIf: String?
    /// The model id that answered; a diagnostics breadcrumb, never shown.
    public let model: String?

    public init(
        answer: String, actions: [DegreeAdvisorAction],
        whatIf: String? = nil, model: String? = nil
    ) {
        self.answer = answer
        self.actions = actions
        self.whatIf = whatIf
        self.model = model
    }

    private enum CodingKeys: String, CodingKey { case answer, actions, whatIf, model }

    /// Decodes one action without ever throwing, so a single bad element
    /// (an op this build does not know, a number where a string belongs) costs
    /// that action and not the answer text. The wrapper matters for a second
    /// reason: an unkeyed container only advances past an element that decoded
    /// successfully, so decoding the raw action with `try?` in a loop would
    /// spin forever on the first bad one.
    private struct Lossy: Decodable {
        let value: DegreeAdvisorAction?
        init(from decoder: Decoder) throws {
            value = try? DegreeAdvisorAction(from: decoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.answer = (try container.decodeIfPresent(String.self, forKey: .answer)) ?? ""
        let lossy: [Lossy]? = try? container.decodeIfPresent([Lossy].self, forKey: .actions)
        self.actions = (lossy ?? []).compactMap { $0.value }
        let rawWhatIf: String? = try? container.decodeIfPresent(String.self, forKey: .whatIf)
        let trimmedWhatIf = rawWhatIf?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.whatIf = trimmedWhatIf.isEmpty ? nil : trimmedWhatIf
        let rawModel: String? = try? container.decodeIfPresent(String.self, forKey: .model)
        self.model = rawModel
    }
}

/// Everything derived from the student's data that a question needs, built
/// once and used both to make the request and to check the answer.
public struct DegreeAdvisorBrief: Sendable, Equatable {
    public let context: String
    public let terms: [DegreeAdvisorTerm]
    /// Key: `DegreePlanMath.normalizedCode(code)`.
    public let addable: [String: AdviceCourse]

    public init(context: String, terms: [DegreeAdvisorTerm], addable: [String: AdviceCourse]) {
        self.context = context
        self.terms = terms
        self.addable = addable
    }
}

/// One edit that was applied, in the words the chat card shows.
public struct DegreeAdvisorChange: Sendable, Equatable, Identifiable {
    public let op: DegreeAdvisorOp
    /// Display form, "CIS 4710".
    public let code: String
    /// For a move, where it was.
    public let termLabel: String
    /// For a move, where it went.
    public let toTermLabel: String?
    public var id: String { "\(op.rawValue)|\(code)|\(termLabel)|\(toTermLabel ?? "")" }

    public init(op: DegreeAdvisorOp, code: String, termLabel: String, toTermLabel: String?) {
        self.op = op
        self.code = code
        self.termLabel = termLabel
        self.toTermLabel = toTermLabel
    }
}

public struct DegreeAdvisorOutcome: Sendable, Equatable {
    public let plan: DegreePlan
    public let applied: [DegreeAdvisorChange]
    public let skipped: Int

    public init(plan: DegreePlan, applied: [DegreeAdvisorChange], skipped: Int) {
        self.plan = plan
        self.applied = applied
        self.skipped = skipped
    }
}

public enum DegreeAdvisor {
    public static let maxQuestion = 1000
    public static let maxHistoryTurns = 6
    public static let maxHistoryCharacters = 6000
    public static let maxContext = 60_000
    public static let maxTerms = 8
    public static let maxAddable = 800
    public static let maxPrograms = 80

    /// The programs the server may ask for an audit of: only catalogue rows
    /// that are options within one of the student's own degrees (`degreeID`
    /// non-nil: their concentration options and sibling majors). A what-if for
    /// such a row replaces exactly one of the student's degrees, so the
    /// document stays "one audit per degree". A minor or an unrelated major has
    /// no degree to stand in for, and guessing one would put a wrong audit
    /// under a right name.
    public static func programs(from entries: [DegreeProgramEntry]) -> [DegreeAdvisorProgram] {
        var out: [DegreeAdvisorProgram] = []
        for entry in entries where entry.degreeID != nil {
            if out.count >= maxPrograms { break }
            out.append(DegreeAdvisorProgram(code: entry.listing.code, name: entry.name, kind: entry.kind.tag))
        }
        return out
    }

    private static let optionCaps = [25, 12, 6, 0]
    private static let worthLimit = 60

    // MARK: Brief

    public static func brief(
        audits: [DegreeLabeledAudit], plan: DegreePlan, history: [String: [String]],
        now: Date, calendar: Calendar = .current
    ) -> DegreeAdvisorBrief {
        let terms = futureTerms(plan: plan, now: now, calendar: calendar)
        let addable = addableCourses(audits: audits, plan: plan, history: history)
        let context = buildContext(
            audits: audits, plan: plan, history: history, terms: terms, now: now, calendar: calendar)
        return DegreeAdvisorBrief(context: context, terms: terms, addable: addable)
    }

    private static func futureTerms(plan: DegreePlan, now: Date, calendar: Calendar) -> [DegreeAdvisorTerm] {
        let current = Term(date: now, calendar: calendar)
        var codes: [String] = []
        for planned in plan.terms {
            guard let term = Term(code: planned.termCode), term > current else { continue }
            if !codes.contains(planned.termCode) { codes.append(planned.termCode) }
        }
        if codes.count > maxTerms { codes = Array(codes.prefix(maxTerms)) }
        if codes.isEmpty {
            codes.append(DegreePlanMath.firstPlanTermCode(now: now, calendar: calendar))
        }
        while codes.count < maxTerms, let last = codes.last, let next = DegreePlanMath.nextTermCode(after: last) {
            codes.append(next)
        }
        return codes.map { DegreeAdvisorTerm(code: $0, label: DegreePlanMath.termLabel($0)) }
    }

    private static func addableCourses(
        audits: [DegreeLabeledAudit], plan: DegreePlan, history: [String: [String]]
    ) -> [String: AdviceCourse] {
        var excluded = Set<String>()
        for entry in audits {
            for course in entry.audit.courses { excluded.insert(DegreePlanMath.normalizedCode(course.code)) }
        }
        for key in history.keys.sorted() {
            for code in history[key] ?? [] { excluded.insert(DegreePlanMath.normalizedCode(code)) }
        }
        for term in plan.terms {
            for course in term.courses { excluded.insert(DegreePlanMath.normalizedCode(course.code)) }
        }
        var out: [String: AdviceCourse] = [:]
        func walk(_ rules: [AuditRule]) {
            for rule in rules {
                if rule.status == .open || rule.status == .inProgress {
                    for option in rule.advice {
                        let key = DegreePlanMath.normalizedCode(option.code)
                        if key.isEmpty || excluded.contains(key) || out[key] != nil { continue }
                        if out.count >= maxAddable { return }
                        out[key] = option
                    }
                }
                walk(rule.children)
            }
        }
        for entry in audits {
            for block in entry.audit.blocks { walk(block.rules) }
        }
        return out
    }

    // MARK: Document

    private static func buildContext(
        audits: [DegreeLabeledAudit], plan: DegreePlan, history: [String: [String]],
        terms: [DegreeAdvisorTerm], now: Date, calendar: Calendar
    ) -> String {
        let shared = sharedSections(
            audits: audits, plan: plan, history: history, terms: terms, now: now, calendar: calendar)
        var last = ""
        for cap in optionCaps {
            let text = render(audits: audits, optionCap: cap, shared: shared)
            last = text
            if text.count <= maxContext { return text }
        }
        // Even with no options at all the document is too long: cut on a line
        // boundary rather than mid-line.
        var out = ""
        var count = 0
        for line in last.split(separator: "\n", omittingEmptySubsequences: false) {
            let add = line.count + 1
            if count + add > maxContext { break }
            out += line + "\n"
            count += add
        }
        return String(out.dropLast())
    }

    /// The sections that do not depend on the option cap.
    private struct Shared {
        let degrees: [String]
        let semesters: [String]
        let plan: [String]
        let worth: [String]
    }

    private static func name(_ entry: DegreeLabeledAudit) -> String {
        entry.label.isEmpty ? "degree" : entry.label
    }

    private static func sharedSections(
        audits: [DegreeLabeledAudit], plan: DegreePlan, history: [String: [String]],
        terms: [DegreeAdvisorTerm], now: Date, calendar: Calendar
    ) -> Shared {
        var degrees: [String] = []
        for (index, entry) in audits.enumerated() {
            var line = "\(index + 1). \(name(entry))"
            if let percent = entry.audit.percentComplete {
                line += " | penn's audit: \(Int(max(0, min(100, percent)).rounded()))% complete"
            }
            degrees.append(line)
        }

        let current = Term(date: now, calendar: calendar)
        var byTerm: [String: [String]] = [:]
        for key in history.keys.sorted() {
            guard let term = Term(code: key), term <= current else { continue }
            var list = byTerm[term.code] ?? []
            for raw in history[key] ?? [] {
                let code = DegreePlanMath.normalizedCode(raw)
                if !code.isEmpty, !list.contains(code) { list.append(code) }
            }
            byTerm[term.code] = list
        }
        var semesters: [String] = []
        for code in byTerm.keys.sorted() {
            guard let list = byTerm[code], !list.isEmpty, let term = Term(code: code) else { continue }
            let kind = term == current ? "now" : "done"
            semesters.append("\(DegreePlanMath.termLabel(code)) (\(kind)): \(list.joined(separator: ", "))")
        }

        var planLines: [String] = []
        for term in terms {
            let planned = plan.terms.first(where: { $0.termCode == term.code })?.courses ?? []
            if planned.isEmpty {
                planLines.append("\(term.code) | \(term.label) | empty")
            } else {
                let total = planned.reduce(0.0) { $0 + $1.credits }
                let items = planned.map { "\(DegreePlanMath.normalizedCode($0.code)) (\(number($0.credits)) cu)" }
                planLines.append(
                    "\(term.code) | \(term.label) | \(number(total)) cu | planned: \(items.joined(separator: ", "))")
            }
        }

        let ranked = DegreeContribution.suggestions(plan: plan, audits: audits, history: history)
        var worth: [String] = []
        for suggestion in ranked.prefix(worthLimit) {
            let gains = suggestion.gains.map { gain -> String in
                let where_ = gain.degreeLabel.isEmpty ? gain.requirement : "\(gain.degreeLabel) · \(gain.requirement)"
                return where_
            }
            worth.append(
                "\(DegreePlanMath.normalizedCode(suggestion.course.code)) +\(number(suggestion.points)) | "
                    + gains.joined(separator: "; "))
        }
        return Shared(degrees: degrees, semesters: semesters, plan: planLines, worth: worth)
    }

    private static func render(audits: [DegreeLabeledAudit], optionCap: Int, shared: Shared) -> String {
        var lines: [String] = []
        lines.append("DEGREES")
        lines.append(contentsOf: shared.degrees)
        for (index, entry) in audits.enumerated() {
            lines.append("")
            lines.append("DEGREE \(index + 1): \(name(entry))")
            for block in entry.audit.blocks where !block.rules.isEmpty {
                lines.append("[\(block.title)]")
                appendRules(block.rules, depth: 0, optionCap: optionCap, into: &lines)
            }
        }
        lines.append("")
        lines.append("SEMESTERS")
        lines.append(contentsOf: shared.semesters)
        lines.append("")
        lines.append("PLAN")
        lines.append(contentsOf: shared.plan)
        lines.append("")
        lines.append("WORTH")
        lines.append("(points are this app's own estimate of progress, not penn's word on what counts)")
        lines.append(contentsOf: shared.worth)
        return lines.joined(separator: "\n")
    }

    private static func appendRules(_ rules: [AuditRule], depth: Int, optionCap: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        for rule in rules {
            var parts: [String] = [statusWord(rule.status), rule.label.isEmpty ? "requirement" : rule.label]
            if rule.status != .met {
                if let credits = rule.needCredits {
                    parts.append("need \(number(credits)) cu")
                } else if let courses = rule.needCourses {
                    parts.append("need \(courses) courses")
                }
            }
            if !rule.applied.isEmpty {
                let held = rule.applied.map { $0.isInProgress ? "\($0.code) (now)" : $0.code }
                parts.append("has: \(held.joined(separator: ", "))")
            }
            if (rule.status == .open || rule.status == .inProgress), !rule.advice.isEmpty, optionCap > 0 {
                let shown = rule.advice.prefix(optionCap).map(optionText)
                var text = "options: " + shown.joined(separator: ", ")
                if rule.advice.count > optionCap { text += ", +\(rule.advice.count - optionCap) more" }
                parts.append(text)
            }
            lines.append(indent + "- " + parts.joined(separator: " | "))
            appendRules(rule.children, depth: depth + 1, optionCap: optionCap, into: &lines)
        }
    }

    private static func optionText(_ option: AdviceCourse) -> String {
        var text = option.code
        if let title = option.title, !title.isEmpty { text += " " + title }
        if let credits = option.credits { text += " (\(number(credits)) cu)" }
        return text
    }

    private static func statusWord(_ status: RuleStatus) -> String {
        switch status {
        case .met: return "met"
        case .inProgress: return "in progress"
        case .open: return "open"
        case .info: return "note"
        }
    }

    /// One decimal at most, none when whole: "3", "1.5". Never locale-aware,
    /// because the document has to be the same bytes on every phone.
    private static func number(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e9 else { return "0" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    // MARK: Request

    public static func request(
        question: String, turns: [DegreeAdvisorTurn], brief: DegreeAdvisorBrief,
        programs: [DegreeAdvisorProgram] = [], now: Date
    ) -> DegreeAdvisorRequest {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(trimmed.prefix(maxQuestion))

        var kept = Array(turns.filter { $0.role == "user" || $0.role == "assistant" }.suffix(maxHistoryTurns))
        var total = kept.reduce(0) { $0 + $1.content.count }
        while total > maxHistoryCharacters, !kept.isEmpty {
            total -= kept[0].content.count
            kept.removeFirst()
        }
        return DegreeAdvisorRequest(
            question: cut, history: kept, context: brief.context, terms: brief.terms,
            addable: brief.addable.keys.sorted(),
            programs: Array(programs.prefix(maxPrograms)), now: now)
    }

    // MARK: Applying an answer's edits

    /// Checks every action against the live plan and the brief, one at a time
    /// and in order, applying as it goes so a later action sees an earlier
    /// one's result. An invalid action is skipped whole and counted.
    ///
    /// The phone validates what the server has already validated for two
    /// reasons: the plan may have changed while the request was in flight (the
    /// student kept using the table), and the phone's own list is the
    /// authority on what may be added, because the server only saw a document
    /// and a list of codes. The wrong fix is trusting the answer because it
    /// came back well-formed: a course the audit does not offer, or a semester
    /// outside the ones listed, would then reach the student's plan.
    public static func apply(
        _ actions: [DegreeAdvisorAction], to plan: DegreePlan, brief: DegreeAdvisorBrief
    ) -> DegreeAdvisorOutcome {
        var working = plan
        var applied: [DegreeAdvisorChange] = []
        var skipped = 0
        for action in actions {
            if let result = applyOne(action, to: working, brief: brief) {
                working = result.plan
                applied.append(result.change)
            } else {
                skipped += 1
            }
        }
        return DegreeAdvisorOutcome(plan: working, applied: applied, skipped: skipped)
    }

    private static func applyOne(
        _ action: DegreeAdvisorAction, to plan: DegreePlan, brief: DegreeAdvisorBrief
    ) -> (plan: DegreePlan, change: DegreeAdvisorChange)? {
        let code = DegreePlanMath.normalizedCode(action.code)
        guard !code.isEmpty else { return nil }
        let termCodes = Set(brief.terms.map { $0.code })

        switch action.op {
        case .add:
            guard let course = brief.addable[code], termCodes.contains(action.term),
                  !DegreePlanMath.isPlanned(code, in: plan),
                  let extended = ensuringTerm(action.term, in: plan, brief: brief)
            else { return nil }
            let added = DegreePlanMath.adding(
                PlannedCourse(code: code, title: course.title, credits: course.credits ?? 1),
                to: action.term, in: extended)
            guard isPlanned(code, in: action.term, plan: added) else { return nil }
            return (added, DegreeAdvisorChange(
                op: .add, code: code, termLabel: DegreePlanMath.termLabel(action.term), toTermLabel: nil))

        case .remove:
            guard isPlanned(code, in: action.term, plan: plan) else { return nil }
            let removed = DegreePlanMath.removing(courseCode: code, from: action.term, in: plan)
            return (removed, DegreeAdvisorChange(
                op: .remove, code: code, termLabel: DegreePlanMath.termLabel(action.term), toTermLabel: nil))

        case .move:
            guard let target = action.toTerm, target != action.term, termCodes.contains(target),
                  isPlanned(code, in: action.term, plan: plan),
                  let extended = ensuringTerm(target, in: plan, brief: brief)
            else { return nil }
            let moved = DegreePlanMath.moving(courseCode: code, to: target, before: nil, in: extended)
            guard isPlanned(code, in: target, plan: moved) else { return nil }
            return (moved, DegreeAdvisorChange(
                op: .move, code: code, termLabel: DegreePlanMath.termLabel(action.term),
                toTermLabel: DegreePlanMath.termLabel(target)))
        }
    }

    private static func isPlanned(_ code: String, in termCode: String, plan: DegreePlan) -> Bool {
        guard let term = plan.terms.first(where: { $0.termCode == termCode }) else { return false }
        return term.courses.contains { DegreePlanMath.normalizedCode($0.code) == code }
    }

    /// The plan with `target` in it, appending consecutive semesters after the
    /// plan's last one until it exists. The plan's terms stay a run with no
    /// gap, as the table draws them. Nil when the target is behind the plan's
    /// last term and missing (a gap would be needed), when it cannot be
    /// reached by fall and spring steps, or when the plan would pass its cap.
    private static func ensuringTerm(_ target: String, in plan: DegreePlan, brief: DegreeAdvisorBrief) -> DegreePlan? {
        if plan.terms.contains(where: { $0.termCode == target }) { return plan }
        guard let targetTerm = Term(code: target) else { return nil }
        if let last = plan.terms.last, let lastTerm = Term(code: last.termCode), lastTerm >= targetTerm {
            return nil
        }
        var out = plan
        while out.terms.count < DegreePlanMath.maxTerms {
            let next: String?
            if let last = out.terms.last {
                next = DegreePlanMath.nextTermCode(after: last.termCode)
            } else {
                next = brief.terms.first?.code
            }
            guard let code = next else { return nil }
            out.terms.append(PlannedTerm(termCode: code))
            if code == target { return out }
            if let reached = Term(code: code), reached > targetTerm { return nil }
        }
        return nil
    }

    // MARK: Summary

    /// Short lowercase lines for the chat card: adds, then moves, then
    /// removes, one line per semester within each, in the order first seen.
    public static func summary(_ changes: [DegreeAdvisorChange]) -> [String] {
        var lines: [String] = []
        let verbs: [(DegreeAdvisorOp, String)] = [(.add, "added"), (.move, "moved"), (.remove, "removed")]
        for (op, verb) in verbs {
            var order: [String] = []
            var codes: [String: [String]] = [:]
            for change in changes where change.op == op {
                let key: String
                if op == .move, let to = change.toTermLabel {
                    key = "\(change.termLabel) → \(to)"
                } else {
                    key = change.termLabel
                }
                if codes[key] == nil { order.append(key) }
                codes[key, default: []].append(change.code)
            }
            for key in order {
                lines.append("\(verb) \((codes[key] ?? []).joined(separator: ", ")) · \(key)")
            }
        }
        return lines
    }
}
