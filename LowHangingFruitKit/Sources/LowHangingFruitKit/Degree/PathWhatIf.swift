import Foundation

// Degree progress, v12. The four change rules below mirror Path@Penn's own
// page script (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md, "What the page's own
// script says"): `new-program`, `add-major`, `add-minor`, `add-conc`. The page
// is the specification, quirks included, because the audit it runs is Penn's
// and this app only chooses which description to hand it.

public enum PathWhatIfChange: String, Codable, Sendable, CaseIterable {
    case newProgram, addMajor, addMinor, addConcentration

    /// UI copy, lowercase by the app's rule.
    public var label: String {
        switch self {
        case .newProgram: return "switch to"
        case .addMajor: return "add major"
        case .addMinor: return "add minor"
        case .addConcentration: return "add concentration"
        }
    }
}

public struct PathWhatIfPlan: Codable, Sendable, Hashable, Identifiable {
    public let change: PathWhatIfChange
    /// The catalogue entry the change came from.
    public let programCode: String
    /// What the page is sent as `degreeInfo`.
    public let degreeInfo: [String: String]
    /// What the screen shows.
    public let goals: DegreeGoals
    public var id: String { change.rawValue + "|" + programCode }

    public init(change: PathWhatIfChange, programCode: String, degreeInfo: [String: String], goals: DegreeGoals) {
        self.change = change
        self.programCode = programCode
        self.degreeInfo = degreeInfo
        self.goals = goals
    }
}

public enum PathWhatIf {
    /// Every change the page would allow for this catalogue entry, in the order
    /// add minor, add concentration, add major, switch to. Each rule yields at
    /// most one plan. Where several of the student's degrees qualify, the last
    /// one wins, because the page's own loop overwrites as it goes.
    public static func plans(for program: PathProgramInfo, current: [StudentDegree]) -> [PathWhatIfPlan] {
        var result: [PathWhatIfPlan] = []

        // add-minor: the entry lists the programs it can be a minor of. The
        // page appends the entry's major code as the minor code; that looks
        // odd and is what the page does, so it is copied.
        if !program.minorSisPrograms.isEmpty && !program.major.isEmpty {
            var chosen: [String: String]? = nil
            for degree in current {
                guard program.minorSisPrograms.contains(degree.program) else { continue }
                guard !degree.minors.contains(program.major), !degree.majors.contains(program.major) else { continue }
                var info = degree.raw
                info["minor"] = (degree.minors + [program.major]).joined(separator: ",")
                chosen = info
            }
            if let info = chosen {
                result.append(plan(.addMinor, program: program, info: info))
            }
        }

        // add-conc: same degree, a major the student already has, a
        // concentration not yet held. StudentDegree already drops "NCON", so a
        // first concentration replaces it.
        if !program.concentration.isEmpty {
            var chosen: [String: String]? = nil
            for degree in current {
                guard program.degree == degree.degree else { continue }
                guard degree.majors.contains(program.major) else { continue }
                guard !degree.concentrations.contains(program.concentration) else { continue }
                var info = degree.raw
                info["conc"] = (degree.concentrations + [program.concentration]).joined(separator: ",")
                chosen = info
            }
            if let info = chosen {
                result.append(plan(.addConcentration, program: program, info: info))
            }
        }

        // add-major: same degree and college, a major not yet held.
        if !program.major.isEmpty {
            var chosen: [String: String]? = nil
            for degree in current {
                guard program.degree == degree.degree else { continue }
                guard program.college == degree.college else { continue }
                guard !degree.majors.contains(program.major) else { continue }
                var info = degree.raw
                info["major"] = (degree.majors + [program.major]).joined(separator: ",")
                chosen = info
            }
            if let info = chosen {
                result.append(plan(.addMajor, program: program, info: info))
            }
        }

        // new-program: never a minor (a minor is added, not switched to), and
        // the page needs a level to run an audit at all.
        if !program.degree.isEmpty && program.degree.uppercased() != "MINOR" && !program.level.isEmpty {
            var info: [String: String] = ["degc": program.degree, "levl": program.level]
            if !program.college.isEmpty { info["coll"] = program.college }
            if !program.major.isEmpty { info["major"] = program.major }
            if !program.concentration.isEmpty { info["conc"] = program.concentration }
            if !program.sisProgram.isEmpty { info["program"] = program.sisProgram }
            result.append(plan(.newProgram, program: program, info: info))
        }

        return result
    }

    private static func plan(_ change: PathWhatIfChange, program: PathProgramInfo, info: [String: String]) -> PathWhatIfPlan {
        PathWhatIfPlan(
            change: change,
            programCode: program.code,
            degreeInfo: info,
            goals: StudentDegree(raw: info).goals
        )
    }
}
