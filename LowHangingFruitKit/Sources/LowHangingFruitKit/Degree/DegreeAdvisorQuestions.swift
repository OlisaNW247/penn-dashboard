import Foundation

// Questions for the student's own human advisor. Some of what the planning
// engine schedules depends on things only an advisor can grant (one course
// counted for two requirements, a placement exam, a heavier load). The server
// lists those as questions beside its plan; the student takes them to the
// advisor and types the answers back here, and the next plan request carries
// them so the engine can plan with the answer in hand.
//
// The questions and answers are the student's own notes: they live in the plan
// file (`DegreePlan.advisor`), survive every hand edit of the table, and are
// deleted with the plan. They go to the server only inside a plan request,
// as ids with "yes" or "no", for that request alone. All of it is pure.

/// What the advisor said. Raw strings are the wire's words.
public enum DegreeAdvisorAnswer: String, Codable, Sendable, Equatable {
    case yes
    case no
}

/// One question for the advisor. `kind` is "doubleCount", "placement" or
/// "load" today; any other string reads as a plain question.
public struct DegreeAdvisorQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String
    public let question: String
    public let detail: String?

    public init(id: String, kind: String, question: String, detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.question = question
        self.detail = detail
    }
}

/// A question as the server sends it, with the answer it echoes back (the one
/// the phone sent with the request, or nil).
public struct DegreeAdvisorQuestionWire: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let question: String
    public let detail: String?
    public let answer: DegreeAdvisorAnswer?

    public init(
        id: String, kind: String, question: String, detail: String? = nil,
        answer: DegreeAdvisorAnswer? = nil
    ) {
        self.id = id
        self.kind = kind
        self.question = question
        self.detail = detail
        self.answer = answer
    }

    private enum CodingKeys: String, CodingKey { case id, kind, question, detail, answer }

    /// The id and the question are required; everything else is lenient, so a
    /// field the server changes costs the field and never the question. Any
    /// answer other than "yes" or "no" reads as none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.question = try c.decode(String.self, forKey: .question)
        let kindValue: String? = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        self.kind = kindValue ?? ""
        let detailValue: String? = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? nil
        self.detail = detailValue
        let raw: String? = (try? c.decodeIfPresent(String.self, forKey: .answer)) ?? nil
        self.answer = raw.flatMap { DegreeAdvisorAnswer(rawValue: $0) }
    }

    public var asQuestion: DegreeAdvisorQuestion {
        DegreeAdvisorQuestion(id: id, kind: kind, question: question, detail: detail)
    }
}

/// One answer as a plan request carries it.
public struct DegreeAdvisorAnswerEntry: Codable, Sendable, Equatable {
    public let id: String
    public let answer: DegreeAdvisorAnswer

    public init(id: String, answer: DegreeAdvisorAnswer) {
        self.id = id
        self.answer = answer
    }
}

public struct DegreeAdvisorNotes: Codable, Sendable, Equatable {
    /// The most answers a request carries, and the most the phone keeps.
    public static let maxAnswers = 40
    /// The most questions the phone keeps from one plan.
    public static let maxQuestions = 12

    public var questions: [DegreeAdvisorQuestion]
    /// By question id.
    public var answers: [String: DegreeAdvisorAnswer]
    /// What had been answered when the plan now in the table was made. The
    /// "update plan" button shows while this differs from `answers`.
    public var answersAtLastPlan: [String: DegreeAdvisorAnswer]

    public init(
        questions: [DegreeAdvisorQuestion] = [],
        answers: [String: DegreeAdvisorAnswer] = [:],
        answersAtLastPlan: [String: DegreeAdvisorAnswer] = [:]
    ) {
        self.questions = questions
        self.answers = answers
        self.answersAtLastPlan = answersAtLastPlan
    }

    private enum CodingKeys: String, CodingKey { case questions, answers, answersAtLastPlan }

    /// Lenient: a stored value with a key missing reads as empty there.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let q: [DegreeAdvisorQuestion]? = (try? c.decodeIfPresent([DegreeAdvisorQuestion].self, forKey: .questions)) ?? nil
        let a: [String: DegreeAdvisorAnswer]? = (try? c.decodeIfPresent([String: DegreeAdvisorAnswer].self, forKey: .answers)) ?? nil
        let l: [String: DegreeAdvisorAnswer]? = (try? c.decodeIfPresent([String: DegreeAdvisorAnswer].self, forKey: .answersAtLastPlan)) ?? nil
        self.questions = q ?? []
        self.answers = a ?? [:]
        self.answersAtLastPlan = l ?? [:]
    }

    // MARK: Answering

    /// Records an answer, or clears it with nil. Past `maxAnswers` the answer
    /// whose question comes earliest in the list goes first (an id no question
    /// names goes before any that one does), never the one just set.
    public func setting(_ answer: DegreeAdvisorAnswer?, for id: String) -> DegreeAdvisorNotes {
        var out = self
        if let answer {
            out.answers[id] = answer
        } else {
            out.answers.removeValue(forKey: id)
        }
        out.bound(keeping: id)
        return out
    }

    private mutating func bound(keeping id: String) {
        guard answers.count > Self.maxAnswers else { return }
        var position: [String: Int] = [:]
        for (index, question) in questions.enumerated() where position[question.id] == nil {
            position[question.id] = index
        }
        let dropOrder = answers.keys.filter { $0 != id }.sorted { lhs, rhs in
            let l = position[lhs] ?? -1
            let r = position[rhs] ?? -1
            return l != r ? l < r : lhs < rhs
        }
        var excess = answers.count - Self.maxAnswers
        for key in dropOrder where excess > 0 {
            answers.removeValue(forKey: key)
            excess -= 1
        }
    }

    /// Folds in a plan's questions. The server's list replaces the questions
    /// (each id once, at most `maxQuestions`); the phone's own answers win over
    /// the echo, and an echoed answer for an id the phone has none for is
    /// adopted. Answers for ids the list no longer names are kept: a question
    /// can drop out of an answer because its answer settled it, and forgetting
    /// the answer would put the plan back. The plan now in the table was made
    /// with these answers.
    public func receiving(_ wire: [DegreeAdvisorQuestionWire]) -> DegreeAdvisorNotes {
        var out = self
        var seen = Set<String>()
        var list: [DegreeAdvisorQuestion] = []
        for item in wire where !seen.contains(item.id) {
            seen.insert(item.id)
            list.append(item.asQuestion)
            if list.count == Self.maxQuestions { break }
        }
        out.questions = list
        for item in wire {
            if let echoed = item.answer, out.answers[item.id] == nil {
                out.answers[item.id] = echoed
            }
        }
        out.bound(keeping: "")
        out.answersAtLastPlan = out.answers
        return out
    }

    // MARK: Reading

    /// Whether an answer was added, changed or cleared since the last plan.
    public var hasChanges: Bool { answers != answersAtLastPlan }

    /// Questions with no answer.
    public var openCount: Int {
        questions.filter { answers[$0.id] == nil }.count
    }

    /// The answers a plan request carries: by id, so the same answers are the
    /// same bytes, and at most `maxAnswers`.
    public var requestAnswers: [DegreeAdvisorAnswerEntry] {
        answers.keys.sorted().prefix(Self.maxAnswers).compactMap { id in
            answers[id].map { DegreeAdvisorAnswerEntry(id: id, answer: $0) }
        }
    }

    /// The unanswered questions as a numbered list to paste into an email:
    /// one per line, nothing else.
    public var copyText: String {
        questions
            .filter { answers[$0.id] == nil }
            .enumerated()
            .map { "\($0.offset + 1). \($0.element.question)" }
            .joined(separator: "\n")
    }
}
