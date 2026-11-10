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
    public var id: String { code }

    public init(code: String, title: String?, credits: Double) {
        self.code = code
        self.title = title
        self.credits = credits
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

public struct DegreePlan: Codable, Sendable, Equatable {
    /// Ascending by `termCode`, each code once.
    public var terms: [PlannedTerm]

    public init(terms: [PlannedTerm] = []) {
        self.terms = terms
    }

    public static let empty = DegreePlan()

    private enum CodingKeys: String, CodingKey { case terms }

    /// Lenient on purpose, as `DegreeSnapshot` is: a file with a key missing
    /// (or `{}`) must read as an empty plan rather than fail, because a failed
    /// decode quarantines the file and the student's plan would seem to vanish.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.terms = try container.decodeIfPresent([PlannedTerm].self, forKey: .terms) ?? []
    }
}

/// The rules of the plan tab. Every function is pure and takes the date it
/// needs as a parameter: the screen decides what "now" is, so a test can pin it.
public enum DegreePlanMath {
    public static let maxTerms = 10
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
        out.terms[index].courses.append(PlannedCourse(code: code, title: course.title, credits: course.credits))
        return out
    }

    public static func removing(courseCode: String, from termCode: String, in plan: DegreePlan) -> DegreePlan {
        guard let index = plan.terms.firstIndex(where: { $0.termCode == termCode }) else { return plan }
        let wanted = normalizedCode(courseCode)
        var out = plan
        out.terms[index].courses.removeAll { normalizedCode($0.code) == wanted }
        return out
    }

    /// Takes the last semester off, but only an empty one and never the only
    /// one: removing a column with courses in it would delete the student's work
    /// in a single tap.
    public static func removingLastTermIfEmpty(_ plan: DegreePlan) -> DegreePlan {
        guard plan.terms.count > 1, let last = plan.terms.last, last.courses.isEmpty else { return plan }
        var out = plan
        out.terms.removeLast()
        return out
    }

    // MARK: Credits

    public static func plannedCredits(_ term: PlannedTerm) -> Double {
        term.courses.reduce(0) { $0 + $1.credits }
    }

    public static func totalPlannedCredits(_ plan: DegreePlan) -> Double {
        plan.terms.reduce(0) { $0 + plannedCredits($1) }
    }

    /// The courses Penn's audit already shows as registered for this term, in
    /// the audit's order, each code once.
    public static func registered(in termCode: String, audit: DegreeAudit?) -> [AuditCourse] {
        guard let audit else { return [] }
        var seen = Set<String>()
        var out: [AuditCourse] = []
        for course in audit.courses where course.isInProgress && course.termCode == termCode {
            if seen.insert(normalizedCode(course.code)).inserted { out.append(course) }
        }
        return out
    }

    /// Planned plus registered credits for one column.
    public static func termCredits(_ term: PlannedTerm, audit: DegreeAudit?) -> Double {
        let held = registered(in: term.termCode, audit: audit).reduce(0) { $0 + ($1.credits ?? 0) }
        return plannedCredits(term) + held
    }

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
        _ requirements: [OpenRequirement], plan: DegreePlan, audit: DegreeAudit?
    ) -> [OpenRequirement] {
        var excluded = Set(plannedCodes(plan))
        if let audit {
            for course in audit.courses { excluded.insert(normalizedCode(course.code)) }
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
