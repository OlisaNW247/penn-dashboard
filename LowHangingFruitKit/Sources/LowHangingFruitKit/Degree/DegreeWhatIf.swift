import Foundation

// Degree progress, v12 (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md).
// Pure comparison of two audits; no endpoint is touched here, but the audits
// it compares come from Degree Works constants that are UNVERIFIED.

public struct DegreeWhatIfSummary: Sendable, Equatable {
    public let target: DegreeGoals
    public let met: Int
    public let inProgress: Int
    public let open: Int
    /// Courses the student already has that the target audit applied somewhere.
    public let alreadyCounting: [AuditCourse]
    /// Blocks only the target has (a new minor's block), for the header line.
    public let newBlocks: [AuditBlock]

    public init(target: DegreeGoals, met: Int, inProgress: Int, open: Int, alreadyCounting: [AuditCourse], newBlocks: [AuditBlock]) {
        self.target = target
        self.met = met
        self.inProgress = inProgress
        self.open = open
        self.alreadyCounting = alreadyCounting
        self.newBlocks = newBlocks
    }
}

public enum DegreeWhatIf {
    /// Counts come from the target audit alone. "Already counting" is matched
    /// by course code, not by id, because a retaken course appears twice and
    /// should be counted once; the current audit's copy is the one returned.
    /// With no current audit the target's own course list stands in, since a
    /// what-if is run over the student's real classes.
    public static func summarize(current: DegreeAudit?, target: DegreeAudit) -> DegreeWhatIfSummary {
        let counts = target.ruleCounts

        var appliedCodes = Set<String>()
        func walk(_ rules: [AuditRule]) {
            for rule in rules {
                for course in rule.applied { appliedCodes.insert(course.code) }
                walk(rule.children)
            }
        }
        for block in target.blocks { walk(block.rules) }

        let pool = current?.courses ?? target.courses
        var seen = Set<String>()
        var counting: [AuditCourse] = []
        for course in pool where appliedCodes.contains(course.code) {
            if seen.insert(course.code).inserted { counting.append(course) }
        }
        counting.sort { a, b in
            switch (a.termCode, b.termCode) {
            case let (x?, y?): return x != y ? x < y : a.code < b.code
            case (nil, nil): return a.code < b.code
            case (_?, nil): return true
            case (nil, _?): return false
            }
        }

        var newBlocks: [AuditBlock] = []
        if let current {
            let known = Set(current.blocks.map(blockKey))
            newBlocks = target.blocks.filter { !known.contains(blockKey($0)) }
        }

        return DegreeWhatIfSummary(
            target: target.goals, met: counts.met, inProgress: counts.inProgress, open: counts.open,
            alreadyCounting: counting, newBlocks: newBlocks)
    }

    private static func blockKey(_ block: AuditBlock) -> String {
        block.value.isEmpty ? block.id.uppercased() : "\(block.type.uppercased()):\(block.value.uppercased())"
    }

    /// "+ math minor" when the target only adds minors, concentrations or
    /// majors to what the student has; otherwise "switch to economics, ba".
    public static func headline(current: DegreeGoals?, target: DegreeGoals, descriptions: [String: String]) -> String {
        func word(_ key: String) -> String {
            (descriptions[key] ?? key).trimmingCharacters(in: .whitespaces).lowercased()
        }
        func added(_ now: [String], _ before: [String]) -> [String] {
            let had = Set(before.map { $0.uppercased() })
            return now.filter { !had.contains($0.uppercased()) }
        }
        func dropped(_ now: [String], _ before: [String]) -> Bool {
            let has = Set(now.map { $0.uppercased() })
            return before.contains { !has.contains($0.uppercased()) }
        }
        func same(_ a: String?, _ b: String?) -> Bool {
            (a ?? "").uppercased() == (b ?? "").uppercased()
        }

        guard let current else { return "switch to " + target.title(descriptions: descriptions) }

        let sameBase = same(current.degree, target.degree) && same(current.program, target.program)
        let lostAnything = dropped(target.majors, current.majors)
            || dropped(target.minors, current.minors)
            || dropped(target.concentrations, current.concentrations)
        if sameBase && !lostAnything {
            var parts: [String] = []
            parts += added(target.majors, current.majors).map { "+ \(word($0)) major" }
            parts += added(target.concentrations, current.concentrations).map { "+ \(word($0)) concentration" }
            parts += added(target.minors, current.minors).map { "+ \(word($0)) minor" }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        let title = target.title(descriptions: descriptions)
        return "switch to " + (title.isEmpty ? "another degree" : title)
    }
}
