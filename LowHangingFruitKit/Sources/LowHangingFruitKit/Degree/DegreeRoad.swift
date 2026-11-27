import Foundation

// The road: the semester table read as one line of stops, from what is
// behind the student to the semester the plan finishes in. It is pure: the
// columns and the plan are parameters, nothing is read from Penn, and nothing
// here says a course counts toward anything. The screens draw it; the words
// they print come from the text functions below so one test can scan them.

/// What a semester on the road holds.
public enum DegreeRoadTermState: Sendable, Equatable { case now, registered, planned, empty }

public struct DegreeRoadStop: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Every finished semester folded into one stop.
        case done(termCodes: [String], classes: Int)
        case term(
            termCode: String, state: DegreeRoadTermState, classes: Int, credits: Double,
            overLimit: Bool, isFinish: Bool)
        /// The questions for the student's advisor.
        case advisor(open: Int, total: Int)
    }

    /// "done", "advisor", or the term code.
    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

public enum DegreeRoadNextStep: Sendable, Equatable {
    case planTheRest
    case askAdvisor
    case room(termCode: String, more: Int)
}

public enum DegreeRoadHeadline: Sendable, Equatable {
    case noPlan
    case finish(termCode: String, semestersToGo: Int, checked: Bool)
}

/// An earlier finish that only an advisor's yes would allow.
public struct DegreeRoadSooner: Sendable, Equatable {
    public let termCode: String
    public let answersNeeded: Int

    public init(termCode: String, answersNeeded: Int) {
        self.termCode = termCode
        self.answersNeeded = answersNeeded
    }
}

public struct DegreeRoad: Sendable, Equatable {
    public let headline: DegreeRoadHeadline
    public let sooner: DegreeRoadSooner?
    public let stops: [DegreeRoadStop]
    public let nextStep: DegreeRoadNextStep?
    public let nextStepStopID: String?

    /// What a semester usually holds, in credit units; "room for n more" is
    /// measured against it.
    public static let typicalLoad: Double = 5

    public init(
        headline: DegreeRoadHeadline, sooner: DegreeRoadSooner?, stops: [DegreeRoadStop],
        nextStep: DegreeRoadNextStep?, nextStepStopID: String?
    ) {
        self.headline = headline
        self.sooner = sooner
        self.stops = stops
        self.nextStep = nextStep
        self.nextStepStopID = nextStepStopID
    }

    /// Columns ascending by term code, as `DegreeTimeline.columns` returns them.
    public static func make(columns: [TimelineColumn], plan: DegreePlan) -> DegreeRoad {
        // Past semesters fold into one stop.
        let past = columns.filter { $0.kind == .past }
        let live = columns.filter { $0.kind != .past }

        struct Draft {
            let termCode: String
            let state: DegreeRoadTermState
            let classes: Int
            let credits: Double
            let overLimit: Bool
        }
        var drafts: [Draft] = []
        for column in live {
            let classes = column.taken.count + column.planned.count
            let credits = DegreeTimeline.credits(column)
            let state: DegreeRoadTermState
            var over = false
            switch column.kind {
            case .current:
                state = .now
            case .future:
                if !column.taken.isEmpty {
                    state = .registered
                } else if !column.planned.isEmpty {
                    state = .planned
                } else {
                    state = .empty
                }
                over = DegreeTimeline.isOverLimit(termCode: column.termCode, credits: credits)
            case .past:
                continue
            }
            drafts.append(Draft(
                termCode: column.termCode, state: state, classes: classes, credits: credits, overLimit: over))
        }

        // The finish: the engine's own word when it gave one, else the last
        // future semester the student planned something in. Registered
        // courses alone are not a plan: a student who has only registered for
        // next term has no finish yet, and "your plan ends spring 2027" would
        // read as a verdict nobody made.
        var finish: String?
        var checked = false
        if let term = plan.summary?.finishTerm, !term.isEmpty {
            finish = term
            checked = true
        } else if let last = live.last(where: { $0.kind == .future && !$0.planned.isEmpty }) {
            finish = last.termCode
        }

        // Empty semesters after the finish are noise.
        if let finish {
            drafts = drafts.filter { !($0.termCode > finish && $0.classes == 0) }
        }

        var stops: [DegreeRoadStop] = []
        if !past.isEmpty {
            stops.append(DegreeRoadStop(
                id: "done",
                kind: .done(termCodes: past.map { $0.termCode }, classes: past.reduce(0) { $0 + $1.taken.count })))
        }
        var termStops: [DegreeRoadStop] = []
        for draft in drafts {
            termStops.append(DegreeRoadStop(
                id: draft.termCode,
                kind: .term(
                    termCode: draft.termCode, state: draft.state, classes: draft.classes,
                    credits: draft.credits, overLimit: draft.overLimit,
                    isFinish: draft.termCode == finish)))
        }

        // The advisor's stop sits before the first semester the student's own
        // plan touches.
        var advisorStop: DegreeRoadStop?
        var advisorOpen = 0
        if let notes = plan.advisor, !notes.questions.isEmpty {
            advisorOpen = notes.questions.filter { notes.answers[$0.id] == nil }.count
            advisorStop = DegreeRoadStop(
                id: "advisor", kind: .advisor(open: advisorOpen, total: notes.questions.count))
        }
        var withAdvisor = termStops
        if let advisorStop {
            let at = termStops.firstIndex { stop in
                if case .term(_, let state, _, _, _, _) = stop.kind { return state == .planned }
                return false
            }
            if let at {
                withAdvisor.insert(advisorStop, at: at)
            } else {
                withAdvisor.append(advisorStop)
            }
        }
        stops.append(contentsOf: withAdvisor)

        // Headline.
        let headline: DegreeRoadHeadline
        if let finish {
            var toGo = 0
            for draft in drafts where draft.classes > 0 && draft.termCode <= finish { toGo += 1 }
            headline = .finish(termCode: finish, semestersToGo: toGo, checked: checked)
        } else {
            headline = .noPlan
        }

        // An earlier finish only an advisor's yes would allow.
        var sooner: DegreeRoadSooner?
        if let finish, let early = plan.summary?.bestCase?.finishTerm, !early.isEmpty, early < finish {
            let needed: Int
            if let notes = plan.advisor, !notes.questions.isEmpty {
                needed = notes.questions.filter { notes.answers[$0.id] != .yes }.count
            } else {
                needed = plan.summary?.bestCase?.approvals.count ?? 0
            }
            sooner = DegreeRoadSooner(termCode: early, answersNeeded: needed)
        }

        // One next step.
        var nextStep: DegreeRoadNextStep?
        var nextID: String?
        let hasPlannedTerm = drafts.contains { $0.state == .planned }
        if case .noPlan = headline {
            nextStep = .planTheRest
            nextID = stops.last?.id
        } else if !hasPlannedTerm {
            nextStep = .planTheRest
            nextID = stops.last?.id
        } else if advisorStop != nil, advisorOpen > 0 {
            nextStep = .askAdvisor
            nextID = "advisor"
        } else if let finish {
            for draft in drafts where draft.state != .now && draft.termCode <= finish {
                guard draft.termCode.hasSuffix("10") || draft.termCode.hasSuffix("30") else { continue }
                let more = Int((typicalLoad - draft.credits).rounded(.down))
                if more >= 1 {
                    nextStep = .room(termCode: draft.termCode, more: more)
                    nextID = draft.termCode
                    break
                }
            }
        }

        return DegreeRoad(
            headline: headline, sooner: sooner, stops: stops, nextStep: nextStep, nextStepStopID: nextID)
    }

    // MARK: Words

    /// "1 semester to go", "5 semesters to go"; "last semester" for none.
    public static func semestersText(_ count: Int) -> String {
        switch count {
        case ..<1: return "last semester"
        case 1: return "1 semester to go"
        default: return "\(count) semesters to go"
        }
    }

    /// "fall 2028 if 2 answers are yes".
    public static func soonerText(_ sooner: DegreeRoadSooner) -> String {
        let label = DegreePlanMath.termLabel(sooner.termCode)
        switch sooner.answersNeeded {
        case ..<1: return "\(label) with your advisor's yes"
        case 1: return "\(label) if 1 answer is yes"
        default: return "\(label) if \(sooner.answersNeeded) answers are yes"
        }
    }

    public static func stateWord(_ state: DegreeRoadTermState) -> String {
        switch state {
        case .now: return "now"
        case .registered: return "registered"
        case .planned: return "planned"
        case .empty: return "nothing planned"
        }
    }

    public static func nextStepText(_ step: DegreeRoadNextStep) -> String {
        switch step {
        case .planTheRest: return "plan the rest"
        case .askAdvisor: return "ask your advisor"
        case .room(_, let more): return "room for \(more) more"
        }
    }

    public static func classesText(_ count: Int) -> String {
        count == 1 ? "1 class" : "\(count) classes"
    }
}
