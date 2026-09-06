import Foundation

/// The assistant's reply, ready for the UI or for the on-device model to polish.
public struct AssistantAnswer: Sendable, Hashable {
    public let text: String
    public let sources: [SourceReference]
    public let question: ParsedQuestion
    /// Passages the answer was drawn from, when retrieval was involved. These
    /// are what the on-device model is allowed to rephrase from.
    public let grounding: [SearchHit]
    /// True when the deterministic text is exact (dates, counts, lists) and
    /// should not be rephrased by a model.
    public let isExact: Bool

    public init(text: String, sources: [SourceReference], question: ParsedQuestion, grounding: [SearchHit] = [], isExact: Bool) {
        self.text = text
        self.sources = sources
        self.question = question
        self.grounding = grounding
        self.isExact = isExact
    }
}

/// Answers class questions from the student's own data with no model at all:
/// structured questions (what's due, when is X, did I submit) are computed
/// from assignments; policy and content questions are answered by retrieval
/// over the course knowledge base. Works on every device the app supports.
public struct ClassQuestionAnswerer: Sendable {
    public let context: AskKnowledgeContext
    public static let maxListItems = 8

    public init(context: AskKnowledgeContext) {
        self.context = context
    }

    public func answer(_ question: String) -> AssistantAnswer {
        let parsed = QuestionParser.parse(question, courses: context.courses)
        switch parsed.intent {
        case .help:
            return help(parsed)
        case .courseList:
            return courseList(parsed)
        case let .upcomingWork(window, kind):
            return upcomingWork(parsed, window: window, kind: kind, countOnly: false)
        case let .howMany(window, kind):
            return upcomingWork(parsed, window: window, kind: kind, countOnly: true)
        case let .nextItem(kind):
            return nextItem(parsed, kind: kind)
        case let .itemDetail(query):
            return itemDetail(parsed, query: query)
        case let .submissionStatus(query):
            return submissionStatus(parsed, query: query)
        case .overdue:
            return overdue(parsed)
        case .recentAnnouncements:
            return recentAnnouncements(parsed)
        case let .lookup(query):
            return lookup(parsed, query: query)
        }
    }

    /// Starter chips for the Ask screen.
    public static func suggestedQuestions(for context: AskKnowledgeContext) -> [String] {
        var questions = ["What's due this week?", "When is my next exam?", "Anything overdue?"]
        if let course = context.courses.first {
            questions.append("What's the late policy in \(course.code)?")
        }
        if !context.knowledge.documents(ofKind: .announcement).isEmpty {
            questions.append("Latest announcements")
        }
        return questions
    }

    // MARK: - Structured answers

    private func help(_ parsed: ParsedQuestion) -> AssistantAnswer {
        let name = context.userName.isEmpty ? "" : ", \(context.userName)"
        let lines = [
            "Hi\(name). Ask me anything about your classes. For example:",
            "1. What's due this week?",
            "2. When is my next midterm?",
            "3. Did I submit the lab?",
            "4. What's the late policy in \(context.courses.first?.code ?? "a course")?",
            "5. Latest announcements",
        ]
        return AssistantAnswer(text: lines.joined(separator: "\n"), sources: [], question: parsed, isExact: true)
    }

    private func courseList(_ parsed: ParsedQuestion) -> AssistantAnswer {
        let courses = context.courses
        guard !courses.isEmpty else {
            return AssistantAnswer(text: "I don't see any courses yet. Connect Canvas and sync, then ask again.", sources: [], question: parsed, isExact: true)
        }
        var lines = ["You're in \(courses.count) course\(courses.count == 1 ? "" : "s"):"]
        for (index, course) in courses.enumerated() {
            let name = course.name == course.code ? "" : " · \(course.name)"
            lines.append("\(index + 1). \(course.code)\(name)")
        }
        let refs = courses.compactMap { course -> SourceReference? in
            guard let url = course.url else { return nil }
            return SourceReference(title: course.name, course: course.code, kind: "course", url: url)
        }
        return AssistantAnswer(text: lines.joined(separator: "\n"), sources: refs, question: parsed, isExact: true)
    }

    private func upcomingWork(_ parsed: ParsedQuestion, window: DateWindow, kind: WorkKindFilter, countOnly: Bool) -> AssistantAnswer {
        let interval = window.interval(now: context.now, calendar: context.calendar)
        let matches = openItems(course: parsed.course)
            .filter { kind.matches($0) }
            .filter { item in
                guard let due = item.dueAt else { return false }
                return interval.contains(due)
            }
            .sorted(by: byDue)

        let scope = parsed.course.map { " for \($0.code)" } ?? ""
        let what = kind == .any ? "thing" : kind.label
        if matches.isEmpty {
            let overdueCount = overdueItems(course: parsed.course).count
            let nothing = kind == .any ? "due" : what + "-related due"
            var text = "Nothing \(nothing) \(window.label)\(scope)."
            if overdueCount > 0 {
                text += " You do have \(overdueCount) overdue item\(overdueCount == 1 ? "" : "s"). Ask \"anything overdue?\" to see \(overdueCount == 1 ? "it" : "them")."
            }
            return AssistantAnswer(text: text, sources: [], question: parsed, isExact: true)
        }

        var lines = ["\(matches.count) \(what)\(matches.count == 1 ? "" : "s") due \(window.label)\(scope):"]
        if !countOnly || matches.count <= Self.maxListItems {
            lines.append(contentsOf: numbered(matches))
        }
        let next = matches[0]
        if let due = next.dueAt {
            lines.append("Next up: \(next.title) (\(next.course)), \(relative(due)).")
        }
        return AssistantAnswer(text: lines.joined(separator: "\n"), sources: sources(for: Array(matches.prefix(3))), question: parsed, isExact: true)
    }

    private func nextItem(_ parsed: ParsedQuestion, kind: WorkKindFilter) -> AssistantAnswer {
        let upcoming = openItems(course: parsed.course, includeCompleted: true)
            .filter { kind.matches($0) }
            .filter { ($0.dueAt ?? .distantPast) >= context.now }
            .sorted(by: byDue)

        if let next = upcoming.first, let due = next.dueAt {
            var text = "Your next \(kind.label) is \(next.title) for \(next.course): \(DateText.long(due, calendar: context.calendar)) (\(relative(due)))."
            if upcoming.count > 1, let after = upcoming[1].dueAt {
                text += "\nAfter that: \(upcoming[1].title) (\(upcoming[1].course)), \(DateText.short(after, calendar: context.calendar))."
            }
            return AssistantAnswer(text: text, sources: sources(for: Array(upcoming.prefix(2))), question: parsed, isExact: true)
        }

        // Canvas may know about an exam the calendar feed doesn't carry yet.
        let docs = assignmentDocuments(course: parsed.course)
            .filter { doc in
                let asItem = WorkItem(id: doc.id, course: doc.course, title: doc.title, kind: .assignment, dueAt: doc.dueAt, url: doc.url, isCompleted: false)
                return kind.matches(asItem) && (doc.dueAt ?? .distantPast) >= context.now
            }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        if let doc = docs.first, let due = doc.dueAt {
            let text = "Your next \(kind.label) is \(doc.title) for \(doc.course): \(DateText.long(due, calendar: context.calendar)) (\(relative(due)))."
            return AssistantAnswer(text: text, sources: [SourceReference(document: doc)], question: parsed, isExact: true)
        }

        // Fall back to the syllabus, which often lists exam dates as prose.
        let query = "\(kind.label) date schedule \(parsed.original)"
        let hits = search(query, parsed: parsed, kinds: [.syllabus, .page, .announcement, .module])
        if let best = hits.first {
            let scope = parsed.course.map { " for \($0.code)" } ?? ""
            let text = "I don't see a dated \(kind.label)\(scope) on your calendar yet. Here's what the \(best.document.course) \(best.document.kind.label) says:\n\(excerpt(best.passage.text, query: query))"
            return AssistantAnswer(text: text, sources: sources(for: hits), question: parsed, grounding: hits, isExact: false)
        }
        let scope = parsed.course.map { " for \($0.code)" } ?? ""
        return AssistantAnswer(text: "I don't see any upcoming \(kind.label)\(scope) in your Canvas data.", sources: [], question: parsed, isExact: true)
    }

    private func itemDetail(_ parsed: ParsedQuestion, query: String) -> AssistantAnswer {
        let candidates = openItems(course: parsed.course, includeCompleted: true)
        if let item = bestItem(matching: query, in: candidates) {
            var text: String
            if let due = item.dueAt {
                text = "\(item.title) (\(item.course)) is due \(DateText.long(due, calendar: context.calendar)), \(relative(due))."
            } else {
                text = "\(item.title) (\(item.course)) has no due date on Canvas."
            }
            if item.isCompleted { text += " You've marked it done." }
            var refs = sources(for: [item])
            // Add the assignment description from Canvas when we have it.
            if let doc = assignmentDocument(for: item), let detail = description(of: doc) {
                text += "\n\(detail)"
                refs = [SourceReference(document: doc)]
            }
            return AssistantAnswer(text: text, sources: refs, question: parsed, isExact: true)
        }

        // Not on the calendar feed: try assignment documents, then retrieval.
        if let doc = bestDocument(matching: query, in: assignmentDocuments(course: parsed.course)) {
            var text: String
            if let due = doc.dueAt {
                text = "\(doc.title) (\(doc.course)) is due \(DateText.long(due, calendar: context.calendar)), \(relative(due))."
            } else {
                text = "\(doc.title) (\(doc.course)) has no due date on Canvas."
            }
            if let submitted = doc.submitted { text += submitted ? " Canvas shows it as submitted." : " Canvas shows it as not submitted." }
            if let detail = description(of: doc) { text += "\n\(detail)" }
            return AssistantAnswer(text: text, sources: [SourceReference(document: doc)], question: parsed, isExact: true)
        }
        return lookup(parsed, query: parsed.original)
    }

    private func submissionStatus(_ parsed: ParsedQuestion, query: String) -> AssistantAnswer {
        let docs = assignmentDocuments(course: parsed.course).filter { $0.submitted != nil }
        if query.isEmpty {
            let pending = docs
                .filter { $0.submitted == false && ($0.dueAt ?? .distantFuture) >= context.now.addingTimeInterval(-7 * 86_400) }
                .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            if docs.isEmpty {
                return AssistantAnswer(text: "I don't have submission data yet. Sync course materials in Settings, then ask again.", sources: [], question: parsed, isExact: true)
            }
            if pending.isEmpty {
                return AssistantAnswer(text: "Everything due recently shows as submitted on Canvas.", sources: [], question: parsed, isExact: true)
            }
            var lines = ["\(pending.count) assignment\(pending.count == 1 ? "" : "s") not yet submitted:"]
            for (index, doc) in pending.prefix(Self.maxListItems).enumerated() {
                let due = doc.dueAt.map { " · " + DateText.short($0, calendar: context.calendar) } ?? ""
                lines.append("\(index + 1). \(doc.course) · \(doc.title)\(due)")
            }
            return AssistantAnswer(text: lines.joined(separator: "\n"), sources: pending.prefix(3).map(SourceReference.init(document:)), question: parsed, isExact: true)
        }

        if let doc = bestDocument(matching: query, in: docs) {
            let state = doc.submitted == true ? "Yes. Canvas shows \(doc.title) (\(doc.course)) as submitted." : "Not yet. Canvas shows \(doc.title) (\(doc.course)) as not submitted."
            var text = state
            if doc.submitted == false, let due = doc.dueAt { text += " It's due \(DateText.long(due, calendar: context.calendar)), \(relative(due))." }
            return AssistantAnswer(text: text, sources: [SourceReference(document: doc)], question: parsed, isExact: true)
        }
        if let item = bestItem(matching: query, in: openItems(course: parsed.course, includeCompleted: true)) {
            let text = item.isCompleted
                ? "You marked \(item.title) (\(item.course)) done in LHF. Canvas hasn't reported a submission for it yet; sync course materials to check."
                : "\(item.title) (\(item.course)) isn't marked done, and I don't have Canvas submission data for it yet."
            return AssistantAnswer(text: text, sources: sources(for: [item]), question: parsed, isExact: true)
        }
        return AssistantAnswer(text: "I couldn't match \"\(query)\" to an assignment. Try the name as it appears on Canvas.", sources: [], question: parsed, isExact: true)
    }

    private func overdue(_ parsed: ParsedQuestion) -> AssistantAnswer {
        let items = overdueItems(course: parsed.course)
        let scope = parsed.course.map { " for \($0.code)" } ?? ""
        guard !items.isEmpty else {
            return AssistantAnswer(text: "Nothing overdue\(scope). Nice.", sources: [], question: parsed, isExact: true)
        }
        var lines = ["\(items.count) overdue item\(items.count == 1 ? "" : "s")\(scope):"]
        lines.append(contentsOf: numbered(items))
        lines.append("Oldest first. Knock out #1 and ask again.")
        return AssistantAnswer(text: lines.joined(separator: "\n"), sources: sources(for: Array(items.prefix(3))), question: parsed, isExact: true)
    }

    private func recentAnnouncements(_ parsed: ParsedQuestion) -> AssistantAnswer {
        let announcements = context.knowledge.documents(ofKind: .announcement)
            .filter { doc in parsed.course.map { CourseMatcher.sameCourse(doc.course, as: $0) } ?? true }
            .sorted { ($0.updatedAt ?? $0.fetchedAt) > ($1.updatedAt ?? $1.fetchedAt) }
        let scope = parsed.course.map { " for \($0.code)" } ?? ""
        guard !announcements.isEmpty else {
            let hint = context.knowledge.isEmpty ? " Sync course materials in Settings first." : ""
            return AssistantAnswer(text: "No announcements\(scope) yet.\(hint)", sources: [], question: parsed, isExact: true)
        }
        var lines = ["Latest announcements\(scope):"]
        let top = Array(announcements.prefix(3))
        for (index, doc) in top.enumerated() {
            let when = doc.updatedAt.map { " (" + DateText.dayOnly($0, calendar: context.calendar) + ")" } ?? ""
            let body = firstSentence(of: bodyText(of: doc), limit: 160)
            lines.append("\(index + 1). \(doc.course) · \(doc.title)\(when): \(body)")
        }
        let grounding = top.enumerated().map { index, doc in
            SearchHit(passage: Passage(documentID: doc.id, ordinal: 0, text: String(bodyText(of: doc).prefix(900))), document: doc, score: Double(3 - index))
        }
        return AssistantAnswer(text: lines.joined(separator: "\n"), sources: top.map(SourceReference.init(document:)), question: parsed, grounding: grounding, isExact: false)
    }

    private func lookup(_ parsed: ParsedQuestion, query: String) -> AssistantAnswer {
        if context.knowledge.isEmpty {
            return AssistantAnswer(text: "I only have your calendar so far. Sync course materials in Settings and I can answer questions about the syllabus, assignments, and announcements.", sources: [], question: parsed, isExact: true)
        }
        let hits = search(query, parsed: parsed, kinds: nil)
        guard let best = hits.first else {
            let scope = parsed.course.map { " for \($0.code)" } ?? ""
            return AssistantAnswer(text: "I couldn't find that in your course materials\(scope). Try different words, or ask about the syllabus, an assignment, or an announcement.", sources: [], question: parsed, isExact: true)
        }
        var lines = ["From the \(best.document.course) \(best.document.kind.label) \"\(best.document.title)\":", excerpt(best.passage.text, query: query)]
        if hits.count > 1, hits[1].document.id != best.document.id {
            let second = hits[1]
            lines.append("Also, the \(second.document.course) \(second.document.kind.label) \"\(second.document.title)\" says: \(excerpt(second.passage.text, query: query, maxSentences: 1))")
        }
        return AssistantAnswer(text: lines.joined(separator: "\n"), sources: sources(for: hits), question: parsed, grounding: hits, isExact: false)
    }

    // MARK: - Data helpers

    private func openItems(course: CourseSummary?, includeCompleted: Bool = false) -> [WorkItem] {
        context.items.filter { item in
            (includeCompleted || !item.isCompleted)
                && (course.map { CourseMatcher.sameCourse(item.course, as: $0) } ?? true)
        }
    }

    private func overdueItems(course: CourseSummary?) -> [WorkItem] {
        openItems(course: course)
            .filter { ($0.dueAt ?? .distantFuture) < context.now }
            .sorted(by: byDue)
    }

    private func assignmentDocuments(course: CourseSummary?) -> [CourseDocument] {
        context.knowledge.documents(ofKind: .assignment)
            .filter { doc in course.map { CourseMatcher.sameCourse(doc.course, as: $0) } ?? true }
    }

    private func assignmentDocument(for item: WorkItem) -> CourseDocument? {
        let itemID = item.url?.lastPathComponent
        return context.knowledge.documents(ofKind: .assignment).first { doc in
            (itemID != nil && doc.sourceID == itemID && CourseMatcher.sameCourse(item.course, as: CourseSummary(courseID: doc.courseID, code: doc.course, name: doc.course, url: nil)))
                || (doc.title.caseInsensitiveCompare(item.title) == .orderedSame && CourseMatcher.normalize(doc.course) == CourseMatcher.normalize(item.course))
        }
    }

    private func search(_ query: String, parsed: ParsedQuestion, kinds: Set<CourseDocument.Kind>?) -> [SearchHit] {
        let courseID = parsed.course.flatMap { course in
            context.knowledge.courses.first(where: { CourseMatcher.sameCourse($0.code, as: course) })?.courseID
        }
        var hits = context.search.search(query, courseID: courseID, kinds: kinds, limit: 4)
        if courseID == nil, let course = parsed.course {
            hits = hits.filter { CourseMatcher.sameCourse($0.document.course, as: course) }
        }
        return hits
    }

    /// Token-overlap match of a free-text mention against item titles. Numbers
    /// must match exactly ("pset 5" never matches "PSet 6").
    private func bestItem(matching query: String, in items: [WorkItem]) -> WorkItem? {
        bestMatch(query: query, candidates: items.map { ($0, $0.title) })
    }

    private func bestDocument(matching query: String, in docs: [CourseDocument]) -> CourseDocument? {
        bestMatch(query: query, candidates: docs.map { ($0, $0.title) })
    }

    private func bestMatch<T>(query: String, candidates: [(T, String)]) -> T? {
        let queryTokens = Set(TextTokenizer.tokens(query, minLength: 1))
        guard !queryTokens.isEmpty else { return nil }
        let queryNumbers = queryTokens.filter { $0.allSatisfy(\.isNumber) }
        var best: (T, Double)?
        for (candidate, title) in candidates {
            let titleTokens = Set(TextTokenizer.tokens(title, minLength: 1))
            let titleNumbers = titleTokens.filter { $0.allSatisfy(\.isNumber) }
            if !queryNumbers.isEmpty, queryNumbers.isDisjoint(with: titleNumbers) { continue }
            if queryNumbers.isEmpty, !titleNumbers.isEmpty, queryTokens.count == 1 { continue }
            let overlap = Double(queryTokens.intersection(titleTokens).count)
            guard overlap > 0 else { continue }
            let score = overlap / Double(queryTokens.count) + (queryNumbers.isEmpty ? 0 : 0.5)
            if score >= 0.5, score > (best?.1 ?? 0) { best = (candidate, score) }
        }
        return best?.0
    }

    // MARK: - Text helpers

    private func numbered(_ items: [WorkItem]) -> [String] {
        var lines: [String] = []
        for (index, item) in items.prefix(Self.maxListItems).enumerated() {
            let due = item.dueAt.map { DateText.short($0, calendar: context.calendar) } ?? "no due date"
            lines.append("\(index + 1). \(item.course) · \(item.title) · \(due)")
        }
        if items.count > Self.maxListItems {
            lines.append("…and \(items.count - Self.maxListItems) more. Ask about one course to narrow it down.")
        }
        return lines
    }

    private func sources(for items: [WorkItem]) -> [SourceReference] {
        items.compactMap { item in
            guard let url = item.url else { return nil }
            return SourceReference(title: item.title, course: item.course, kind: item.kind.rawValue, url: url)
        }
    }

    private func sources(for hits: [SearchHit]) -> [SourceReference] {
        var seen: Set<String> = []
        return hits.compactMap { hit in
            guard seen.insert(hit.document.id).inserted else { return nil }
            return SourceReference(document: hit.document)
        }
    }

    private func byDue(_ a: WorkItem, _ b: WorkItem) -> Bool {
        (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture)
    }

    /// "in 2 days", "in 3 hours", "4 days ago".
    func relative(_ date: Date) -> String {
        let seconds = date.timeIntervalSince(context.now)
        let past = seconds < 0
        let magnitude = abs(seconds)
        let value: String
        if magnitude < 3600 {
            let minutes = max(1, Int(magnitude / 60))
            value = "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else if magnitude < 86_400 {
            let hours = Int(magnitude / 3600)
            value = "\(hours) hour\(hours == 1 ? "" : "s")"
        } else {
            let days = Int((magnitude / 86_400).rounded())
            value = "\(days) day\(days == 1 ? "" : "s")"
        }
        return past ? "\(value) ago" : "in \(value)"
    }

    /// The document body without the "Due:/Points:/Status:" header lines the
    /// builder prepends for assignments.
    private func bodyText(of doc: CourseDocument) -> String {
        doc.text
            .components(separatedBy: "\n")
            .filter { !($0.hasPrefix("Due: ") || $0.hasPrefix("Points: ") || $0.hasPrefix("Status: ") || $0.hasPrefix("Posted: ")) }
            .joined(separator: "\n")
    }

    private func description(of doc: CourseDocument) -> String? {
        let body = bodyText(of: doc).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return "Canvas says: " + firstSentence(of: body, limit: 260)
    }

    func firstSentence(of text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let sentence = flat.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? flat
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= limit { return trimmed + (flat.count > trimmed.count ? "." : "") }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Up to `maxSentences` sentences from a passage, favoring the ones that
    /// contain the query's words, capped at ~320 characters.
    func excerpt(_ text: String, query: String, maxSentences: Int = 2) -> String {
        let queryTokens = Set(TextTokenizer.tokens(query))
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let sentences = flat
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 12 }
        guard !sentences.isEmpty else { return String(flat.prefix(320)) }

        // The best sentence is the one where the question's words make up the
        // largest share of it — "Attendance is not taken" beats "Late policy:
        // each student has four late days…" for an attendance question even
        // though both contain one query word. The sentence after it comes
        // along as context, because policy prose states the rule in one
        // sentence and the exception in the next.
        var bestIndex = 0
        var bestScore: (matches: Double, density: Double) = (-1, -1)
        for (index, sentence) in sentences.enumerated() {
            let tokens = TextTokenizer.tokens(sentence)
            let matches = Double(Set(tokens).intersection(queryTokens).count)
            let density = tokens.isEmpty ? 0 : matches / Double(tokens.count)
            if matches > bestScore.matches || (matches == bestScore.matches && density > bestScore.density) {
                bestScore = (matches, density)
                bestIndex = index
            }
        }
        let end = min(bestIndex + maxSentences, sentences.count)
        var result = sentences[bestIndex..<end].joined(separator: ". ") + "."
        if result.count > 320 {
            result = String(result.prefix(317)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return result
    }
}
