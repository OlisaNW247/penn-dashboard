import Foundation

// What each planned course is worth to the degree estimate, and which courses
// are worth adding. Until 2026-11-13 the plan tab's rule was "no ranking, no
// suggestions, Penn's list in Penn's order". The owner reversed it in his own
// words: adding courses to the plan "should guide you" and only offer courses
// that contribute to the degree, and "classes that contribute to a higher
// percentage of completion to your degrees should be highlighted differently
// compared to classes that don't."
//
// What survives of the old rule: a candidate is still only a course Penn itself
// lists as an option for a requirement that is still open, and the points are
// this app's estimate (the same one the ring labels "with plan"), never Penn's
// word on what counts. A course is not called satisfying anything here, only
// worth some points of that estimate.
//
// A course whose only requirement the plan already fills is left out on purpose.
// It would add nothing to the estimate, and offering it is how a student
// over-plans one requirement while another stays empty. The wrong fix is to
// list it with zero points: that is noise in a list whose whole job is to point
// at what helps. A course that counts toward a rule with room but moves nothing
// (a rule Penn already shows in progress) is kept, with zero points, because it
// does count.
//
// Points are measured by laying the plan against each audit twice, with and
// without the course, and differencing the ring gain. Everything is pure: no
// clock, no store, no I/O.

/// The points one course adds to one degree's ring estimate.
public struct DegreeGain: Sendable, Equatable, Hashable {
    public let degreeID: String
    /// Empty when the caller passed exactly one audit.
    public let degreeLabel: String
    /// The requirement the course is laid against (`DegreeProjection.counted`).
    public let requirement: String
    /// 0...100. Can be 0 for a course that counts but moves nothing.
    public let points: Double

    public init(degreeID: String, degreeLabel: String, requirement: String, points: Double) {
        self.degreeID = degreeID
        self.degreeLabel = degreeLabel
        self.requirement = requirement
        self.points = points
    }
}

/// A course worth adding, with what it would gain in each degree it counts in.
public struct DegreeSuggestion: Sendable, Equatable, Identifiable {
    /// Penn's own entry (code, title, credits) as first seen.
    public let course: AdviceCourse
    /// Never empty; in the order of the audits.
    public let gains: [DegreeGain]
    public var id: String { DegreePlanMath.normalizedCode(course.code) }
    public var points: Double { gains.reduce(0) { $0 + $1.points } }

    public init(course: AdviceCourse, gains: [DegreeGain]) {
        self.course = course
        self.gains = gains
    }
}

public enum DegreeContribution {
    /// One audit with its plan-free projection and ring start, computed once.
    private struct Baseline {
        let labeled: DegreeLabeledAudit
        let before: DegreeProjection
        let base: Double
    }

    private static func baselines(plan: DegreePlan, audits: [DegreeLabeledAudit]) -> [Baseline] {
        audits.map { entry in
            Baseline(
                labeled: entry,
                before: DegreeProjection.make(plan: plan, audit: entry.audit),
                base: DegreeProjection.baseFraction(of: entry.audit))
        }
    }

    private static func points(before: DegreeProjection, after: DegreeProjection, base: Double) -> Double {
        max(0, (after.ringGain(base: base) - before.ringGain(base: base)) * 100)
    }

    private static func label(of entry: DegreeLabeledAudit, among count: Int) -> String {
        count == 1 ? "" : entry.label
    }

    /// For each planned course that counts in at least one audit: its gains, in
    /// the order of `audits`. Key is the normalized code. A planned course that
    /// counts nowhere is absent.
    public static func planned(plan: DegreePlan, audits: [DegreeLabeledAudit]) -> [String: [DegreeGain]] {
        var out: [String: [DegreeGain]] = [:]
        for entry in audits {
            let base = DegreeProjection.baseFraction(of: entry.audit)
            let full = DegreeProjection.make(plan: plan, audit: entry.audit)
            var visited = Set<String>()
            for term in plan.terms {
                for course in term.courses {
                    let code = DegreePlanMath.normalizedCode(course.code)
                    if code.isEmpty || !visited.insert(code).inserted { continue }
                    guard let requirement = full.counted[code] else { continue }
                    var without = plan
                    without.terms = plan.terms.map { existing in
                        PlannedTerm(termCode: existing.termCode, courses: existing.courses.filter {
                            DegreePlanMath.normalizedCode($0.code) != code
                        })
                    }
                    let lacking = DegreeProjection.make(plan: without, audit: entry.audit)
                    out[code, default: []].append(DegreeGain(
                        degreeID: entry.degreeID,
                        degreeLabel: label(of: entry, among: audits.count),
                        requirement: requirement,
                        points: points(before: lacking, after: full, base: base)))
                }
            }
        }
        return out
    }

    private static func gains(
        forNormalized code: String, credits: Double, plan: DegreePlan, baselines: [Baseline]
    ) -> [DegreeGain] {
        guard !code.isEmpty, !DegreePlanMath.isPlanned(code, in: plan) else { return [] }
        var extended = plan
        extended.terms.append(PlannedTerm(termCode: "999999", courses: [
            PlannedCourse(code: code, title: nil, credits: credits > 0 ? credits : 1),
        ]))
        var out: [DegreeGain] = []
        for baseline in baselines {
            let after = DegreeProjection.make(plan: extended, audit: baseline.labeled.audit)
            guard let requirement = after.counted[code] else { continue }
            out.append(DegreeGain(
                degreeID: baseline.labeled.degreeID,
                degreeLabel: label(of: baseline.labeled, among: baselines.count),
                requirement: requirement,
                points: points(before: baseline.before, after: after, base: baseline.base)))
        }
        return out
    }

    /// What adding one course (not yet planned) would gain. Empty when it would
    /// count nowhere, when the code normalizes to "", or when the plan already
    /// holds it.
    public static func gains(
        for code: String, credits: Double, plan: DegreePlan, audits: [DegreeLabeledAudit]
    ) -> [DegreeGain] {
        let normalized = DegreePlanMath.normalizedCode(code)
        return gains(
            forNormalized: normalized, credits: credits, plan: plan,
            baselines: baselines(plan: plan, audits: audits))
    }

    /// Courses worth adding: every option Penn lists for a requirement still
    /// open, in any audit, that is not planned, not on any audit's course list
    /// and not in `history`, and that would count in at least one audit. Sorted
    /// by points descending, then by number of gains descending, then by first
    /// appearance (audits in order, Penn's order inside each).
    public static func suggestions(
        plan: DegreePlan, audits: [DegreeLabeledAudit], history: [String: [String]]
    ) -> [DegreeSuggestion] {
        var takenAnywhere = Set<String>()
        for entry in audits {
            for course in entry.audit.courses { takenAnywhere.insert(DegreePlanMath.normalizedCode(course.code)) }
        }
        var seen = Set<String>()
        var candidates: [AdviceCourse] = []
        for entry in audits {
            let open = DegreePlanMath.addable(
                DegreePlanMath.openRequirements(in: entry.audit),
                plan: plan, audit: entry.audit, history: history)
            for requirement in open {
                for option in requirement.options {
                    let code = DegreePlanMath.normalizedCode(option.code)
                    if code.isEmpty || takenAnywhere.contains(code) { continue }
                    if seen.insert(code).inserted { candidates.append(option) }
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        let starts = baselines(plan: plan, audits: audits)
        var found: [(index: Int, suggestion: DegreeSuggestion)] = []
        for (index, course) in candidates.enumerated() {
            let code = DegreePlanMath.normalizedCode(course.code)
            let list = gains(forNormalized: code, credits: course.credits ?? 1, plan: plan, baselines: starts)
            if list.isEmpty { continue }
            found.append((index, DegreeSuggestion(course: course, gains: list)))
        }
        found.sort { lhs, rhs in
            let a = lhs.suggestion.points
            let b = rhs.suggestion.points
            if a != b { return a > b }
            let x = lhs.suggestion.gains.count
            let y = rhs.suggestion.gains.count
            if x != y { return x > y }
            return lhs.index < rhs.index
        }
        return found.map { $0.suggestion }
    }
}
