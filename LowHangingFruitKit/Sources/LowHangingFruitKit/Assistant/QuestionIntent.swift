import Foundation

/// A relative time range a student might ask about.
public enum DateWindow: Sendable, Hashable {
    case today
    case tomorrow
    case thisWeek
    case nextWeek
    case weekend
    case byWeekday(Int)     // Calendar weekday, 1 = Sunday
    case nextDays(Int)
    case thisMonth
    case anytime

    public func interval(now: Date, calendar: Calendar) -> DateInterval {
        let startOfToday = calendar.startOfDay(for: now)
        func days(_ n: Int, from date: Date = Date()) -> Date {
            calendar.date(byAdding: .day, value: n, to: date) ?? date
        }
        switch self {
        case .today:
            return DateInterval(start: now, end: days(1, from: startOfToday))
        case .tomorrow:
            let start = days(1, from: startOfToday)
            return DateInterval(start: start, end: days(1, from: start))
        case .thisWeek:
            return DateInterval(start: now, end: days(7, from: now))
        case .nextWeek:
            let week = calendar.dateInterval(of: .weekOfYear, for: days(7, from: now))
                ?? DateInterval(start: days(7, from: now), end: days(14, from: now))
            return week
        case .weekend:
            // Up to and including the coming Sunday night.
            let sunday = DateWindow.byWeekday(1).interval(now: now, calendar: calendar).end
            return DateInterval(start: now, end: sunday)
        case let .byWeekday(weekday):
            var components = DateComponents()
            components.weekday = weekday
            let next = calendar.nextDate(after: startOfToday, matching: components, matchingPolicy: .nextTime) ?? days(7, from: now)
            return DateInterval(start: now, end: days(1, from: calendar.startOfDay(for: next)))
        case let .nextDays(n):
            return DateInterval(start: now, end: days(n, from: now))
        case .thisMonth:
            let month = calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, end: days(30, from: now))
            return DateInterval(start: now, end: month.end)
        case .anytime:
            return DateInterval(start: now, end: days(365, from: now))
        }
    }

    public var label: String {
        switch self {
        case .today: return "today"
        case .tomorrow: return "tomorrow"
        case .thisWeek: return "in the next 7 days"
        case .nextWeek: return "next week"
        case .weekend: return "by Sunday"
        case let .byWeekday(day): return "by \(DateWindow.weekdayNames[day - 1])"
        case let .nextDays(n): return "in the next \(n) days"
        case .thisMonth: return "this month"
        case .anytime: return "coming up"
        }
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
}

/// The kind of work a question is about.
public enum WorkKindFilter: Sendable, Hashable {
    case any
    case assessment   // exams, midterms, finals, quizzes, tests
    case quiz
    case exam
    case assignment   // psets, homework, labs, essays, projects

    public var label: String {
        switch self {
        case .any: return "thing"
        case .assessment: return "exam or quiz"
        case .quiz: return "quiz"
        case .exam: return "exam"
        case .assignment: return "assignment"
        }
    }

    func matches(_ item: WorkItem) -> Bool {
        switch self {
        case .any: return true
        case .assessment: return item.isAssessment
        case .quiz:
            return item.kind == .quiz || item.title.range(of: #"(?i)\bquiz(zes)?\b"#, options: .regularExpression) != nil
        case .exam:
            return item.title.range(of: #"(?i)\b(midterms?|exams?|finals?|final exam|prelims?|test)\b"#, options: .regularExpression) != nil
        case .assignment: return !item.isAssessment
        }
    }
}

public enum QuestionIntent: Sendable, Hashable {
    case help
    case courseList
    case upcomingWork(window: DateWindow, kind: WorkKindFilter)
    case howMany(window: DateWindow, kind: WorkKindFilter)
    case nextItem(kind: WorkKindFilter)
    case itemDetail(query: String)
    case submissionStatus(query: String)
    case overdue
    case recentAnnouncements
    case lookup(query: String)
}

/// A parsed question: what is being asked, and about which course.
public struct ParsedQuestion: Sendable, Hashable {
    public let original: String
    public let intent: QuestionIntent
    public let course: CourseSummary?

    public init(original: String, intent: QuestionIntent, course: CourseSummary?) {
        self.original = original
        self.intent = intent
        self.course = course
    }
}

/// Rule-based question understanding. Deterministic on purpose: it runs on
/// every device with no model, and its output is exact where dates are involved.
public enum QuestionParser {
    public static func parse(_ question: String, courses: [CourseSummary]) -> ParsedQuestion {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = CourseMatcher.match(in: trimmed, courses: courses)
        var q = " " + trimmed.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "what's", with: "what is")
            .replacingOccurrences(of: "when's", with: "when is")
            .replacingOccurrences(of: "whats", with: "what is")
            .replacingOccurrences(of: "whens", with: "when is")
            .replacingOccurrences(of: "i've", with: "i have")
            .replacingOccurrences(of: "haven't", with: "have not")
            .replacingOccurrences(of: "?", with: "") + " "
        if let match {
            q = q.replacingOccurrences(of: match.mention, with: " ")
        }
        let intent = classify(q, original: trimmed, courseMention: match?.mention)
        return ParsedQuestion(original: trimmed, intent: intent, course: match?.course)
    }

    static func classify(_ q: String, original: String, courseMention: String?) -> QuestionIntent {
        func has(_ phrases: String...) -> Bool { phrases.contains { q.contains($0) } }
        func hasWord(_ pattern: String) -> Bool {
            q.range(of: #"\b(?:"# + pattern + #")\b"#, options: .regularExpression) != nil
        }

        let compact = q.trimmingCharacters(in: .whitespaces)
        if compact.isEmpty || hasWord("hi|hello|hey|help|yo") && compact.count < 24 || has("what can you do", "what can i ask") {
            return .help
        }

        if has("what classes", "what courses", "which classes", "which courses", "my classes", "my courses", "list my", "am i taking", "am i enrolled") {
            return .courseList
        }

        if hasWord("announcement|announcements|announced|announce") || has("latest news", "any news", "what did the professor say", "what did the prof say", "what did the instructor say", "recently posted") {
            return .recentAnnouncements
        }

        if hasWord("overdue|past due|missed|behind") && !has("policy") {
            return .overdue
        }

        let kind = workKind(in: q)
        let window = dateWindow(in: q)

        if has("how many", "how much do i have", "count") {
            return .howMany(window: window ?? .thisWeek, kind: kind)
        }

        // "Did I submit X" / "have I turned in X" / "what have I not submitted".
        // Deliberately narrow: "can I turn in psets late" is a policy question.
        let submissionPatterns = [
            #"\b(did|have|has|had)\s+i\s+(already\s+)?(submit|submitted|turn|turned|hand|handed)\b"#,
            #"\b(what|which|anything)\b.*\b(not|unsubmitted|yet)\b.*\b(submit|submitted|turned|handed)\b"#,
            #"\b(is|was)\b.*\bsubmitted\b"#,
            #"\bunsubmitted\b"#,
        ]
        if submissionPatterns.contains(where: { q.range(of: $0, options: .regularExpression) != nil }) {
            let query = stripLeadIn(q, patterns: [
                #"\b(did|have|has|was|is|had)\s+i\b"#, #"\bwhat\s+have\s+i\s+not\b"#, #"\bwhat\s+have\s+i\b"#,
                #"\bwhat\b"#, #"\bhave\s+not\b"#, #"\bnot\b"#, #"\bsubmitted\b"#, #"\bsubmit\b"#,
                #"\bturned\s+in\b"#, #"\bturn\s+in\b"#, #"\bhanded\s+in\b"#, #"\bhand\s+in\b"#,
                #"\byet\b"#, #"\balready\b"#, #"\bfor\b"#, #"\bthe\b"#, #"\bmy\b"#, #"\bunsubmitted\b"#,
            ])
            return .submissionStatus(query: query)
        }

        // "When is the next exam" / "next quiz" / "when is my midterm".
        let asksWhen = hasWord("when|what day|what date|what time|deadline|due date")
        if hasWord("next|upcoming") && kind != .any && window == nil {
            return .nextItem(kind: kind)
        }
        if asksWhen && kind != .any && !hasWord("due") && specificItemQuery(q, courseMention: courseMention).isEmpty {
            return .nextItem(kind: kind)
        }

        // "When is pset 5 due" / "deadline for lab 3".
        if asksWhen || hasWord("due") && !hasWord("what|which|anything|something|everything|all|list|show") {
            let query = specificItemQuery(q, courseMention: courseMention)
            if !query.isEmpty {
                return .itemDetail(query: query)
            }
            if kind != .any { return .nextItem(kind: kind) }
        }

        // "What's due this week" / "what do I have" / "anything due tomorrow".
        if hasWord("due|upcoming|coming up|to do|todo|left|remaining|on my plate|have to do|need to do|assignments|homework|work")
            || has("what do i have", "what is on", "what is coming", "anything", "what is left", "what is next")
            || window != nil {
            return .upcomingWork(window: window ?? .thisWeek, kind: kind)
        }

        return .lookup(query: original)
    }

    static func workKind(in q: String) -> WorkKindFilter {
        func hasWord(_ pattern: String) -> Bool {
            q.range(of: #"\b(?:"# + pattern + #")\b"#, options: .regularExpression) != nil
        }
        if hasWord("quiz|quizzes") { return .quiz }
        if hasWord("exam|exams|midterm|midterms|final|finals|test|tests|prelim") { return .exam }
        if hasWord("assessment|assessments") { return .assessment }
        if hasWord("pset|psets|problem set|homework|hw|lab|labs|essay|paper|project|reading|assignment|assignments") { return .assignment }
        return .any
    }

    static func dateWindow(in q: String) -> DateWindow? {
        func hasWord(_ pattern: String) -> Bool {
            q.range(of: #"\b(?:"# + pattern + #")\b"#, options: .regularExpression) != nil
        }
        if hasWord("today|tonight") { return .today }
        if hasWord("tomorrow") { return .tomorrow }
        if hasWord("next week") { return .nextWeek }
        if hasWord("this weekend|the weekend|weekend") { return .weekend }
        if hasWord("this week|the week|week") { return .thisWeek }
        if hasWord("this month|the month") { return .thisMonth }
        if let regex = try? NSRegularExpression(pattern: #"\b(?:next|in the next|within|in)\s+(\d{1,2})\s+days?\b"#),
           let m = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
           let range = Range(m.range(at: 1), in: q), let n = Int(q[range]) {
            return .nextDays(n)
        }
        if hasWord("next few days|next couple of days|couple days|few days") { return .nextDays(3) }
        for (index, name) in DateWindow.weekdayNames.enumerated() {
            let day = name.lowercased()
            if q.range(of: #"\b(by|before|until|till|on|this|through|thru)\s+(?:the\s+)?\#(day)\b"#, options: .regularExpression) != nil
                || q.range(of: #"\b\#(day)\b"#, options: .regularExpression) != nil {
                return .byWeekday(index + 1)
            }
        }
        if hasWord("everything|all|anytime|ever|semester|term") { return .anytime }
        return nil
    }

    /// Pulls the item being asked about out of "when is pset 5 due for cis".
    static func specificItemQuery(_ q: String, courseMention: String?) -> String {
        var s = stripLeadIn(q, patterns: [
            #"\b(when|what day|what date|what time)\s+(is|are|does|do|was|will)\b"#,
            #"\b(what is|what are)\s+the\s+(deadline|due date)\s+(for|of)\b"#,
            #"\b(deadline|due date)\s+(for|of)\b"#,
            #"\bis\s+due\b"#, #"\bdue\b"#, #"\bthe\b"#, #"\bmy\b"#, #"\bour\b"#, #"\bfor\b"#, #"\bin\b"#, #"\bclass\b"#, #"\bcourse\b"#,
            #"\b(when|is|are|does|do)\b"#,
        ])
        if let courseMention { s = s.replacingOccurrences(of: courseMention, with: " ") }
        let tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Generic words alone don't identify an item ("when is the exam").
        let generic: Set<String> = ["next", "exam", "exams", "midterm", "final", "finals", "quiz", "test", "assignment", "homework", "it", "this", "that", "thing", "things", "everything", "anything", "stuff", "date", "again"]
        let meaningful = tokens.filter { !generic.contains($0) }
        guard !meaningful.isEmpty else { return "" }
        return tokens.joined(separator: " ")
    }

    static func stripLeadIn(_ text: String, patterns: [String]) -> String {
        var s = text
        for pattern in patterns {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
