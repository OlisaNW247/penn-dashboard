import Foundation

/// A grading scheme the backend extracted from a course's syllabus text —
/// the server-side counterpart to `SyllabusParser.parse`, run once per
/// course (not per student) and shared through the sync manifest so a
/// student never waits on their own device to re-derive what the syllabus
/// already said. Kept as a distinct type from `SyllabusGradingScheme`
/// rather than reusing it directly: this is the *wire-shaped* extraction
/// (weights, components, when it was made), and `SyllabusGradingScheme.from
/// (profile:)` (Syllabus/SyllabusModels.swift) is the one place that turns
/// it into the on-device proposal type, applying the same honesty gate
/// `SyllabusParser` applies to its own parses — nothing here is offered to
/// the student as fact until it passes that gate.
public struct CourseGradingProfile: Sendable, Hashable, Codable, Identifiable {
    /// One grading category as the server's extraction read it — "Problem
    /// Sets … 30%, drop the lowest two, 10 expected."
    public struct Weight: Sendable, Hashable, Codable {
        public let name: String
        public let percent: Double
        /// "there will be 10 problem sets" — nil when the syllabus didn't
        /// state a count, same meaning as `SyllabusCategory.expectedItemCount`.
        public let expectedCount: Int?
        /// "the lowest two are dropped" — nil (not 0) when the syllabus
        /// said nothing about drops, so `SyllabusGradingScheme.from(profile:)`
        /// can distinguish "server didn't see a drop rule" from "server saw
        /// zero drops," even though both currently map to the same `0` on
        /// `SyllabusCategory.dropLowest`.
        public let dropLowest: Int?

        public init(name: String, percent: Double, expectedCount: Int? = nil, dropLowest: Int? = nil) {
            self.name = name
            self.percent = percent
            self.expectedCount = expectedCount
            self.dropLowest = dropLowest
        }
    }

    /// One graded component of the course as the server's extraction
    /// identified it — distinct from `CatalogComponent`, which is the
    /// registrar's section-level view; this is the syllabus's own
    /// description of what it's grading ("Lab", "pass/fail") and is what
    /// `GradeSiteExclusion` reads to decide a Canvas site doesn't carry the
    /// course grade.
    public struct Component: Sendable, Hashable, Codable {
        public let name: String
        /// The syllabus's own words for how this component is graded, e.g.
        /// "Pass/Fail" or "Satisfactory/Unsatisfactory" — free text, not a
        /// closed enum, because the server is quoting the syllabus, not
        /// classifying it; `GradeSiteExclusion` does the classifying against
        /// this string with its own pattern.
        public let gradingBasis: String?
        public let creditUnits: Double?

        public init(name: String, gradingBasis: String? = nil, creditUnits: Double? = nil) {
            self.name = name
            self.gradingBasis = gradingBasis
            self.creditUnits = creditUnits
        }
    }

    public var id: String { courseID }

    public let courseID: String
    public let weights: [Weight]
    public let components: [Component]
    /// When the server ran this extraction — shown so a stale profile
    /// (superseded by a newer syllabus) can eventually be told apart from a
    /// fresh one, though nothing in this Kit compares it yet.
    public let extractedAt: Date

    public init(courseID: String, weights: [Weight], components: [Component], extractedAt: Date) {
        self.courseID = courseID
        self.weights = weights
        self.components = components
        self.extractedAt = extractedAt
    }
}
