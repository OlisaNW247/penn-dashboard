import Foundation

// A student with two degrees on their Penn record plans one set of semesters
// toward two audits. Penn publishes one audit per degree and no combined
// figure; the wrong design here is a combined percent, which would be this
// app's own opinion presented as Penn's. So this file only lays the audits
// side by side: Penn's own rule counts added up, the courses Penn applied in
// more than one audit, and, for each planned course, every degree whose open
// requirements list it as an option. Everything is pure and reads the audits
// it is given.

/// One of the student's degrees with the audit to draw for it.
public struct DegreeLabeledAudit: Sendable, Equatable, Identifiable {
    /// `StudentDegree.id`.
    public let degreeID: String
    /// Short lowercase name for a chip or a "fits" line, e.g. "computer science".
    public let label: String
    public let audit: DegreeAudit
    public var id: String { degreeID }

    public init(degreeID: String, label: String, audit: DegreeAudit) {
        self.degreeID = degreeID
        self.label = label
        self.audit = audit
    }
}

/// One requirement a planned course fits, and in which degree.
public struct DegreePlanFit: Sendable, Equatable, Hashable {
    /// Empty when the student has one degree, so the single-degree screen
    /// reads exactly as it did before there was a combined view.
    public let degreeLabel: String
    /// Penn's requirement title, as `DegreePlanMath.coverage` returns it.
    public let requirement: String

    public init(degreeLabel: String, requirement: String) {
        self.degreeLabel = degreeLabel
        self.requirement = requirement
    }
}

/// The open requirements of one degree.
public struct DegreeOpenGroup: Sendable, Equatable, Identifiable {
    public let degreeID: String
    public let label: String
    public let requirements: [DegreePlanMath.OpenRequirement]
    public var id: String { degreeID }

    public init(degreeID: String, label: String, requirements: [DegreePlanMath.OpenRequirement]) {
        self.degreeID = degreeID
        self.label = label
        self.requirements = requirements
    }
}

public enum DegreeOverall {
    /// Penn's own rule counts added up across the audits (each audit's
    /// `ruleCounts`). A sum of Penn's counts, not a percentage.
    public static func counts(_ audits: [DegreeLabeledAudit]) -> (met: Int, inProgress: Int, open: Int) {
        var met = 0, progress = 0, open = 0
        for entry in audits {
            let counts = entry.audit.ruleCounts
            met += counts.met
            progress += counts.inProgress
            open += counts.open
        }
        return (met, progress, open)
    }

    /// Normalised codes Penn applied to some requirement of one audit, at any
    /// depth: the same walk `DegreeWhatIf.summarize` does.
    private static func appliedCodes(_ audit: DegreeAudit) -> Set<String> {
        var codes = Set<String>()
        func walk(_ rules: [AuditRule]) {
            for rule in rules {
                for course in rule.applied { codes.insert(DegreePlanMath.normalizedCode(course.code)) }
                walk(rule.children)
            }
        }
        for block in audit.blocks { walk(block.rules) }
        return codes
    }

    /// Course codes Penn applied to a requirement in two or more of the
    /// audits, sorted, each once.
    public static func sharedCourses(_ audits: [DegreeLabeledAudit]) -> [String] {
        var tally: [String: Int] = [:]
        for entry in audits {
            for code in appliedCodes(entry.audit) { tally[code, default: 0] += 1 }
        }
        return tally.filter { $0.value >= 2 }.map { $0.key }.sorted()
    }

    /// For each planned course code (normalised), every degree whose audit
    /// lists it among the options of a requirement still open: at most one fit
    /// per audit, in the order of `audits`. A code that fits nothing is absent.
    /// Built on `DegreePlanMath.coverage`, so the matching rule is the single
    /// degree screen's own. With exactly one audit the label is empty.
    public static func fits(plan: DegreePlan, audits: [DegreeLabeledAudit]) -> [String: [DegreePlanFit]] {
        var out: [String: [DegreePlanFit]] = [:]
        let single = audits.count == 1
        for entry in audits {
            let covered = DegreePlanMath.coverage(plan: plan, audit: entry.audit)
            for (code, requirement) in covered {
                out[code, default: []].append(
                    DegreePlanFit(degreeLabel: single ? "" : entry.label, requirement: requirement))
            }
        }
        return out
    }

    /// The open requirements of each audit, in order; a degree with none open
    /// is left out.
    public static func openGroups(_ audits: [DegreeLabeledAudit]) -> [DegreeOpenGroup] {
        var groups: [DegreeOpenGroup] = []
        for entry in audits {
            let open = DegreePlanMath.openRequirements(in: entry.audit)
            if !open.isEmpty {
                groups.append(DegreeOpenGroup(degreeID: entry.degreeID, label: entry.label, requirements: open))
            }
        }
        return groups
    }

    /// Every course of every audit, the first occurrence of a code winning,
    /// for looking up credits and titles.
    public static func mergedCourses(_ audits: [DegreeLabeledAudit]) -> [AuditCourse] {
        var seen = Set<String>()
        var out: [AuditCourse] = []
        for entry in audits {
            for course in entry.audit.courses {
                if seen.insert(DegreePlanMath.normalizedCode(course.code)).inserted { out.append(course) }
            }
        }
        return out
    }
}
