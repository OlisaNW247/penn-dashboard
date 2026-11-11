import Foundation

// Degree progress, v12. The shapes here were observed on 2026-11-10 (names and
// types only); see docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md, "The rewrite
// contract". Nothing in this file touches the network or a WebView: it is the
// value types the bridge decodes into and the what-if rules read.

/// Comma-list handling shared by the Path types. Internal on purpose.
enum PathText {
    /// "CIS, MATH,," becomes ["CIS", "MATH"]: trimmed, empties dropped, order kept.
    static func list(_ value: String) -> [String] {
        var result: [String] = []
        for piece in value.split(separator: ",", omittingEmptySubsequences: true) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

/// One curriculum entry of the student's own record (an element of `cur`).
///
/// `raw` is the entry's string fields exactly as the page holds them, and it
/// goes back to the page verbatim as the `degreeInfo` of an audit. Every other
/// field is derived from it, so the two can never disagree. The wrong shape
/// would be to rebuild `degreeInfo` from the derived fields: the page may
/// carry keys this app has never seen, and an audit run with a lossy
/// description is a different audit.
public struct StudentDegree: Codable, Sendable, Hashable, Identifiable {
    public let level: String
    public let degree: String
    public let college: String
    public let program: String
    public let majors: [String]
    /// The code "NCON" (no concentration) is dropped, so an empty list means none.
    public let concentrations: [String]
    public let minors: [String]
    public let catalogTerm: String?
    public let raw: [String: String]

    public var id: String {
        "\(college)|\(degree)|\(majors.joined(separator: ","))|\(program)"
    }

    public init(raw: [String: String]) {
        self.raw = raw
        self.level = raw["levl"] ?? ""
        self.degree = raw["degc"] ?? ""
        self.college = raw["coll"] ?? ""
        self.program = raw["program"] ?? ""
        self.majors = PathText.list(raw["major"] ?? "")
        var kept: [String] = []
        for code in PathText.list(raw["conc"] ?? "") {
            if code.uppercased() != PathAuditDecoder.noConcentrationCode { kept.append(code) }
        }
        self.concentrations = kept
        self.minors = PathText.list(raw["minor"] ?? "")
        let term = raw["ctlg"] ?? ""
        self.catalogTerm = term.isEmpty ? nil : term
    }

    /// What the screen shows for this degree; empty strings become nil.
    public var goals: DegreeGoals {
        DegreeGoals(
            school: PathText.nonEmpty(level),
            college: PathText.nonEmpty(college),
            program: PathText.nonEmpty(program),
            degree: PathText.nonEmpty(degree),
            majors: majors,
            concentrations: concentrations,
            minors: minors,
            catalogYear: catalogTerm
        )
    }
}

/// One line of Penn's program catalogue ("programs-v2-list").
public struct PathProgramListing: Codable, Sendable, Hashable, Identifiable {
    public let code: String
    public let title: String
    public var id: String { code }

    public init(code: String, title: String) {
        self.code = code
        self.title = title
    }
}

/// The part of "programs-v2-info" the what-if rules read. The requirement
/// template that response also carries is never brought across the bridge.
public struct PathProgramInfo: Codable, Sendable, Hashable {
    public let code: String
    public let name: String
    public let type: String
    public let level: String
    public let degree: String
    public let major: String
    public let minor: String
    public let concentration: String
    public let college: String
    public let sisProgram: String
    public let minorSisPrograms: [String]

    public init(
        code: String, name: String, type: String, level: String, degree: String, major: String,
        minor: String, concentration: String, college: String, sisProgram: String,
        minorSisPrograms: [String]
    ) {
        self.code = code
        self.name = name
        self.type = type
        self.level = level
        self.degree = degree
        self.major = major
        self.minor = minor
        self.concentration = concentration
        self.college = college
        self.sisProgram = sisProgram
        self.minorSisPrograms = minorSisPrograms
    }
}

/// The page's five code-to-name maps.
public struct PathDictionaries: Codable, Sendable, Equatable {
    public var majors: [String: String]
    public var degrees: [String: String]
    public var levels: [String: String]
    public var colleges: [String: String]
    public var programs: [String: String]

    public init(
        majors: [String: String] = [:], degrees: [String: String] = [:], levels: [String: String] = [:],
        colleges: [String: String] = [:], programs: [String: String] = [:]
    ) {
        self.majors = majors
        self.degrees = degrees
        self.levels = levels
        self.colleges = colleges
        self.programs = programs
    }

    /// One flat lookup for `DegreeGoals.title(descriptions:)`. A code that sits
    /// in two maps takes the more specific meaning: majors win over degrees
    /// over programs over colleges over levels. Written lowest priority first
    /// so each later map simply overwrites.
    public var descriptions: [String: String] {
        var flat: [String: String] = [:]
        let lowestFirst: [[String: String]] = [levels, colleges, programs, degrees, majors]
        for map in lowestFirst {
            for (code, name) in map { flat[code] = name }
        }
        return flat
    }
}
