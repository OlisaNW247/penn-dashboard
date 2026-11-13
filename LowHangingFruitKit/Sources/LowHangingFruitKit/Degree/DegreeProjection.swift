import Foundation

// A projection of the student's planned courses onto Penn's degree audit, so
// the degree screen can show progress "going up" as courses are planned.
//
// This is the student's sketch laid beside Penn's audit and nothing more. A
// planned course is never called satisfied: whether a course counts is Penn's
// decision, made when it is taken, so the screen says "planned" and never
// "met" about anything here. The ring share is this app's own estimate, not
// Penn's percentage, and every place it is drawn labels it "with plan".
//
// The capacity rule is the point of the file. The earlier `coverage` rule in
// `DegreePlanMath` marks a requirement as covered when any planned course is
// among its options, which counts a 14-credit requirement as covered by one
// course; a bar built on it would jump to full on the first pick. The wrong
// fix is to keep that rule and scale the result. Here every requirement has a
// remaining need (credits, courses, or one course when Penn states none), each
// planned course consumes some of it, and a course that arrives after the need
// is spent is kept as overflow that adds nothing.
//
// A rule Penn already shows as in progress is drawn in progress on the bar. It
// can still hold planned courses and a fill of its own, but that fill is left
// out of `openFill` and of a block's share: counting it again would draw the
// same requirement twice. Everything is pure (no clock, no store, no I/O) and
// every output array follows the plan's order, never a dictionary's.

public struct DegreeRuleProjection: Sendable, Equatable {
    /// Planned courses laid against this rule, in plan order, overflow included.
    public let planned: [PlannedCourse]
    /// 0...1: the share of what the rule still needs that the plan would supply.
    public let fill: Double
    public var isFilled: Bool { fill >= 1 }

    public init(planned: [PlannedCourse], fill: Double) {
        self.planned = planned
        self.fill = fill
    }
}

public struct DegreeProjection: Sendable, Equatable {
    /// Keyed by `DegreeProjection.key(blockID:ruleID:)`.
    public let rules: [String: DegreeRuleProjection]
    /// Normalized codes of planned courses laid against some rule, plan order, distinct.
    public let placed: [String]
    /// Normalized codes of planned courses no open requirement lists, plan order, distinct.
    public let unplaced: [String]
    /// Sum of `fill` over countable rules whose status is `.open`.
    public let openFill: Double
    /// `openFill` over the countable rules that are open or in progress; 0 when
    /// there are none; clamped to 0...1.
    public let ringShare: Double
    /// Normalized code -> label of the requirement the course was laid against WITH room
    /// (it consumed some of the rule's remaining need). An overflow course and an unplaced
    /// course are absent. The label is the rule's label, or the block's title when the
    /// rule's label is empty (the same choice `DegreePlanMath.openRequirements` makes).
    public let counted: [String: String]

    init(
        rules: [String: DegreeRuleProjection], placed: [String], unplaced: [String],
        openFill: Double, ringShare: Double, counted: [String: String]
    ) {
        self.counted = counted
        self.rules = rules
        self.placed = placed
        self.unplaced = unplaced
        self.openFill = openFill
        self.ringShare = ringShare
    }

    public static let empty = DegreeProjection(rules: [:], placed: [], unplaced: [], openFill: 0, ringShare: 0, counted: [:])

    public var isEmpty: Bool { placed.isEmpty }

    public static func key(blockID: String, ruleID: String) -> String {
        "\(blockID)|\(ruleID)"
    }

    public func rule(blockID: String, ruleID: String) -> DegreeRuleProjection? {
        rules[Self.key(blockID: blockID, ruleID: ruleID)]
    }

    /// For one block: how many distinct planned courses are laid against its
    /// rules (any depth), and the share of its bar they add: the sum of `fill`
    /// over its open countable rules divided by its countable rule count (0
    /// when it has none).
    public func block(_ block: AuditBlock) -> (courses: Int, share: Double) {
        var codes = Set<String>()
        var countable = 0
        var openSum = 0.0
        func walk(_ rules: [AuditRule]) {
            for rule in rules {
                let entry = self.rules[Self.key(blockID: block.id, ruleID: rule.id)]
                if let entry {
                    for course in entry.planned { codes.insert(course.code) }
                }
                if rule.status != .info { countable += 1 }
                if rule.status == .open { openSum += entry?.fill ?? 0 }
                walk(rule.children)
            }
        }
        walk(block.rules)
        guard countable > 0 else { return (codes.count, 0) }
        return (codes.count, min(1, max(0, openSum / Double(countable))))
    }

    /// The arc to add to a ring whose done fraction is `fraction`:
    /// `(1 - fraction) * ringShare`, clamped to 0...(1 - fraction).
    /// The done share a ring starts from: Penn's percent / 100 clamped to 0...1 when the
    /// audit has one, else met / (met + inProgress + open) from `ruleCounts` (0 when
    /// there are no rules).
    public static func baseFraction(of audit: DegreeAudit) -> Double {
        if let percent = audit.percentComplete {
            return min(1, max(0, percent / 100))
        }
        let counts = audit.ruleCounts
        let total = counts.met + counts.inProgress + counts.open
        guard total > 0 else { return 0 }
        return Double(counts.met) / Double(total)
    }

    public func ringGain(base fraction: Double) -> Double {
        let room = max(0, 1 - fraction)
        return min(room, max(0, room * ringShare))
    }

    // MARK: Making a projection

    private struct Slot {
        let key: String
        let label: String
        let usesCredits: Bool
        let remaining: Double
        var left: Double
        var supplied: Double
        var planned: [PlannedCourse]
    }

    fileprivate static func isRequirement(_ rule: AuditRule) -> Bool {
        (rule.status == .open || rule.status == .inProgress) && !rule.advice.isEmpty
    }

    public static func make(plan: DegreePlan, audit: DegreeAudit?) -> DegreeProjection {
        guard let audit else { return .empty }
        let layout = DegreeProjectionLayoutCache.shared.layout(for: audit)

        // The plan's courses, once each, minus what Penn already counts.
        var seen = Set<String>()
        var candidates: [PlannedCourse] = []
        for term in plan.terms {
            for course in term.courses {
                let code = DegreePlanMath.normalizedCode(course.code)
                if code.isEmpty || layout.taken.contains(code) { continue }
                if seen.insert(code).inserted {
                    candidates.append(PlannedCourse(code: code, title: course.title, credits: course.credits))
                }
            }
        }
        guard !candidates.isEmpty else { return .empty }

        // Requirements in Penn's order, each with its remaining need.
        var slots: [Slot] = layout.requirements.map { requirement in
            Slot(key: requirement.key, label: requirement.label, usesCredits: requirement.usesCredits,
                 remaining: requirement.remaining, left: requirement.remaining, supplied: 0, planned: [])
        }

        // Lay each planned course against the first requirement that lists it
        // and still has room; else as overflow on the first that lists it.
        var placed: [String] = []
        var unplaced: [String] = []
        var counted: [String: String] = [:]
        for course in candidates {
            let listing = layout.listing[course.code] ?? []
            guard let firstListing = listing.first else {
                unplaced.append(course.code)
                continue
            }
            var target: Int?
            for index in listing where slots[index].left > 1e-9 {
                target = index
                break
            }
            if let target {
                let used = slots[target].usesCredits ? (course.credits > 0 ? course.credits : 1.0) : 1.0
                slots[target].left -= used
                slots[target].supplied += used
                slots[target].planned.append(course)
                counted[course.code] = slots[target].label
            } else {
                slots[firstListing].planned.append(course)
            }
            placed.append(course.code)
        }

        var entries: [String: DegreeRuleProjection] = [:]
        for slot in slots {
            let fill = slot.remaining > 0 ? min(1, slot.supplied / slot.remaining) : 0
            if !slot.planned.isEmpty || fill > 0 {
                entries[slot.key] = DegreeRuleProjection(planned: slot.planned, fill: fill)
            }
        }

        // A rule with no options of its own is as full as its unmet children
        // are on average; grandchildren feed children first.
        func derive(_ rules: [AuditRule], blockID: String) {
            for rule in rules {
                derive(rule.children, blockID: blockID)
                if isRequirement(rule) { continue }
                let pending = rule.children.filter { $0.status != .info && $0.status != .met }
                if pending.isEmpty { continue }
                var total = 0.0
                for child in pending {
                    total += entries[key(blockID: blockID, ruleID: child.id)]?.fill ?? 0
                }
                let mean = total / Double(pending.count)
                if mean > 0 {
                    entries[key(blockID: blockID, ruleID: rule.id)] = DegreeRuleProjection(planned: [], fill: mean)
                }
            }
        }
        for block in audit.blocks { derive(block.rules, blockID: block.id) }

        var openFill = 0.0
        var denominator = 0
        func tally(_ rules: [AuditRule], blockID: String) {
            for rule in rules {
                if rule.status == .open || rule.status == .inProgress { denominator += 1 }
                if rule.status == .open {
                    openFill += entries[key(blockID: blockID, ruleID: rule.id)]?.fill ?? 0
                }
                tally(rule.children, blockID: blockID)
            }
        }
        for block in audit.blocks { tally(block.rules, blockID: block.id) }
        let share = denominator > 0 ? min(1, max(0, openFill / Double(denominator))) : 0

        return DegreeProjection(rules: entries, placed: placed, unplaced: unplaced, openFill: openFill, ringShare: share, counted: counted)
    }
}

// What `make` needs from an audit and nothing from a plan: the codes Penn
// already counts, each requirement's remaining need, and which requirements
// list which course. It is split out because the contribution model asks for
// one projection per candidate course, and a requirement can list hundreds of
// options: normalizing every option's code for every candidate turned a list of
// suggestions into seconds of work on paper before it ever ran. With the layout
// built once, a projection costs the plan's length plus one walk of the rules.
struct DegreeProjectionLayout: Sendable {
    struct Requirement: Sendable {
        let key: String
        let label: String
        let usesCredits: Bool
        let remaining: Double
    }

    let taken: Set<String>
    let requirements: [Requirement]
    /// Normalized code -> indices into `requirements` that list it, Penn's order.
    let listing: [String: [Int]]

    init(audit: DegreeAudit) {
        var taken = Set<String>()
        for course in audit.courses { taken.insert(DegreePlanMath.normalizedCode(course.code)) }

        var requirements: [Requirement] = []
        var listing: [String: [Int]] = [:]
        func collect(_ rules: [AuditRule], blockID: String, blockTitle: String) {
            for rule in rules {
                if DegreeProjection.isRequirement(rule) {
                    let usesCredits: Bool
                    let remaining: Double
                    if let needCredits = rule.needCredits, needCredits > 0 {
                        let applied = rule.appliedCredits ?? rule.applied.reduce(0.0) { $0 + ($1.credits ?? 0) }
                        usesCredits = true
                        remaining = max(0, needCredits - applied)
                    } else if let needCourses = rule.needCourses, needCourses > 0 {
                        let applied = rule.appliedCount ?? rule.applied.count
                        usesCredits = false
                        remaining = Double(max(0, needCourses - applied))
                    } else {
                        usesCredits = false
                        remaining = 1
                    }
                    let index = requirements.count
                    requirements.append(Requirement(
                        key: DegreeProjection.key(blockID: blockID, ruleID: rule.id),
                        label: rule.label.isEmpty ? blockTitle : rule.label,
                        usesCredits: usesCredits,
                        remaining: remaining))
                    var listedHere = Set<String>()
                    for option in rule.advice {
                        let code = DegreePlanMath.normalizedCode(option.code)
                        if code.isEmpty || !listedHere.insert(code).inserted { continue }
                        listing[code, default: []].append(index)
                    }
                }
                collect(rule.children, blockID: blockID, blockTitle: blockTitle)
            }
        }
        for block in audit.blocks { collect(block.rules, blockID: block.id, blockTitle: block.title) }

        self.taken = taken
        self.requirements = requirements
        self.listing = listing
    }
}

// The last few layouts, so a screen that asks for a projection on every redraw
// (the ring, each requirement card, the semester table) builds an audit's
// layout once and not once per frame. Keyed by the audit's own value: a new
// read or a what-if is a different audit and gets its own entry. Eight is more
// than a dual-degree student with a what-if open can hold at once.
final class DegreeProjectionLayoutCache: @unchecked Sendable {
    static let shared = DegreeProjectionLayoutCache()

    private let lock = NSLock()
    private var entries: [(audit: DegreeAudit, layout: DegreeProjectionLayout)] = []

    func layout(for audit: DegreeAudit) -> DegreeProjectionLayout {
        lock.lock()
        defer { lock.unlock() }
        if let hit = entries.first(where: { $0.audit == audit }) { return hit.layout }
        let layout = DegreeProjectionLayout(audit: audit)
        entries.append((audit: audit, layout: layout))
        if entries.count > 8 { entries.removeFirst() }
        return layout
    }
}
