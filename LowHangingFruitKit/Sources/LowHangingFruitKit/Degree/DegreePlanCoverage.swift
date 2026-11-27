import Foundation

// What the planning engine says its schedule fills, per degree, and how that
// claim adjusts the ring. The projection (`DegreeProjection`) can only count
// audit rules it can match to a planned course: a rule needing several
// courses, a credit-total row, a slot the planner waives (a language
// placement, a capstone met by senior design) or a parent row never matches,
// so a plan that fills everything still read short of 100 on Olisa's phone
// (2026-11-27). The planner knows whether its schedule covers a degree, so it
// says so, and the figure follows it. The figure stays this app's estimate
// ("≈"), Penn's number in the middle of the ring never changes, and nothing is
// called met. The wrong fix is loosening the matching: it would count rules
// the plan does not fill.

/// The wire form, as the engine sends it.
public struct DegreeEngineCoverage: Codable, Sendable, Equatable {
    /// The `StudentDegree.id` the phone sent.
    public let degreeId: String
    /// Open requirement slots the planner considered.
    public let slots: Int
    /// How many of them the returned schedule fills (never above `slots`).
    public let filled: Int
    public let complete: Bool
    /// Slots the DRAWN schedule covers by the target term (nothing in it needs
    /// an approval); nil when no target was named or from an older server.
    public let filledByTarget: Int?
    /// Slots the best case would cover by the target term, if the advisor
    /// approves the open questions; nil likewise.
    public let bestFilledByTarget: Int?

    /// `0 <= filledByTarget <= filled <= slots` and
    /// `filledByTarget <= bestFilledByTarget <= slots`, whatever was sent.
    static func clampedTargets(
        slots: Int, filled: Int, target: Int?, best: Int?
    ) -> (target: Int?, best: Int?) {
        let t = target.map { min(filled, max(0, $0)) }
        let b = best.map { min(slots, max(t ?? 0, max(0, $0))) }
        return (t, b)
    }

    public init(
        degreeId: String, slots: Int, filled: Int, complete: Bool,
        filledByTarget: Int? = nil, bestFilledByTarget: Int? = nil
    ) {
        let s = max(0, slots)
        let f = min(s, max(0, filled))
        self.degreeId = degreeId
        self.slots = s
        self.filled = f
        self.complete = complete
        let clamped = Self.clampedTargets(slots: s, filled: f, target: filledByTarget, best: bestFilledByTarget)
        self.filledByTarget = clamped.target
        self.bestFilledByTarget = clamped.best
    }

    private enum CodingKeys: String, CodingKey {
        case degreeId, slots, filled, complete, filledByTarget, bestFilledByTarget
    }

    /// The degree id is required; counts read as 0 when missing or not a
    /// number, are never negative, and `filled` is clamped to `slots`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .degreeId)
        let s: Int? = (try? c.decodeIfPresent(Int.self, forKey: .slots)) ?? nil
        let f: Int? = (try? c.decodeIfPresent(Int.self, forKey: .filled)) ?? nil
        let done: Bool? = (try? c.decodeIfPresent(Bool.self, forKey: .complete)) ?? nil
        let t: Int? = (try? c.decodeIfPresent(Int.self, forKey: .filledByTarget)) ?? nil
        let b: Int? = (try? c.decodeIfPresent(Int.self, forKey: .bestFilledByTarget)) ?? nil
        self.init(degreeId: id, slots: s ?? 0, filled: f ?? 0, complete: done ?? false,
                  filledByTarget: t, bestFilledByTarget: b)
    }
}

/// The stored form, kept on `DegreePlanSummary`.
public struct DegreePlanCoverage: Codable, Sendable, Equatable {
    public let degreeID: String
    public let slots: Int
    public let filled: Int
    public let complete: Bool
    public let filledByTarget: Int?
    public let bestFilledByTarget: Int?

    public init(
        degreeID: String, slots: Int, filled: Int, complete: Bool,
        filledByTarget: Int? = nil, bestFilledByTarget: Int? = nil
    ) {
        let s = max(0, slots)
        let f = min(s, max(0, filled))
        self.degreeID = degreeID
        self.slots = s
        self.filled = f
        self.complete = complete
        let clamped = DegreeEngineCoverage.clampedTargets(
            slots: s, filled: f, target: filledByTarget, best: bestFilledByTarget)
        self.filledByTarget = clamped.target
        self.bestFilledByTarget = clamped.best
    }

    public init(_ wire: DegreeEngineCoverage) {
        self.init(degreeID: wire.degreeId, slots: wire.slots, filled: wire.filled, complete: wire.complete,
                  filledByTarget: wire.filledByTarget, bestFilledByTarget: wire.bestFilledByTarget)
    }

    private enum CodingKeys: String, CodingKey {
        case degreeID, slots, filled, complete, filledByTarget, bestFilledByTarget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .degreeID)
        let s: Int? = (try? c.decodeIfPresent(Int.self, forKey: .slots)) ?? nil
        let f: Int? = (try? c.decodeIfPresent(Int.self, forKey: .filled)) ?? nil
        let done: Bool? = (try? c.decodeIfPresent(Bool.self, forKey: .complete)) ?? nil
        let t: Int? = (try? c.decodeIfPresent(Int.self, forKey: .filledByTarget)) ?? nil
        let b: Int? = (try? c.decodeIfPresent(Int.self, forKey: .bestFilledByTarget)) ?? nil
        self.init(degreeID: id, slots: s ?? 0, filled: f ?? 0, complete: done ?? false,
                  filledByTarget: t, bestFilledByTarget: b)
    }

    /// The coverage that applies to the audit being drawn for `degreeID`, or
    /// nil. It applies only when the plan was made against THAT audit: when
    /// the summary has a stand-in for the degree, the drawn audit must be a
    /// what-if with the stand-in's goals; when it has none, the drawn audit
    /// must not be a what-if. Anything else draws today's estimate, because a
    /// claim about the management what-if says nothing about the declared
    /// audit's rules.
    public static func applicable(
        for degreeID: String, audit: DegreeAudit, summary: DegreePlanSummary?
    ) -> DegreePlanCoverage? {
        guard let summary,
              let found = summary.coverage?.first(where: { $0.degreeID == degreeID })
        else { return nil }
        if let standIn = summary.standIns?.first(where: { $0.degreeID == degreeID }) {
            guard audit.isWhatIf, audit.goals == standIn.goals else { return nil }
        } else {
            guard !audit.isWhatIf else { return nil }
        }
        return found
    }
}

/// The ring's two cases when the student named a finish term: what the drawn
/// schedule covers by then (nothing in it needs an approval) and what the best
/// case would cover if the advisor approves the open questions. Both are
/// fractions of the WHOLE ring to add after Penn's own percent: the remainder
/// (1 - base) times covered slots over slots. This app's estimate, like every
/// planned figure; Penn's number in the middle never changes.
public struct DegreeRingCases: Sendable, Equatable {
    public let granted: Double
    public let best: Double
    /// True only when both fields exist, slots > 0 and the best case exceeds
    /// the granted one by at least half a percent of the ring.
    public let showsBest: Bool

    /// nil when there is no second-case data to draw: no coverage, no slots,
    /// or no `filledByTarget` (an older server, or no target). Callers then
    /// keep the single "with plan" figure.
    public static func make(coverage: DegreePlanCoverage?, base: Double) -> DegreeRingCases? {
        guard let coverage, coverage.slots > 0, let target = coverage.filledByTarget else { return nil }
        let room = max(0, 1 - min(1, max(0, base)))
        let slots = Double(coverage.slots)
        let granted = room * Double(target) / slots
        if let bestCount = coverage.bestFilledByTarget {
            let best = room * Double(bestCount) / slots
            return DegreeRingCases(granted: granted, best: best, showsBest: best - granted >= 0.005 - 1e-12)
        }
        return DegreeRingCases(granted: granted, best: granted, showsBest: false)
    }
}

extension DegreeProjection {
    /// This projection adjusted by the planner's claim for the audit it was
    /// made for (`coverage` already passed `DegreePlanCoverage.applicable`).
    ///
    /// - complete: every rule the audit shows open is treated as covered
    ///   (an entry with `fill` 1; chips already laid are kept, none invented),
    ///   so block bars, the combined bar and the planned count come out whole;
    ///   the arc and the text both read 1. A rule Penn shows in progress is
    ///   left as the projection had it, because the bar draws it in its own
    ///   segment and counting it again would draw it twice; the text already
    ///   counts it as done.
    /// - not complete with `slots` > 0: the arc and the text use the larger of
    ///   today's estimate and filled / slots, never above 1; rules and bars
    ///   stay as computed.
    /// - nil, or no slots and not complete: unchanged.
    public func adjusted(by coverage: DegreePlanCoverage?, audit: DegreeAudit) -> DegreeProjection {
        guard let coverage else { return self }
        if coverage.complete {
            var entries = rules
            var openFilled = 0.0
            func walk(_ list: [AuditRule], blockID: String) {
                for rule in list {
                    if rule.status == .open {
                        let key = DegreeProjection.key(blockID: blockID, ruleID: rule.id)
                        let existing = entries[key]
                        if (existing?.fill ?? 0) < 1 {
                            entries[key] = DegreeRuleProjection(planned: existing?.planned ?? [], fill: 1)
                        }
                        openFilled += 1
                    }
                    walk(rule.children, blockID: blockID)
                }
            }
            for block in audit.blocks { walk(block.rules, blockID: block.id) }
            return DegreeProjection(
                rules: entries, placed: placed, unplaced: unplaced,
                openFill: max(openFill, openFilled), ringShare: 1, counted: counted,
                countedAll: countedAll, withPlanShare: 1)
        }
        guard coverage.slots > 0 else { return self }
        let share = min(1, max(0, Double(coverage.filled) / Double(coverage.slots)))
        return DegreeProjection(
            rules: rules, placed: placed, unplaced: unplaced, openFill: openFill,
            ringShare: max(ringShare, share), counted: counted, countedAll: countedAll,
            withPlanShare: max(withPlanShare, share))
    }
}
