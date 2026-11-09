import Foundation

// Degree progress, v12. Contract: docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md.
// Every endpoint constant behind this model (see DegreeWorksEndpoints) is
// UNVERIFIED against Penn's live Degree Works system; nothing here has been
// observed on a real audit.

/// The goals a Degree Works audit is run against: which school, program,
/// degree, majors and so on. These are codes ("EU_BSE", "CIS"), never prose.
public struct DegreeGoals: Codable, Sendable, Hashable {
    public var school: String?
    public var college: String?
    public var program: String?
    public var degree: String?
    public var majors: [String]
    public var concentrations: [String]
    public var minors: [String]
    public var catalogYear: String?

    public init(
        school: String? = nil, college: String? = nil, program: String? = nil, degree: String? = nil,
        majors: [String] = [], concentrations: [String] = [], minors: [String] = [], catalogYear: String? = nil
    ) {
        self.school = school
        self.college = college
        self.program = program
        self.degree = degree
        self.majors = majors
        self.concentrations = concentrations
        self.minors = minors
        self.catalogYear = catalogYear
    }

    /// A lowercase one-liner such as "computer science, bse". Descriptions
    /// come from the caller (the goal catalog); a code with no description
    /// falls back to itself. The caller owns the lookup so this stays pure.
    public func title(descriptions: [String: String]) -> String {
        func word(_ key: String) -> String {
            (descriptions[key] ?? key).trimmingCharacters(in: .whitespaces).lowercased()
        }
        var parts: [String] = []
        let majorWords = majors.filter { !$0.isEmpty }.map(word)
        if !majorWords.isEmpty { parts.append(majorWords.joined(separator: " + ")) }
        if let degree, !degree.isEmpty { parts.append(word(degree)) }
        if parts.isEmpty, let program, !program.isEmpty { parts.append(word(program)) }
        return parts.joined(separator: ", ")
    }
}

public enum RuleStatus: String, Codable, Sendable { case met, inProgress, open, info }

/// One course on the audit. There is deliberately no field for a letter
/// grade: the feature does not need grades, so the decoder never reads them.
public struct AuditCourse: Codable, Sendable, Hashable, Identifiable {
    public let code: String
    public let title: String
    public let credits: Double?
    public let termCode: String?
    public var term: Term? { termCode.flatMap(Term.init(code:)) }
    public let isInProgress: Bool
    public let isTransfer: Bool
    public var id: String { "\(code)|\(termCode ?? "")" }

    public init(code: String, title: String, credits: Double?, termCode: String?, isInProgress: Bool, isTransfer: Bool) {
        self.code = code
        self.title = title
        self.credits = credits
        self.termCode = termCode
        self.isInProgress = isInProgress
        self.isTransfer = isTransfer
    }
}

/// A course Degree Works suggests for an open rule. Shown as a ghost chip,
/// never ordered or recommended by this app.
public struct AdviceCourse: Codable, Sendable, Hashable, Identifiable {
    public let code: String
    public let title: String?
    public let credits: Double?
    public var id: String { code }

    public init(code: String, title: String?, credits: Double?) {
        self.code = code
        self.title = title
        self.credits = credits
    }
}

public struct AuditRule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let ruleType: String
    public let percentComplete: Double?
    public let status: RuleStatus
    public let needCourses: Int?
    public let needCredits: Double?
    public let appliedCount: Int?
    public let appliedCredits: Double?
    public let applied: [AuditCourse]
    public let advice: [AdviceCourse]
    public let adviceText: String?
    public let children: [AuditRule]

    public init(
        id: String, label: String, ruleType: String, percentComplete: Double?, status: RuleStatus,
        needCourses: Int?, needCredits: Double?, appliedCount: Int?, appliedCredits: Double?,
        applied: [AuditCourse], advice: [AdviceCourse], adviceText: String?, children: [AuditRule]
    ) {
        self.id = id
        self.label = label
        self.ruleType = ruleType
        self.percentComplete = percentComplete
        self.status = status
        self.needCourses = needCourses
        self.needCredits = needCredits
        self.appliedCount = appliedCount
        self.appliedCredits = appliedCredits
        self.applied = applied
        self.advice = advice
        self.adviceText = adviceText
        self.children = children
    }
}

public struct AuditBlock: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let value: String
    public let title: String
    public let percentComplete: Double?
    public let rules: [AuditRule]

    /// Derived, never stored: 100 percent is met; else any rule at any depth
    /// in progress is in progress; else open. Computing it keeps a decoded
    /// file from ever disagreeing with its own rules.
    public var status: RuleStatus {
        if let percentComplete, percentComplete >= 100 { return .met }
        func anyInProgress(_ rules: [AuditRule]) -> Bool {
            rules.contains { $0.status == .inProgress || anyInProgress($0.children) }
        }
        return anyInProgress(rules) ? .inProgress : .open
    }

    public init(id: String, type: String, value: String, title: String, percentComplete: Double?, rules: [AuditRule]) {
        self.id = id
        self.type = type
        self.value = value
        self.title = title
        self.percentComplete = percentComplete
        self.rules = rules
    }
}

/// What the app keeps of one audit. It has no field for the student's name,
/// email, GPA or any grade: the decoder cannot store what the type cannot hold.
public struct DegreeAudit: Codable, Sendable, Equatable {
    public let goals: DegreeGoals
    public let isWhatIf: Bool
    public let percentComplete: Double?
    public let degreeLabel: String?
    public let catalogYearLabel: String?
    public let blocks: [AuditBlock]
    public let courses: [AuditCourse]
    public let fetchedAt: Date

    public init(
        goals: DegreeGoals, isWhatIf: Bool, percentComplete: Double?, degreeLabel: String?,
        catalogYearLabel: String?, blocks: [AuditBlock], courses: [AuditCourse], fetchedAt: Date
    ) {
        self.goals = goals
        self.isWhatIf = isWhatIf
        self.percentComplete = percentComplete
        self.degreeLabel = degreeLabel
        self.catalogYearLabel = catalogYearLabel
        self.blocks = blocks
        self.courses = courses
        self.fetchedAt = fetchedAt
    }

    /// Counts over every rule at every depth, excluding `.info`.
    public var ruleCounts: (met: Int, inProgress: Int, open: Int) {
        var met = 0, progress = 0, open = 0
        func walk(_ rules: [AuditRule]) {
            for rule in rules {
                switch rule.status {
                case .met: met += 1
                case .inProgress: progress += 1
                case .open: open += 1
                case .info: break
                }
                walk(rule.children)
            }
        }
        for block in blocks { walk(block.rules) }
        return (met, progress, open)
    }

    /// Sum of the courses' credits, in-progress ones included.
    public var creditsApplied: Double {
        courses.reduce(0) { $0 + ($1.credits ?? 0) }
    }
}
