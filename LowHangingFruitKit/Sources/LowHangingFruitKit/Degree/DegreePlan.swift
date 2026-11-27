import Foundation

// The degree screen's "plan" tab: a sample course load the student builds for
// the semesters ahead. It is the student's own sketch, never Penn's word on
// anything: nothing here says a plan satisfies a requirement, and nothing
// recommends a course. The only thing the audit contributes is the list of
// courses Penn already shows as registered for a term, and Penn's own list of
// options for requirements it still has open, which the plan is merely laid
// beside. All of it is pure: no clock, no store, no network, and the plan never
// leaves the phone.

/// One course the student put in a semester. `code` is stored normalised
/// (`DegreePlanMath.normalizedCode`) so "cis5200" and "CIS 5200" are one course.
public struct PlannedCourse: Codable, Sendable, Hashable, Identifiable {
    public let code: String
    public let title: String?
    public let credits: Double
    /// Set only for a course the chat placed for a named requirement: the
    /// projection key (`DegreeProjection.key`) of that requirement, and its
    /// label, so the table can say "your pick" for a course the audit does not
    /// list among Penn's options.
    public let pickRuleKey: String?
    public let pickLabel: String?
    /// Set only for a course the planning engine placed: the requirements it
    /// counts toward (the engine's words) and how Penn treats it ("automatic",
    /// "petition" or "check"). The table shows them; nothing computes with them.
    public let countsToward: [String]?
    public let approval: String?
    /// Set only for a course the planning engine placed: the audit rules it
    /// decided the course fills, as `"<degreeId>|<blockId>|<ruleId>"` (the same
    /// order as `countsToward`). The projection honours them as given: the
    /// engine already applied Penn's sharing rules, and the phone must not
    /// second-guess it. Nil for every course the student or the chat placed.
    public let slotIds: [String]?
    public var id: String { code }

    public init(
        code: String, title: String?, credits: Double,
        pickRuleKey: String? = nil, pickLabel: String? = nil,
        countsToward: [String]? = nil, approval: String? = nil,
        slotIds: [String]? = nil
    ) {
        self.slotIds = slotIds
        self.countsToward = countsToward
        self.approval = approval
        self.code = code
        self.title = title
        self.credits = credits
        self.pickRuleKey = pickRuleKey
        self.pickLabel = pickLabel
    }

    private enum CodingKeys: String, CodingKey { case code, title, credits, pickRuleKey, pickLabel, countsToward, approval, slotIds }

    /// The pick fields are decoded if present so a `degree-plan.json` written
    /// before they existed still loads: a failed decode quarantines the file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(String.self, forKey: .code)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.credits = try container.decode(Double.self, forKey: .credits)
        self.pickRuleKey = try container.decodeIfPresent(String.self, forKey: .pickRuleKey)
        self.pickLabel = try container.decodeIfPresent(String.self, forKey: .pickLabel)
        self.countsToward = try container.decodeIfPresent([String].self, forKey: .countsToward)
        self.approval = try container.decodeIfPresent(String.self, forKey: .approval)
        self.slotIds = try container.decodeIfPresent([String].self, forKey: .slotIds)
    }
}

/// One semester column. `termCode` is Penn's `YYYYTT` code, as on `AuditCourse`.
public struct PlannedTerm: Codable, Sendable, Equatable, Identifiable {
    public let termCode: String
    public var courses: [PlannedCourse]
    public var id: String { termCode }

    public init(termCode: String, courses: [PlannedCourse] = []) {
        self.termCode = termCode
        self.courses = courses
    }
}

/// A degree the plan was made against a what-if audit for (the student's
/// Wharton degree is "undeclared", the plan was made against "management"). The
/// planned courses carry slot ids from that audit's block and rule ids, which
/// the declared audit does not have, so drawing the declared one leaves the
/// plan's arc empty: the screen then does not show the plan the planner made.
/// The wrong fix is remapping slot ids onto the declared audit; the ids are
/// right, the audit drawn is the wrong one. `goals` finds the kept audit again.
public struct DegreePlanStandIn: Codable, Sendable, Equatable {
    /// `StudentDegree.id` of the degree the what-if stands in for.
    public let degreeID: String
    /// The goals of the what-if audit, the key the kept audit is found by.
    public let goals: DegreeGoals
    /// Display label without the what-if suffix, e.g. "management (general)".
    public let label: String

    public init(degreeID: String, goals: DegreeGoals, label: String) {
        self.degreeID = degreeID
        self.goals = goals
        self.label = label
    }

    /// The stand-ins among the audits a plan was made from: every audit that
    /// is itself a what-if, once per degree (the first wins).
    public static func standIns(from audits: [DegreeLabeledAudit]) -> [DegreePlanStandIn] {
        var seen = Set<String>()
        var out: [DegreePlanStandIn] = []
        for entry in audits where entry.audit.isWhatIf {
            guard !seen.contains(entry.degreeID) else { continue }
            seen.insert(entry.degreeID)
            out.append(DegreePlanStandIn(
                degreeID: entry.degreeID, goals: entry.audit.goals,
                label: DegreeAdvisor.displayLabel(entry.label)))
        }
        return out
    }

    /// The audit and label to draw for one degree. A stand-in for the degree
    /// whose what-if audit is still kept replaces the degree's own audit and
    /// reads "<label> · what if"; anything else draws the own audit as before.
    /// Age is not asked: this is drawing, not a decision to read Penn again.
    public static func drawing(
        degreeID: String, ownLabel: String, ownAudit: DegreeAudit,
        standIns: [DegreePlanStandIn]?, lookup: (DegreeGoals) -> DegreeAudit?
    ) -> DegreeLabeledAudit {
        if let standIn = standIns?.first(where: { $0.degreeID == degreeID }),
           let kept = lookup(standIn.goals) {
            let name = standIn.label.isEmpty ? ownLabel : standIn.label
            return DegreeLabeledAudit(degreeID: degreeID, label: "\(name) · what if", audit: kept)
        }
        return DegreeLabeledAudit(degreeID: degreeID, label: ownLabel, audit: ownAudit)
    }
}

/// Decodes one element without throwing, so one bad stand-in or approval label
/// costs itself and not the summary.
private struct SummaryLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// What the planning engine said about the plan it wrote, kept with the plan so
/// the table can say so in one line. It describes the table exactly as the
/// engine left it: any edit by hand drops it (`DegreePlanMath` does that), and
/// the chat's undo brings the earlier plan back with its earlier summary.
public struct DegreePlanSummary: Codable, Sendable, Equatable {
    /// `YYYYTT` of the semester the engine's scenario finishes in, if it does.
    public let finishTerm: String?
    public let scenarioID: String
    public let scenarioLabel: String
    /// Credits the engine says are left to plan, if it said.
    public let remainingCredits: Double?
    /// True when the chosen scenario leans on an approval (a heavier load, a
    /// petition, the placement exam).
    public let needsApproval: Bool
    public let createdAt: Date
    /// The what-if audits the plan was made against, by degree. Nil from a
    /// summary stored before this field, or when the plan used only declared
    /// audits.
    public let standIns: [DegreePlanStandIn]?
    /// The server's short approval labels; nil from an older server (then
    /// `needsApproval` came from the scenario's id alone).
    public let approvals: [String]?

    public init(
        finishTerm: String?, scenarioID: String, scenarioLabel: String,
        remainingCredits: Double?, needsApproval: Bool, createdAt: Date,
        standIns: [DegreePlanStandIn]? = nil, approvals: [String]? = nil
    ) {
        self.standIns = standIns
        self.approvals = approvals
        self.finishTerm = finishTerm
        self.scenarioID = scenarioID
        self.scenarioLabel = scenarioLabel
        self.remainingCredits = remainingCredits
        self.needsApproval = needsApproval
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case finishTerm, scenarioID, scenarioLabel, remainingCredits, needsApproval, createdAt
        case standIns, approvals
    }

    /// Lenient: a summary with a key missing still reads, because a failed
    /// decode of the plan file quarantines the whole file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.finishTerm = try? container.decodeIfPresent(String.self, forKey: .finishTerm)
        self.scenarioID = (try? container.decodeIfPresent(String.self, forKey: .scenarioID)) ?? ""
        self.scenarioLabel = (try? container.decodeIfPresent(String.self, forKey: .scenarioLabel)) ?? ""
        self.remainingCredits = try? container.decodeIfPresent(Double.self, forKey: .remainingCredits)
        self.needsApproval = (try? container.decodeIfPresent(Bool.self, forKey: .needsApproval)) ?? false
        self.createdAt = (try? container.decodeIfPresent(Date.self, forKey: .createdAt))
            ?? Date(timeIntervalSince1970: 0)
        let rawStandIns: [SummaryLossy<DegreePlanStandIn>]? =
            (try? container.decodeIfPresent([SummaryLossy<DegreePlanStandIn>].self, forKey: .standIns)) ?? nil
        self.standIns = rawStandIns.map { $0.compactMap { $0.value } }
        let rawApprovals: [SummaryLossy<String>]? =
            (try? container.decodeIfPresent([SummaryLossy<String>].self, forKey: .approvals)) ?? nil
        self.approvals = rawApprovals.map { $0.compactMap { $0.value } }
    }

    /// The one quiet line above the semester table: "plan · would finish
    /// spring 2028 · 19 cu to go · needs approval". It says "would", because
    /// whether anything counts is Penn's word, and it is lower case like the
    /// rest of the screen. Without a finish term it says so instead of guessing.
    public static func line(_ summary: DegreePlanSummary) -> String {
        var parts = ["plan"]
        if let finish = summary.finishTerm, !finish.isEmpty {
            parts.append("would finish \(DegreePlanMath.termLabel(finish))")
        } else {
            parts.append("no finish semester")
        }
        if let left = summary.remainingCredits, left.isFinite, left > 0 {
            parts.append("\(creditsText(left)) cu to go")
        }
        if summary.needsApproval { parts.append("needs approval") }
        return parts.joined(separator: " · ")
    }

    /// One decimal at most, none when whole: "19", "19.5".
    public static func creditsText(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e9 else { return "0" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }
}

public struct DegreePlan: Codable, Sendable, Equatable {
    /// Ascending by `termCode`, each code once.
    public var terms: [PlannedTerm]
    /// Set only while the plan is exactly what the planning engine wrote.
    public var summary: DegreePlanSummary?

    public init(terms: [PlannedTerm] = [], summary: DegreePlanSummary? = nil) {
        self.terms = terms
        self.summary = summary
    }

    public static let empty = DegreePlan()

    private enum CodingKeys: String, CodingKey { case terms, summary }

    /// Lenient on purpose, as `DegreeSnapshot` is: a file with a key missing
    /// (or `{}`) must read as an empty plan rather than fail, because a failed
    /// decode quarantines the file and the student's plan would seem to vanish.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.terms = try container.decodeIfPresent([PlannedTerm].self, forKey: .terms) ?? []
        self.summary = try? container.decodeIfPresent(DegreePlanSummary.self, forKey: .summary)
    }
}

/// The rules of the plan tab. Every function is pure and takes the date it
/// needs as a parameter: the screen decides what "now" is, so a test can pin it.
public enum DegreePlanMath {
    /// A cap on columns. Fourteen so a plan that spends summers (fall, spring and
    /// summer for several years) is not cut short.
    public static let maxTerms = 14
    public static let maxCoursesPerTerm = 8

    /// An open requirement that Penn's audit lists options for, in Penn's order.
    public struct OpenRequirement: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let options: [AdviceCourse]

        public init(id: String, label: String, options: [AdviceCourse]) {
            self.id = id
            self.label = label
            self.options = options
        }
    }

    // MARK: Codes and terms

    /// "cis5200", " cis  5200 " and "CIS 5200" are all "CIS 5200". A leading run
    /// of letters followed directly by digits gets its space; anything else is
    /// only trimmed, upper-cased and de-spaced. Matching ids by exact string
    /// would make a typed "cis 5200" miss the audit's "CIS 5200" and let the
    /// same course in twice.
    public static func normalizedCode(_ raw: String) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .uppercased()
        guard !collapsed.isEmpty else { return "" }
        var characters = Array(collapsed)
        var index = 0
        while index < characters.count, characters[index].isLetter { index += 1 }
        if index > 0, index < characters.count, characters[index].isNumber {
            characters.insert(" ", at: index)
        }
        return String(characters)
    }

    /// The fall or spring after `term`. Summers are skipped: the plan is for
    /// the two semesters a student is normally enrolled in, and the student can
    /// still type a summer course into a neighbouring column.
    private static func following(_ term: Term) -> Term {
        switch term.season {
        case .fall:
            return Term(year: term.year + 1, season: .spring)
        case .spring, .summer:
            return Term(year: term.year, season: .fall)
        }
    }

    /// `YYYYTT` for a term.
    public static func termCode(of term: Term) -> String { code(of: term) }

    private static func code(of term: Term) -> String {
        "\(term.year)\(term.season.rawValue)"
    }

    /// "202630" -> "202710" -> "202730"; "202720" -> "202730". Nil for a string
    /// that is not a term code.
    public static func nextTermCode(after code: String) -> String? {
        guard let term = Term(code: code) else { return nil }
        return Self.code(of: following(term))
    }

    /// The semester after the one containing `now`.
    public static func firstPlanTermCode(now: Date, calendar: Calendar = .current) -> String {
        Self.code(of: following(Term(date: now, calendar: calendar)))
    }

    /// "spring 2027"; the raw code when it does not parse.
    public static func termLabel(_ code: String) -> String {
        guard let term = Term(code: code) else { return code }
        return "\(term.season.name.lowercased()) \(term.year)"
    }

    /// Whether `code` fits an audit's wildcard pattern such as "MGMT @",
    /// "MGMT 2@@" or "@ @". The subject is "@" (any) or equal; the number is
    /// all "@" (any), digits then "@"s (a prefix), or plain digits (exact).
    /// A pattern with no number part matches on subject alone; any other shape
    /// matches nothing, because a guess here would plan a course Penn does not
    /// accept.
    public static func matchesPattern(_ code: String, _ pattern: String) -> Bool {
        let codeParts = normalizedCode(code).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let patternParts = pattern.uppercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !codeParts.isEmpty, !patternParts.isEmpty, patternParts.count <= 2, codeParts.count <= 2 else {
            return false
        }
        let subject = patternParts[0]
        if subject != "@" && subject != codeParts[0] { return false }
        guard patternParts.count == 2 else { return true }
        guard codeParts.count == 2 else { return false }
        let wanted = patternParts[1]
        let number = codeParts[1]
        if wanted.allSatisfy({ $0 == "@" }) { return true }
        let digits = wanted.prefix(while: { $0.isASCII && $0.isNumber })
        let rest = wanted.dropFirst(digits.count)
        if digits.isEmpty { return false }
        if rest.isEmpty { return number == String(digits) }
        guard rest.allSatisfy({ $0 == "@" }) else { return false }
        return number.hasPrefix(String(digits))
    }

    // MARK: Editing the plan

    public static func withTermAdded(_ plan: DegreePlan, now: Date, calendar: Calendar = .current) -> DegreePlan {
        guard plan.terms.count < maxTerms else { return plan }
        let next: String?
        if let last = plan.terms.last {
            next = nextTermCode(after: last.termCode)
        } else {
            next = firstPlanTermCode(now: now, calendar: calendar)
        }
        guard let code = next, !plan.terms.contains(where: { $0.termCode == code }) else { return plan }
        var out = plan
        out.terms.append(PlannedTerm(termCode: code))
        out.summary = nil
        return out
    }

    /// An empty plan gets its first semester so the tab never shows nothing to
    /// add to. A plan that already has terms is returned as it is, even if its
    /// first term is now in the past: those courses are the student's own work,
    /// and dropping them to tidy the table would be losing it.
    public static func ensuringFirstTerm(_ plan: DegreePlan, now: Date, calendar: Calendar = .current) -> DegreePlan {
        guard plan.terms.isEmpty else { return plan }
        return withTermAdded(plan, now: now, calendar: calendar)
    }

    /// Whether a course with this code is already in any semester.
    public static func isPlanned(_ code: String, in plan: DegreePlan) -> Bool {
        let wanted = normalizedCode(code)
        return plan.terms.contains { term in
            term.courses.contains { normalizedCode($0.code) == wanted }
        }
    }

    /// Adds `course` to a semester. A no-op for an empty code, a course already
    /// planned anywhere, a semester not in the plan, or a full semester.
    public static func adding(_ course: PlannedCourse, to termCode: String, in plan: DegreePlan) -> DegreePlan {
        let code = normalizedCode(course.code)
        guard !code.isEmpty, !isPlanned(code, in: plan) else { return plan }
        guard let index = plan.terms.firstIndex(where: { $0.termCode == termCode }) else { return plan }
        guard plan.terms[index].courses.count < maxCoursesPerTerm else { return plan }
        var out = plan
        out.terms[index].courses.append(PlannedCourse(
            code: code, title: course.title, credits: course.credits,
            pickRuleKey: course.pickRuleKey, pickLabel: course.pickLabel,
            countsToward: course.countsToward, approval: course.approval,
            slotIds: course.slotIds))
        // A hand edit means the engine's summary no longer describes the table.
        out.summary = nil
        return out
    }

    /// Moves a planned course to another semester, or to another place in its
    /// own, putting it before the course `anchorCode` names or at the end when
    /// that is nil or not in the target. A no-op (the plan comes back as it
    /// was) when the course is not planned, the target semester is not in the
    /// plan, the anchor is the course itself, or a different, full semester is
    /// the target. The course keeps its title and credits.
    public static func moving(
        courseCode: String, to termCode: String, before anchorCode: String?, in plan: DegreePlan
    ) -> DegreePlan {
        let wanted = normalizedCode(courseCode)
        guard !wanted.isEmpty else { return plan }
        let anchor: String? = anchorCode.map { normalizedCode($0) }
        if let anchor, anchor == wanted { return plan }
        var fromIndex: Int?
        var courseIndex = 0
        for (termIndex, term) in plan.terms.enumerated() {
            if let found = term.courses.firstIndex(where: { normalizedCode($0.code) == wanted }) {
                fromIndex = termIndex
                courseIndex = found
                break
            }
        }
        guard let from = fromIndex else { return plan }
        guard let to = plan.terms.firstIndex(where: { $0.termCode == termCode }) else { return plan }
        if from != to, plan.terms[to].courses.count >= maxCoursesPerTerm { return plan }
        var out = plan
        let moved = out.terms[from].courses.remove(at: courseIndex)
        if let anchor,
           let at = out.terms[to].courses.firstIndex(where: { normalizedCode($0.code) == anchor }) {
            out.terms[to].courses.insert(moved, at: at)
        } else {
            out.terms[to].courses.append(moved)
        }
        out.summary = nil
        return out
    }

    public static func removing(courseCode: String, from termCode: String, in plan: DegreePlan) -> DegreePlan {
        guard let index = plan.terms.firstIndex(where: { $0.termCode == termCode }) else { return plan }
        let wanted = normalizedCode(courseCode)
        var out = plan
        out.terms[index].courses.removeAll { normalizedCode($0.code) == wanted }
        if out.terms[index].courses.count != plan.terms[index].courses.count { out.summary = nil }
        return out
    }

    /// Takes the last semester off, but only an empty one and never the only
    /// one: removing a column with courses in it would delete the student's work
    /// in a single tap.
    public static func removingLastTermIfEmpty(_ plan: DegreePlan) -> DegreePlan {
        guard plan.terms.count > 1, let last = plan.terms.last, last.courses.isEmpty else { return plan }
        var out = plan
        out.terms.removeLast()
        out.summary = nil
        return out
    }

    // MARK: Credits

    public static func plannedCredits(_ term: PlannedTerm) -> Double {
        term.courses.reduce(0) { $0 + $1.credits }
    }

    public static func totalPlannedCredits(_ plan: DegreePlan) -> Double {
        plan.terms.reduce(0) { $0 + plannedCredits($1) }
    }

    // The audit's own course list used to supply the "registered" chips of a
    // column here (`registered(in:audit:)`, `termCredits`). Penn's audit never
    // says which term a course belongs to, so those read nothing on a real
    // audit; `DegreeTimeline` takes the term from a separate history map instead.

    // MARK: Laying the plan beside Penn's open requirements

    /// Every rule Penn still has open or in progress that lists options, depth
    /// first (a rule, then its children), in the audit's own order. The order is
    /// Penn's and is never changed: ranking it would be recommending.
    public static func openRequirements(in audit: DegreeAudit?) -> [OpenRequirement] {
        guard let audit else { return [] }
        var out: [OpenRequirement] = []
        func walk(_ rules: [AuditRule], block: AuditBlock) {
            for rule in rules {
                if (rule.status == .open || rule.status == .inProgress), !rule.advice.isEmpty {
                    let label = rule.label.isEmpty ? block.title : rule.label
                    out.append(OpenRequirement(id: "\(block.id)|\(rule.id)", label: label, options: rule.advice))
                }
                walk(rule.children, block: block)
            }
        }
        for block in audit.blocks { walk(block.rules, block: block) }
        return out
    }

    private static func plannedCodes(_ plan: DegreePlan) -> [String] {
        plan.terms.flatMap { $0.courses.map { normalizedCode($0.code) } }
    }

    /// Planned course code -> the label of the first open requirement that lists
    /// it as an option. A course maps to one label at most; two courses may share
    /// one. A course that fits nothing is simply absent. The wording the screen
    /// puts on it is "fits", never "satisfies": whether a course counts is
    /// Penn's decision, made when it is taken.
    public static func coverage(plan: DegreePlan, audit: DegreeAudit?) -> [String: String] {
        let requirements = openRequirements(in: audit)
        guard !requirements.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for code in plannedCodes(plan) {
            if let match = requirements.first(where: { requirement in
                requirement.options.contains { normalizedCode($0.code) == code }
            }) {
                out[code] = match.label
            }
        }
        return out
    }

    /// How many open requirements have at least one planned course among their
    /// options, out of how many there are.
    public static func coveredCount(plan: DegreePlan, audit: DegreeAudit?) -> (covered: Int, open: Int) {
        let requirements = openRequirements(in: audit)
        let planned = Set(plannedCodes(plan))
        let covered = requirements.filter { requirement in
            requirement.options.contains { planned.contains(normalizedCode($0.code)) }
        }.count
        return (covered, requirements.count)
    }

    /// The options still worth offering in the add sheet: each requirement with
    /// the codes already planned, taken or registered removed, and requirements
    /// left with nothing dropped. Order untouched.
    public static func addable(
        _ requirements: [OpenRequirement], plan: DegreePlan, audit: DegreeAudit?,
        history: [String: [String]] = [:]
    ) -> [OpenRequirement] {
        var excluded = Set(plannedCodes(plan))
        if let audit {
            for course in audit.courses { excluded.insert(normalizedCode(course.code)) }
        }
        // A course the term history lists is taken or registered, whether or
        // not the audit's course list carries it.
        for codes in history.values {
            for code in codes { excluded.insert(normalizedCode(code)) }
        }
        var out: [OpenRequirement] = []
        for requirement in requirements {
            let options = requirement.options.filter { !excluded.contains(normalizedCode($0.code)) }
            if !options.isEmpty {
                out.append(OpenRequirement(id: requirement.id, label: requirement.label, options: options))
            }
        }
        return out
    }
}
