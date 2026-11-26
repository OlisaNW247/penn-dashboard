import Foundation

// The wire types of the degree advisor's server-side planning engine: the
// structured data the phone sends (the audits as they are, the term history
// and the current term) and the full schedule the engine answers with.
//
// The request half is plain Codable. The response half is decoded leniently
// on purpose: the engine is a separate deployment from the app, so a missing
// key or a malformed element must cost that key or element and never the
// answer text around it (the same rule `DegreeAdvisorResponse` follows for
// actions). The wrong fix is a strict decode: an engine that adds a field
// the phone does not know would then break every chat on every older build.

/// One audit as the engine reads it.
public struct DegreeAdvisorStructuredAudit: Codable, Sendable, Equatable {
    public let degreeId: String
    public let label: String
    public let audit: DegreeAudit

    public init(degreeId: String, label: String, audit: DegreeAudit) {
        self.degreeId = degreeId
        self.label = label
        self.audit = audit
    }
}

/// The audits, the history and the current term, for the engine.
public struct DegreeAdvisorStructured: Codable, Sendable, Equatable {
    public let audits: [DegreeAdvisorStructuredAudit]
    /// Term code -> course codes, the snapshot's history.
    public let history: [String: [String]]
    /// `YYYYTT` of the term containing now.
    public let currentTerm: String

    public init(audits: [DegreeAdvisorStructuredAudit], history: [String: [String]], currentTerm: String) {
        self.audits = audits
        self.history = history
        self.currentTerm = currentTerm
    }

    /// Built from the labelled audits a brief is made from.
    public init(audits: [DegreeLabeledAudit], history: [String: [String]], currentTerm: String) {
        self.init(
            audits: audits.map {
                DegreeAdvisorStructuredAudit(degreeId: $0.degreeID, label: $0.label, audit: $0.audit)
            },
            history: history, currentTerm: currentTerm)
    }
}

/// Decodes one element without ever throwing, so a bad element in a list is
/// dropped and the rest of the list survives. An unkeyed container only
/// advances past an element that decoded, so decoding the raw element with
/// `try?` in a loop would spin on the first bad one; this wrapper always
/// succeeds.
private struct EngineLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private func lossyList<Value: Decodable, Key: CodingKey>(
    _ type: Value.Type, in container: KeyedDecodingContainer<Key>, forKey key: Key
) -> [Value] {
    let wrapped: [EngineLossy<Value>]? = try? container.decodeIfPresent([EngineLossy<Value>].self, forKey: key)
    return (wrapped ?? []).compactMap { $0.value }
}

private func lenient<Value: Decodable, Key: CodingKey>(
    _ type: Value.Type, in container: KeyedDecodingContainer<Key>, forKey key: Key
) -> Value? {
    let value: Value? = (try? container.decodeIfPresent(Value.self, forKey: key)) ?? nil
    return value
}

public struct DegreeEngineScenario: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let maxLoad: Double
    public let summer: Bool
    public let finishTerm: String?
    public let meetsTarget: Bool

    public init(id: String, label: String, maxLoad: Double, summer: Bool, finishTerm: String?, meetsTarget: Bool) {
        self.id = id
        self.label = label
        self.maxLoad = maxLoad
        self.summer = summer
        self.finishTerm = finishTerm
        self.meetsTarget = meetsTarget
    }

    private enum CodingKeys: String, CodingKey { case id, label, maxLoad, summer, finishTerm, meetsTarget }

    /// Only the id is required; the rest read as a plain scenario.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.label = lenient(String.self, in: c, forKey: .label) ?? ""
        self.maxLoad = lenient(Double.self, in: c, forKey: .maxLoad) ?? 0
        self.summer = lenient(Bool.self, in: c, forKey: .summer) ?? false
        self.finishTerm = lenient(String.self, in: c, forKey: .finishTerm)
        self.meetsTarget = lenient(Bool.self, in: c, forKey: .meetsTarget) ?? false
    }
}

public struct DegreeEngineCourse: Codable, Sendable, Equatable {
    public let code: String
    public let title: String
    public let credits: Double
    public let countsToward: [String]
    /// "automatic", "petition" or "check".
    public let approval: String
    public let note: String?
    /// `"<degreeId>|<blockId>|<ruleId>"` for each audit rule the engine filled
    /// with this course, in the order of `countsToward`. Empty from an older
    /// server. Parsed by `DegreeProjection.resolveSlotID`.
    public let slotIds: [String]

    public init(
        code: String, title: String, credits: Double, countsToward: [String] = [],
        approval: String = "automatic", note: String? = nil, slotIds: [String] = []
    ) {
        self.slotIds = slotIds
        self.code = code
        self.title = title
        self.credits = credits
        self.countsToward = countsToward
        self.approval = approval
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case code, title, credits, countsToward, approval, note, slotIds }

    /// Only the code is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(String.self, forKey: .code)
        self.title = lenient(String.self, in: c, forKey: .title) ?? ""
        let given = lenient(Double.self, in: c, forKey: .credits) ?? 1
        self.credits = given.isFinite && given > 0 ? given : 1
        self.countsToward = lossyList(String.self, in: c, forKey: .countsToward)
        self.approval = lenient(String.self, in: c, forKey: .approval) ?? "automatic"
        self.note = lenient(String.self, in: c, forKey: .note)
        self.slotIds = lossyList(String.self, in: c, forKey: .slotIds)
    }
}

public struct DegreeEngineTerm: Codable, Sendable, Equatable {
    public let term: String
    public let credits: Double
    public let courses: [DegreeEngineCourse]
    /// Credits the student is already registered for in this term, when the
    /// server says (absent from an older one).
    public let registeredCredits: Double?

    public init(term: String, credits: Double, courses: [DegreeEngineCourse], registeredCredits: Double? = nil) {
        self.term = term
        self.credits = credits
        self.courses = courses
        self.registeredCredits = registeredCredits
    }

    private enum CodingKeys: String, CodingKey { case term, credits, courses, registeredCredits }

    /// Only the term is required; the credits default to the courses' sum.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.term = try c.decode(String.self, forKey: .term)
        let list = lossyList(DegreeEngineCourse.self, in: c, forKey: .courses)
        self.courses = list
        self.credits = lenient(Double.self, in: c, forKey: .credits) ?? list.reduce(0) { $0 + $1.credits }
        let registered = lenient(Double.self, in: c, forKey: .registeredCredits)
        self.registeredCredits = registered.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

public struct DegreeEngineUnfilled: Codable, Sendable, Equatable {
    public let degreeLabel: String
    public let label: String
    public let reason: String

    public init(degreeLabel: String, label: String, reason: String) {
        self.degreeLabel = degreeLabel
        self.label = label
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case degreeLabel, label, reason }

    /// The label is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.label = try c.decode(String.self, forKey: .label)
        self.degreeLabel = lenient(String.self, in: c, forKey: .degreeLabel) ?? ""
        self.reason = lenient(String.self, in: c, forKey: .reason) ?? ""
    }
}

public struct DegreeEnginePetition: Codable, Sendable, Equatable {
    public let code: String
    public let slots: [String]
    public let savesCredits: Double

    public init(code: String, slots: [String], savesCredits: Double) {
        self.code = code
        self.slots = slots
        self.savesCredits = savesCredits
    }

    private enum CodingKeys: String, CodingKey { case code, slots, savesCredits }

    /// The code is required.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(String.self, forKey: .code)
        self.slots = lossyList(String.self, in: c, forKey: .slots)
        self.savesCredits = lenient(Double.self, in: c, forKey: .savesCredits) ?? 0
    }
}

/// The engine's whole answer to a planning question.
public struct DegreeEnginePlan: Codable, Sendable, Equatable {
    public let remainingCredits: Double
    public let remainingCreditsWithoutOverlap: Double
    public let scenarios: [DegreeEngineScenario]
    public let chosen: String
    public let schedule: [DegreeEngineTerm]
    public let unfilled: [DegreeEngineUnfilled]
    public let petitions: [DegreeEnginePetition]
    public let notes: [String]

    public init(
        remainingCredits: Double, remainingCreditsWithoutOverlap: Double,
        scenarios: [DegreeEngineScenario], chosen: String, schedule: [DegreeEngineTerm],
        unfilled: [DegreeEngineUnfilled] = [], petitions: [DegreeEnginePetition] = [],
        notes: [String] = []
    ) {
        self.remainingCredits = remainingCredits
        self.remainingCreditsWithoutOverlap = remainingCreditsWithoutOverlap
        self.scenarios = scenarios
        self.chosen = chosen
        self.schedule = schedule
        self.unfilled = unfilled
        self.petitions = petitions
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case remainingCredits, remainingCreditsWithoutOverlap, scenarios, chosen, schedule
        case unfilled, petitions, notes
    }

    /// The schedule list is required (a plan with no schedule key must not
    /// read as "an empty schedule", which would wipe the student's future
    /// semesters); everything else is lenient.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawSchedule = try c.decode([EngineLossy<DegreeEngineTerm>].self, forKey: .schedule)
        self.schedule = rawSchedule.compactMap { $0.value }
        self.remainingCredits = lenient(Double.self, in: c, forKey: .remainingCredits) ?? 0
        self.remainingCreditsWithoutOverlap =
            lenient(Double.self, in: c, forKey: .remainingCreditsWithoutOverlap) ?? 0
        self.scenarios = lossyList(DegreeEngineScenario.self, in: c, forKey: .scenarios)
        self.chosen = lenient(String.self, in: c, forKey: .chosen) ?? ""
        self.unfilled = lossyList(DegreeEngineUnfilled.self, in: c, forKey: .unfilled)
        self.petitions = lossyList(DegreeEnginePetition.self, in: c, forKey: .petitions)
        self.notes = lossyList(String.self, in: c, forKey: .notes)
    }
}

/// Lenient decode of the optional `plan` key: a malformed plan is nil.
struct DegreeEnginePlanBox: Decodable {
    let plan: DegreeEnginePlan?
    init(from decoder: Decoder) throws {
        plan = try? DegreeEnginePlan(from: decoder)
    }
}

extension DegreeEnginePlan {
    /// The scenario `chosen` names, if the list has it.
    public var chosenScenario: DegreeEngineScenario? {
        scenarios.first { $0.id == chosen }
    }
}

extension DegreeAdvisor {
    /// Replaces every planned semester after `currentTerm` with the engine's
    /// schedule, summers included; semesters at or before `currentTerm` (and any
    /// term code that does not parse) are untouched.
    ///
    /// The engine plans the whole remaining degree, so its schedule is the
    /// future, not a set of edits to it: merging would leave the student's
    /// earlier sketch beside the engine's and double-count both. The one undo
    /// the chat offers puts the whole earlier plan back, so replacing is safe.
    /// Courses are filed under their normalised code; a code already in a kept
    /// term, repeated in the schedule, past the per-term cap, or in a term that
    /// is not after the current one is skipped and counted. Terms the schedule
    /// leaves empty are dropped, the result is ascending by code, and the
    /// semesters that fit under `DegreePlanMath.maxTerms` are kept (the latest
    /// ones fall off first). A schedule with no courses leaves the plan as it is.
    public static func applyEnginePlan(
        _ plan: DegreeEnginePlan, to existing: DegreePlan, currentTerm: String, now: Date = Date()
    ) -> DegreeAdvisorOutcome {
        let total = plan.schedule.reduce(0) { $0 + $1.courses.count }
        // A schedule with no course in it changes nothing: replacing the
        // student's sketch with nothing on the strength of an empty answer
        // would delete their work for no reason the answer gave.
        guard total > 0 else { return DegreeAdvisorOutcome(plan: existing, applied: [], skipped: 0) }
        guard let current = Term(code: currentTerm) else {
            return DegreeAdvisorOutcome(plan: existing, applied: [], skipped: total)
        }
        var kept: [PlannedTerm] = []
        for term in existing.terms {
            if let parsed = Term(code: term.termCode), parsed > current { continue }
            kept.append(term)
        }
        var taken = Set<String>()
        for term in kept {
            for course in term.courses { taken.insert(DegreePlanMath.normalizedCode(course.code)) }
        }

        var order: [String] = []
        var byTerm: [String: [PlannedCourse]] = [:]
        var skipped = 0
        for entry in plan.schedule {
            guard let parsed = Term(code: entry.term), parsed > current else {
                skipped += entry.courses.count
                continue
            }
            for course in entry.courses {
                let code = DegreePlanMath.normalizedCode(course.code)
                var list = byTerm[parsed.code] ?? []
                guard !code.isEmpty, !taken.contains(code),
                      list.count < DegreePlanMath.maxCoursesPerTerm
                else {
                    skipped += 1
                    continue
                }
                taken.insert(code)
                let title = course.title.trimmingCharacters(in: .whitespacesAndNewlines)
                list.append(PlannedCourse(
                    code: code, title: title.isEmpty ? nil : String(title.prefix(120)),
                    credits: course.credits,
                    countsToward: course.countsToward.isEmpty ? nil : course.countsToward,
                    approval: course.approval,
                    slotIds: course.slotIds.isEmpty ? nil : course.slotIds))
                if byTerm[parsed.code] == nil { order.append(parsed.code) }
                byTerm[parsed.code] = list
            }
        }

        var codes = order.filter { !(byTerm[$0] ?? []).isEmpty }.sorted()
        let room = max(0, DegreePlanMath.maxTerms - kept.count)
        if codes.count > room {
            for dropped in codes[room...] { skipped += (byTerm[dropped] ?? []).count }
            codes = Array(codes.prefix(room))
        }

        var terms = kept
        var applied: [DegreeAdvisorChange] = []
        for code in codes {
            let courses = byTerm[code] ?? []
            terms.append(PlannedTerm(termCode: code, courses: courses))
            for course in courses {
                applied.append(DegreeAdvisorChange(
                    op: .add, code: course.code, termLabel: DegreePlanMath.termLabel(code), toTermLabel: nil))
            }
        }
        terms.sort { $0.termCode < $1.termCode }
        return DegreeAdvisorOutcome(
            plan: DegreePlan(terms: terms, summary: summary(of: plan, now: now)), applied: applied, skipped: skipped)
    }

    /// The summary line's facts, from the scenario the engine chose; nil when
    /// the answer names none (an older server), so such a plan reads as before.
    /// An approval is needed by the "approved" and "best" scenarios, and by the
    /// student's own load when it is above the normal 5.5 cu.
    static func summary(of plan: DegreeEnginePlan, now: Date) -> DegreePlanSummary? {
        guard let scenario = plan.chosenScenario else { return nil }
        let needsApproval = scenario.id == "approved" || scenario.id == "best"
            || (scenario.id == "student" && scenario.maxLoad > 5.5)
        let finish = scenario.finishTerm.flatMap { $0.isEmpty ? nil : $0 }
        return DegreePlanSummary(
            finishTerm: finish, scenarioID: scenario.id, scenarioLabel: scenario.label,
            remainingCredits: plan.remainingCredits.isFinite ? plan.remainingCredits : nil,
            needsApproval: needsApproval, createdAt: now)
    }
}

extension DegreeAdvisor {
    /// What `degreeAdvisorAudits` appends to the label of a what-if audit. It
    /// stays in what the chat and the server see and comes off for display.
    public static let whatIfLabelSuffix = " (what if, not declared)"

    /// A label as the table shows it: without the what-if suffix.
    public static func displayLabel(_ label: String) -> String {
        label.replacingOccurrences(of: whatIfLabelSuffix, with: "")
    }
}
