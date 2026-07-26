import Foundation

/// One letter-grade band: everything from `minPercent` up to the next band.
public struct GradeBand: Sendable, Hashable, Codable, Identifiable {
    public let letter: String
    public let minPercent: Double
    /// Penn 4.0-scale value for this band.
    public let gpa: Double

    public var id: String { letter }

    public init(letter: String, minPercent: Double, gpa: Double) {
        self.letter = letter
        self.minPercent = minPercent
        self.gpa = gpa
    }
}

/// A course's letter-grade cutoffs.
///
/// Canvas doesn't expose the professor's real cutoffs, so the default is the
/// standard table and every number derived from it must be labeled an
/// estimate. A syllabus can supply the real thing (`isCustom == true`), which
/// is the whole reason `SyllabusParser` bothers to read cutoff tables — a
/// course that says "A ≥ 90" makes "you need 87% on the final for an A" a
/// fact about that class rather than a guess.
public struct GradeCutoffs: Sendable, Hashable, Codable {
    /// Bands sorted high → low by `minPercent`.
    public let bands: [GradeBand]
    /// True when these came from the user's syllabus rather than the standard
    /// table — drives whether the UI says "standard cutoffs" or "your syllabus".
    public let isCustom: Bool

    public init(bands: [GradeBand], isCustom: Bool) {
        self.bands = bands.sorted { $0.minPercent > $1.minPercent }
        self.isCustom = isCustom
    }

    /// The standard cutoffs mapped to Penn's scale (A+ and A both 4.0; no D−),
    /// matching what `GradeScale.gpa(forPercent:)` has always used.
    public static let standard = GradeCutoffs(
        bands: [
            GradeBand(letter: "A",  minPercent: 93, gpa: 4.0),
            GradeBand(letter: "A-", minPercent: 90, gpa: 3.7),
            GradeBand(letter: "B+", minPercent: 87, gpa: 3.3),
            GradeBand(letter: "B",  minPercent: 83, gpa: 3.0),
            GradeBand(letter: "B-", minPercent: 80, gpa: 2.7),
            GradeBand(letter: "C+", minPercent: 77, gpa: 2.3),
            GradeBand(letter: "C",  minPercent: 73, gpa: 2.0),
            GradeBand(letter: "C-", minPercent: 70, gpa: 1.7),
            GradeBand(letter: "D+", minPercent: 67, gpa: 1.3),
            GradeBand(letter: "D",  minPercent: 60, gpa: 1.0),
            GradeBand(letter: "F",  minPercent: 0,  gpa: 0.0),
        ],
        isCustom: false
    )

    /// The band a percent falls in. Never nil for the standard table (F is the
    /// floor); nil only for a custom table whose lowest band starts above the
    /// given percent.
    public func band(forPercent percent: Double) -> GradeBand? {
        bands.first { percent >= $0.minPercent }
    }

    public func letter(forPercent percent: Double) -> String? {
        band(forPercent: percent)?.letter
    }

    public func gpa(forPercent percent: Double) -> Double {
        band(forPercent: percent)?.gpa ?? 0
    }

    /// The next band above `percent` — "what you're reaching for" in the
    /// report's target picker. Nil when already in the top band.
    public func nextBandUp(fromPercent percent: Double) -> GradeBand? {
        bands.last { $0.minPercent > percent }
    }

    /// Bands worth offering as targets in the report, best first, excluding
    /// anything at or below a 0% floor (an "F target" is not a goal).
    public var targetBands: [GradeBand] {
        bands.filter { $0.minPercent > 0 }
    }
}

/// Percent → 4.0-scale conversion for the term summary (docs/grades.md §11).
///
/// Professors set their own letter cutoffs, and Canvas doesn't expose them, so
/// this is an **estimate** on the standard cutoffs mapped to Penn's scale
/// (A+ and A both 4.0; no D−). The UI must always label the result
/// "estimated". Per-course code should prefer `GradeCutoffs` directly, since a
/// watched course may carry its syllabus's real cutoffs.
public enum GradeScale {
    public static func gpa(forPercent percent: Double) -> Double {
        GradeCutoffs.standard.gpa(forPercent: percent)
    }

    public static func letter(forPercent percent: Double) -> String {
        GradeCutoffs.standard.letter(forPercent: percent) ?? "F"
    }
}
