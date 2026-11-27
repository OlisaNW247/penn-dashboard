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

/// A requirement Penn describes only in words (open or in progress, no
/// children, no concrete course among its options). The model may place a
/// course of its own choosing for one, naming it by `tag`.
public struct DegreeAdvisorRequirement: Codable, Sendable, Hashable {
    /// "R1", "R2", in document order.
    public let tag: String
    public let label: String
    /// The audit's label.
    public let degree: String
    /// "need 4 courses", "need 2 cu" or "".
    public let need: String
    /// Wildcard advice codes ("MGMT @"); a pick must match one when there are any.
    public let patterns: [String]

    public init(tag: String, label: String, degree: String, need: String, patterns: [String]) {
        self.tag = tag
        self.label = label
        self.degree = degree
        self.need = need
        self.patterns = patterns
    }
}

/// The phone's side of a tagged requirement: the wire value plus what the
/// phone needs to file a pick (never sent).
public struct DegreeAdvisorRequirementInfo: Sendable, Hashable {
    public let requirement: DegreeAdvisorRequirement
    /// `DegreeProjection.key(blockID:ruleID:)`.
    public let ruleKey: String
    public let degreeID: String
    /// The rule's full label (the block's title when it has none).
    public let label: String

    public init(requirement: DegreeAdvisorRequirement, ruleKey: String, degreeID: String, label: String) {
        self.requirement = requirement
        self.ruleKey = ruleKey
        self.degreeID = degreeID
        self.label = label
    }
}

public struct DegreeAdvisorRequest: Encodable, Sendable, Equatable {
    public let question: String
    public let history: [DegreeAdvisorTurn]
    public let context: String
    public let terms: [DegreeAdvisorTerm]
    public let addable: [String]
    public let programs: [DegreeAdvisorProgram]
    public let requirements: [DegreeAdvisorRequirement]
    public let now: Date
    /// 1...3: which pass of a plan this is. Always encoded.
    public let round: Int
    /// The audits as data for the planning engine; omitted when nil.
    public let structured: DegreeAdvisorStructured?
    /// What the student's advisor answered, for this request alone; at most
    /// `DegreeAdvisorNotes.maxAnswers`. Nil (so the key is omitted) when there
    /// are none, as with `structured`.
    public let advisorAnswers: [DegreeAdvisorAnswerEntry]?

    public init(
        question: String, history: [DegreeAdvisorTurn], context: String,
        terms: [DegreeAdvisorTerm], addable: [String],
        programs: [DegreeAdvisorProgram] = [],
        requirements: [DegreeAdvisorRequirement] = [], now: Date, round: Int = 1,
        structured: DegreeAdvisorStructured? = nil,
        advisorAnswers: [DegreeAdvisorAnswerEntry] = []
    ) {
        self.structured = structured
        let capped = Array(advisorAnswers.prefix(DegreeAdvisorNotes.maxAnswers))
        self.advisorAnswers = capped.isEmpty ? nil : capped
        self.round = min(3, max(1, round))
        self.question = question
        self.history = history
        self.context = context
        self.terms = terms
        self.addable = addable
        self.programs = programs
        self.requirements = requirements
        self.now = now
    }
}

public enum DegreeAdvisorOp: String, Codable, Sendable { case add, remove, move }

public struct DegreeAdvisorAction: Codable, Sendable, Hashable {
    public let op: DegreeAdvisorOp
    public let code: String
    public let term: String
    public let toTerm: String?
    /// A requirement tag ("R3"): the requirement a course was placed for.
    public let requirement: String?
    public let title: String?
    public let credits: Double?

    public init(
        op: DegreeAdvisorOp, code: String, term: String, toTerm: String?,
        requirement: String? = nil, title: String? = nil, credits: Double? = nil
    ) {
        self.op = op
        self.code = code
        self.term = term
        self.toTerm = toTerm
        self.requirement = requirement
        self.title = title
        self.credits = credits
    }

    private enum CodingKeys: String, CodingKey {
        case op, code, term, toTerm
        case requirement = "for"
        case title, credits
    }

    /// Lenient about everything but the three fields an action cannot do
    /// without: a wrong type in an optional field costs that field only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.op = try container.decode(DegreeAdvisorOp.self, forKey: .op)
        self.code = try container.decode(String.self, forKey: .code)
        self.term = try container.decode(String.self, forKey: .term)
        self.toTerm = (try? container.decodeIfPresent(String.self, forKey: .toTerm)) ?? nil
        self.requirement = (try? container.decodeIfPresent(String.self, forKey: .requirement)) ?? nil
        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        self.credits = (try? container.decodeIfPresent(Double.self, forKey: .credits)) ?? nil
    }
}

public struct DegreeAdvisorResponse: Decodable, Sendable, Equatable {
    public let answer: String
    public let actions: [DegreeAdvisorAction]
    /// The `code` of a program the server wants the audit for, or nil.
    public let whatIf: String?
    /// The model id that answered; a diagnostics breadcrumb, never shown.
    public let model: String?
    /// True when the student asked to build, fill or complete a plan.
    public let planning: Bool
    /// Pick codes the server removed because Penn's catalogue lacked them.
    public let dropped: [String]
    /// The engine's whole schedule, when the server ran it. Nil when absent or
    /// malformed; the answer text and actions are unaffected either way.
    public let plan: DegreeEnginePlan?
    /// A drafted email to an advisor, when the server wrote one.
    public let email: String?

    public init(
        answer: String, actions: [DegreeAdvisorAction],
        whatIf: String? = nil, model: String? = nil,
        planning: Bool = false, dropped: [String] = [],
        plan: DegreeEnginePlan? = nil, email: String? = nil
    ) {
        self.plan = plan
        self.email = email
        self.planning = planning
        self.dropped = dropped
        self.answer = answer
        self.actions = actions
        self.whatIf = whatIf
        self.model = model
    }

    private enum CodingKeys: String, CodingKey { case answer, actions, whatIf, model, planning, dropped, plan, email }

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
        let rawPlanning: Bool? = try? container.decodeIfPresent(Bool.self, forKey: .planning)
        self.planning = rawPlanning ?? false
        let rawDropped: [String]? = try? container.decodeIfPresent([String].self, forKey: .dropped)
        self.dropped = rawDropped ?? []
        let box: DegreeEnginePlanBox? = try? container.decodeIfPresent(DegreeEnginePlanBox.self, forKey: .plan)
        self.plan = box?.plan
        let rawEmail: String? = (try? container.decodeIfPresent(String.self, forKey: .email)) ?? nil
        let trimmedEmail = rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.email = trimmedEmail.isEmpty ? nil : rawEmail
    }
}

/// Everything derived from the student's data that a question needs, built
/// once and used both to make the request and to check the answer.
public struct DegreeAdvisorBrief: Sendable, Equatable {
    public let context: String
    public let terms: [DegreeAdvisorTerm]
    /// Key: `DegreePlanMath.normalizedCode(code)`.
    public let addable: [String: AdviceCourse]
    /// Key: the tag ("R1").
    public let requirements: [String: DegreeAdvisorRequirementInfo]
    /// Normalized codes taken or registered in any audit or in the history.
    public let taken: Set<String>
    /// How many lines the STILL NEEDED section lists: needs the model can act on.
    public let fillableNeeds: Int
    /// The audits, history and current term as data, for the planning engine.
    public let structured: DegreeAdvisorStructured?

    public init(
        context: String, terms: [DegreeAdvisorTerm], addable: [String: AdviceCourse],
        requirements: [String: DegreeAdvisorRequirementInfo] = [:], taken: Set<String> = [],
        fillableNeeds: Int = 0, structured: DegreeAdvisorStructured? = nil
    ) {
        self.structured = structured
        self.fillableNeeds = fillableNeeds
        self.context = context
        self.terms = terms
        self.addable = addable
        self.requirements = requirements
        self.taken = taken
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
    public static let maxRequirements = 120
    public static let maxStillNeeded = 120
    public static let maxAdviceText = 200
    /// Fall and spring semesters in a degree, counted from the first.
    public static let finishSemesters = 8

    /// A wildcard advice code such as "MGMT @" or "@ @".
    static func isWildcard(_ code: String) -> Bool { code.contains("@") }

    /// A rule Penn describes in words: open or in progress, no children, and no
    /// concrete course among its options (none at all, or only wildcards).
    static func isWordRequirement(_ rule: AuditRule) -> Bool {
        guard rule.status == .open || rule.status == .inProgress, rule.children.isEmpty else { return false }
        return rule.advice.allSatisfy { isWildcard($0.code) }
    }

    /// Every word requirement of every audit, tagged R1, R2, ... in document
    /// order (audits in order, blocks, rules depth first). `renderKey` is
    /// unique per audit position, for the document.
    struct TaggedRequirement {
        let renderKey: String
        let info: DegreeAdvisorRequirementInfo
    }

    static func tagRequirements(_ audits: [DegreeLabeledAudit]) -> [TaggedRequirement] {
        var out: [TaggedRequirement] = []
        for (auditIndex, entry) in audits.enumerated() {
            func walk(_ rules: [AuditRule], block: AuditBlock) {
                for rule in rules {
                    if isWordRequirement(rule) {
                        let tag = "R\(out.count + 1)"
                        let label = rule.label.isEmpty ? block.title : rule.label
                        var need = ""
                        if let credits = rule.needCredits {
                            need = "need \(number(credits)) cu"
                        } else if let courses = rule.needCourses {
                            need = "need \(courses) courses"
                        }
                        var patterns: [String] = []
                        for option in rule.advice where patterns.count < 20 {
                            let text = String(option.code.trimmingCharacters(in: .whitespaces).prefix(20))
                            if !text.isEmpty { patterns.append(text) }
                        }
                        let wire = DegreeAdvisorRequirement(
                            tag: tag, label: String(label.prefix(160)),
                            degree: String(name(entry).prefix(80)),
                            need: String(need.prefix(40)), patterns: patterns)
                        out.append(TaggedRequirement(
                            renderKey: "\(auditIndex)|\(block.id)|\(rule.id)",
                            info: DegreeAdvisorRequirementInfo(
                                requirement: wire,
                                ruleKey: DegreeProjection.key(blockID: block.id, ruleID: rule.id),
                                degreeID: entry.degreeID, label: label)))
                    }
                    walk(rule.children, block: block)
                }
            }
            for block in entry.audit.blocks { walk(block.rules, block: block) }
        }
        return out
    }

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
        let tagged = tagRequirements(audits)
        var tags: [String: String] = [:]
        var infos: [String: DegreeAdvisorRequirementInfo] = [:]
        for item in tagged {
            tags[item.renderKey] = item.info.requirement.tag
            infos[item.info.requirement.tag] = item.info
        }
        var taken = Set<String>()
        for entry in audits {
            for course in entry.audit.courses { taken.insert(DegreePlanMath.normalizedCode(course.code)) }
        }
        for key in history.keys.sorted() {
            for code in history[key] ?? [] { taken.insert(DegreePlanMath.normalizedCode(code)) }
        }
        taken.remove("")
        let needs = stillNeededLines(audits: audits, plan: plan, tags: tags, infos: infos, addable: addable)
        let context = buildContext(
            audits: audits, plan: plan, history: history, terms: terms, tags: tags,
            needs: needs.lines, now: now, calendar: calendar)
        return DegreeAdvisorBrief(
            context: context, terms: terms, addable: addable, requirements: infos, taken: taken,
            fillableNeeds: needs.count,
            structured: DegreeAdvisorStructured(
                audits: audits, history: history,
                currentTerm: Term(date: now, calendar: calendar).code))
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
                    for option in rule.advice where !isWildcard(option.code) {
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

    /// The STILL NEEDED lines: requirements the plan leaves unspent that the
    /// model can do something about (a tagged word requirement, or one that
    /// lists an option in `addable`). `count` is the number of lines written.
    private static func stillNeededLines(
        audits: [DegreeLabeledAudit], plan: DegreePlan, tags: [String: String],
        infos: [String: DegreeAdvisorRequirementInfo], addable: [String: AdviceCourse]
    ) -> (lines: [String], count: Int) {
        var lines: [String] = []
        outer: for (index, entry) in audits.enumerated() {
            for need in DegreeProjection.stillNeeded(plan: plan, audit: entry.audit) {
                let tag = tags["\(index)|" + need.key]
                let fillable = need.optionCodes.contains { addable[$0] != nil }
                guard tag != nil || fillable else { continue }
                if lines.count >= maxStillNeeded { break outer }
                let flat = need.label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                let label = String((flat.isEmpty ? "requirement" : flat).prefix(120))
                var parts = [name(entry), (tag.map { "[\($0)] " } ?? "") + label]
                let left = number(need.remaining)
                if need.usesCredits {
                    parts.append("\(left) cu left")
                } else if abs(need.remaining - 1) < 1e-9 {
                    parts.append("1 course left")
                } else {
                    parts.append("\(left) courses left")
                }
                if fillable { parts.append("options in ADDABLE") }
                lines.append(parts.joined(separator: " | "))
            }
        }
        return (lines, lines.count)
    }

    private static func buildContext(
        audits: [DegreeLabeledAudit], plan: DegreePlan, history: [String: [String]],
        terms: [DegreeAdvisorTerm], tags: [String: String], needs: [String],
        now: Date, calendar: Calendar
    ) -> String {
        var shared = sharedSections(
            audits: audits, plan: plan, history: history, terms: terms, now: now, calendar: calendar)
        shared.needs = needs
        var last = ""
        for cap in optionCaps {
            let text = render(audits: audits, optionCap: cap, shared: shared, tags: tags)
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
        let finish: [String]
        let plan: [String]
        let worth: [String]
        var needs: [String] = []
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

        // The expected last semester: eight fall and spring semesters counting
        // the first one the history shows. Summers are not counted. A
        // convention, not Penn's word, and the line tells the model so.
        var finish: [String] = []
        let firstTerm = history.keys.compactMap { key -> Term? in
            guard let term = Term(code: key), term.season != .summer,
                  !(history[key] ?? []).isEmpty else { return nil }
            return term
        }.min()
        if let firstTerm {
            let firstCode = DegreePlanMath.termCode(of: firstTerm)
            var lastCode = firstCode
            for _ in 1..<finishSemesters {
                guard let next = DegreePlanMath.nextTermCode(after: lastCode) else { break }
                lastCode = next
            }
            finish.append(
                "expected final semester: \(DegreePlanMath.termLabel(lastCode)) "
                    + "(eight fall and spring semesters from "
                    + "\(DegreePlanMath.termLabel(firstCode)), the first in SEMESTERS; "
                    + "the student may say otherwise)")
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
        return Shared(degrees: degrees, semesters: semesters, finish: finish, plan: planLines, worth: worth)
    }

    private static func render(
        audits: [DegreeLabeledAudit], optionCap: Int, shared: Shared, tags: [String: String]
    ) -> String {
        var lines: [String] = []
        lines.append("DEGREES")
        lines.append(contentsOf: shared.degrees)
        for (index, entry) in audits.enumerated() {
            lines.append("")
            lines.append("DEGREE \(index + 1): \(name(entry))")
            for block in entry.audit.blocks where !block.rules.isEmpty {
                lines.append("[\(block.title)]")
                appendRules(block.rules, depth: 0, optionCap: optionCap,
                            tagPrefix: "\(index)|\(block.id)|", tags: tags, into: &lines)
            }
        }
        lines.append("")
        lines.append("SEMESTERS")
        lines.append(contentsOf: shared.semesters)
        if !shared.finish.isEmpty {
            lines.append("")
            lines.append("FINISH")
            lines.append(contentsOf: shared.finish)
        }
        lines.append("")
        lines.append("PLAN")
        lines.append(contentsOf: shared.plan)
        lines.append("")
        lines.append("STILL NEEDED (after the plan as it stands; this app's estimate)")
        lines.append(contentsOf: shared.needs.isEmpty ? ["none"] : shared.needs)
        lines.append("")
        lines.append("WORTH")
        lines.append("(points are this app's own estimate of progress, not penn's word on what counts)")
        lines.append(contentsOf: shared.worth)
        return lines.joined(separator: "\n")
    }

    private static func appendRules(
        _ rules: [AuditRule], depth: Int, optionCap: Int, tagPrefix: String, tags: [String: String],
        into lines: inout [String]
    ) {
        let indent = String(repeating: "  ", count: depth)
        for rule in rules {
            let tagText = tags[tagPrefix + rule.id].map { "[\($0)] " } ?? ""
            var parts: [String] = [
                tagText + statusWord(rule.status), rule.label.isEmpty ? "requirement" : rule.label,
            ]
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
            if let words = rule.adviceText {
                let flat = words.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !flat.isEmpty { parts.append("penn's words: " + String(flat.prefix(maxAdviceText))) }
            }
            lines.append(indent + "- " + parts.joined(separator: " | "))
            appendRules(rule.children, depth: depth + 1, optionCap: optionCap,
                        tagPrefix: tagPrefix, tags: tags, into: &lines)
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
        programs: [DegreeAdvisorProgram] = [], now: Date, round: Int = 1,
        advisorAnswers: [DegreeAdvisorAnswerEntry] = []
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
            programs: Array(programs.prefix(maxPrograms)),
            requirements: requirementList(brief), now: now, round: round,
            structured: brief.structured, advisorAnswers: advisorAnswers)
    }

    /// The brief's requirements as the wire carries them: ascending by tag
    /// number, at most `maxRequirements`.
    static func requirementList(_ brief: DegreeAdvisorBrief) -> [DegreeAdvisorRequirement] {
        func number(_ tag: String) -> Int { Int(tag.dropFirst()) ?? Int.max }
        let sorted = brief.requirements.values
            .map { $0.requirement }
            .sorted { number($0.tag) < number($1.tag) }
        return Array(sorted.prefix(maxRequirements))
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
            guard termCodes.contains(action.term),
                  !DegreePlanMath.isPlanned(code, in: plan),
                  let extended = ensuringTerm(action.term, in: plan, brief: brief)
            else { return nil }
            let tag = action.requirement?.trimmingCharacters(in: .whitespaces).uppercased()
            let info = tag.flatMap { brief.requirements[$0] }
            let planned: PlannedCourse
            if let course = brief.addable[code] {
                planned = PlannedCourse(
                    code: code, title: course.title, credits: course.credits ?? 1,
                    pickRuleKey: info?.ruleKey, pickLabel: info?.label)
            } else {
                // A pick: a course of the model's own naming, accepted only for
                // a word requirement it names, in a code shape Penn uses, that
                // fits the requirement's wildcards and is not already taken.
                guard let info, isPickCode(code), !brief.taken.contains(code),
                      info.requirement.patterns.isEmpty
                        || info.requirement.patterns.contains(where: { DegreePlanMath.matchesPattern(code, $0) })
                else { return nil }
                let title = action.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                var credits = 1.0
                if let given = action.credits, given.isFinite, given > 0, given <= 4 { credits = given }
                planned = PlannedCourse(
                    code: code, title: (title?.isEmpty ?? true) ? nil : String(title!.prefix(120)),
                    credits: credits, pickRuleKey: info.ruleKey, pickLabel: info.label)
            }
            let added = DegreePlanMath.adding(planned, to: action.term, in: extended)
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

    /// Two to five letters, a space, four digits: "MGMT 2010".
    static func isPickCode(_ code: String) -> Bool {
        let parts = code.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let letters = parts[0]
        let digits = parts[1]
        return (2...5).contains(letters.count)
            && letters.allSatisfy { $0.isASCII && $0.isLetter && $0.isUppercase }
            && digits.count == 4 && digits.allSatisfy { $0.isASCII && $0.isNumber }
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

    /// The line added under the model's answer when some of its edits could
    /// not be applied to the plan (a full semester, a course no longer where
    /// the model thought, a term out of reach). The model writes its answer
    /// before the phone tries the edits, so without this line an answer can
    /// claim a move the plan never took. Nil when nothing was skipped.
    public static func skippedNote(applied: Int, skipped: Int) -> String? {
        guard skipped > 0 else { return nil }
        if applied == 0 {
            return skipped == 1
                ? "that change didn't go into your plan. try again, or move it on the road."
                : "none of those changes went into your plan. try again, or move them on the road."
        }
        let total = applied + skipped
        return "\(skipped) of \(total) changes didn't go into your plan."
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
