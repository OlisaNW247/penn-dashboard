import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Steps 3 and 5 of `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md` Part 3: the
/// per-intent slot budgets and the computed lines (the registrar's schedule
/// for the asked day, the work due in the asked range). Pinned clock
/// (Monday 2026-11-02, 13:12 in New York), no model, structured assertions.

private typealias F = TimeFrameFixture

enum BudgetFixture {
    static let meetingQuestion = "Do I not have cis 2620 class today?"

    static let lecture = ClassMeeting(sectionID: "CIS-2620-001", activity: "LEC", weekday: 2, startMinutes: 615, endMinutes: 704)
    static let recitation = ClassMeeting(sectionID: "CIS-2620-201", activity: "REC", weekday: 2, startMinutes: 930, endMinutes: 989)
    static let wednesdayLecture = ClassMeeting(sectionID: "CIS-2620-001", activity: "LEC", weekday: 4, startMinutes: 615, endMinutes: 704)

    static let catalog = CourseCatalogEntry(
        courseID: "1", catalogCode: "CIS-2620", title: "Operating Systems",
        meetings: [lecture, recitation, wednesdayLecture]
    )

    static func context(
        _ documents: [CourseDocument],
        section: String? = nil,
        catalog: [CourseCatalogEntry] = [],
        work: [WorkItem] = [],
        askedAt: Date = F.pinned
    ) -> AssistantContext {
        let course = CourseSummary(courseID: "1", code: "CIS 2620", name: "CIS 2620 Operating Systems", url: nil, section: section)
        return AssistantContext(
            courseCodes: ["CIS 2620"],
            contextDocument: "the exact document text",
            askedAt: askedAt,
            timeZone: F.newYork,
            knowledge: CourseKnowledgeBase(courses: [course], documents: documents, catalog: catalog),
            work: work
        )
    }

    static func page(_ id: String, title: String, text: String) -> CourseDocument {
        CourseDocument(courseID: "1", course: "CIS 2620", kind: .page, sourceID: id, title: title, url: nil, text: text)
    }

    static func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }
}

@Suite("Ask excerpts: the registrar's schedule line for a class-meeting question")
struct AskScheduleLineTests {
    typealias B = BudgetFixture
    static let scheduleHead = "Weekly schedule (registrar): "

    @Test("the student's own section only, marked, right after the local date line")
    func ownSection() throws {
        let block = BackendAssistantResponder.excerptBlock(
            question: B.meetingQuestion, context: B.context([F.schedule], section: "001", catalog: [B.catalog])
        )
        let all = B.lines(block.text)
        #expect(all[0].hasPrefix("The student's local date and time: "))
        #expect(all[1] == "Weekly schedule (registrar): CIS 2620 lecture Mon 10:15–11:44 AM (section 001, the student's section).")
        #expect(!block.text.contains("recitation"))
    }

    @Test("with no known section every section of the day is listed, earliest first")
    func everySection() {
        let block = BackendAssistantResponder.excerptBlock(
            question: B.meetingQuestion, context: B.context([F.schedule], catalog: [B.catalog])
        )
        let all = B.lines(block.text)
        #expect(all[1] == "Weekly schedule (registrar): CIS 2620 lecture Mon 10:15–11:44 AM (section 001); recitation Mon 3:30–4:29 PM (section 201).")
    }

    @Test("a day with no meeting says so, with the weekday and date")
    func noMeetingDay() {
        let tuesday = F.eastern(2026, 11, 3, 12)
        let block = BackendAssistantResponder.excerptBlock(
            question: B.meetingQuestion, context: B.context([F.schedule], catalog: [B.catalog], askedAt: tuesday)
        )
        #expect(B.lines(block.text)[1] == "Weekly schedule (registrar): no CIS 2620 meeting on Tuesday 2026-11-03.")
    }

    @Test("a catalog with nothing for the course gives no schedule line")
    func noCatalog() {
        let block = BackendAssistantResponder.excerptBlock(question: B.meetingQuestion, context: B.context([F.schedule]))
        #expect(!block.text.contains(Self.scheduleHead))
    }

    @Test("the authority rule is the last line, after the excerpts, and the schedule line sits before them")
    func authorityRuleLast() throws {
        let post = F.ed(1, title: "No lectures this week but quiz on Monday", body: "Review the proofs before then.", posted: F.eastern(2026, 11, 1))
        let block = BackendAssistantResponder.excerptBlock(
            question: B.meetingQuestion, context: B.context([post, F.schedule], catalog: [B.catalog])
        )
        let all = B.lines(block.text)
        #expect(all.last == BackendAssistantResponder.meetingAuthorityRule)
        #expect(!BackendAssistantResponder.meetingAuthorityRule.hasPrefix("["))
        let scheduleIndex = try #require(all.firstIndex { $0.hasPrefix(Self.scheduleHead) })
        let firstExcerpt = try #require(all.firstIndex { $0.hasPrefix("[1] ") })
        #expect(scheduleIndex < firstExcerpt)
        #expect(block.text.contains(BackendAssistantResponder.meetingExcerptNote))
        // The newest post is still the first excerpt, above the BM25 fill.
        #expect(all[firstExcerpt].contains("No lectures this week"))
        #expect(block.sources.first?.documentID == post.id)
    }

    @Test("with no excerpts at all the rule still closes the block")
    func ruleWithoutExcerpts() {
        let other = B.page("p", title: "Parking", text: "Parking permits are sold at the garage.")
        let withPage = BackendAssistantResponder.excerptBlock(
            question: B.meetingQuestion, context: B.context([other], catalog: [B.catalog])
        )
        #expect(B.lines(withPage.text).last == BackendAssistantResponder.meetingAuthorityRule)
    }

    @Test("clock text is arithmetic from minutes")
    func timeText() {
        #expect(WeeklyScheduleLine.timeRange(startMinutes: 615, endMinutes: 704) == "10:15–11:44 AM")
        #expect(WeeklyScheduleLine.timeRange(startMinutes: 660, endMinutes: 735) == "11:00 AM–12:15 PM")
        #expect(WeeklyScheduleLine.timeRange(startMinutes: 0, endMinutes: 50) == "12:00–12:50 AM")
        #expect(WeeklyScheduleLine.timeRange(startMinutes: 780, endMinutes: 869) == "1:00–2:29 PM")
    }
}

@Suite("Ask excerpts: slot budgets per intent")
struct AskSlotBudgetTests {
    typealias B = BudgetFixture

    private func standingIDs(_ docs: [CourseDocument]) -> Set<String> {
        Set(docs.filter { $0.kind == .syllabus || $0.kind == .page || $0.kind == .file }.map(\.id))
    }

    @Test("a policy question reserves four slots for standing material even when posts score higher")
    func policyReservesFour() {
        var docs: [CourseDocument] = []
        for n in 0..<6 {
            docs.append(F.ed(100 + n, title: "Laptop late note \(n)", body: "Late laptop policy reminder number \(n) laptop laptop laptop.", posted: F.eastern(2026, 10, 20 + n)))
        }
        for n in 0..<4 {
            docs.append(B.page("pg\(n)", title: "Course page \(n)", text: "Laptops are allowed in section \(n)."))
        }
        let syllabus = CourseDocument(courseID: "1", course: "CIS 2620", kind: .syllabus, sourceID: "syl", title: "CIS 2620 syllabus", url: nil, text: "Laptop use: laptops are allowed.")
        docs.append(syllabus)
        let question = "what does the cis 2620 syllabus say about the laptop"
        #expect(F.tag(F.frame(question)) == "policy")
        let block = BackendAssistantResponder.excerptBlock(question: question, context: B.context(docs))
        let standing = standingIDs(docs)
        #expect(block.sources.count == BackendAssistantResponder.excerptLimit)
        #expect(block.sources.filter { standing.contains($0.documentID) }.count >= AskExcerptBudget.policyReservedSlots)
    }

    @Test("a dated post without a policy word is dropped; one with a policy word is kept")
    func policyWordGate() {
        let plain = F.ed(1, title: "Bring a laptop", body: "Reminder: bring a laptop to the room on Friday.", posted: F.eastern(2026, 10, 30))
        let policy = F.ed(2, title: "Laptop late rule", body: "The late policy for the laptop lab changed.", posted: F.eastern(2026, 10, 30))
        let syllabus = CourseDocument(courseID: "1", course: "CIS 2620", kind: .syllabus, sourceID: "syl", title: "CIS 2620 syllabus", url: nil, text: "Laptop use: laptops are allowed.")
        let question = "what does the cis 2620 syllabus say about the laptop"
        let block = BackendAssistantResponder.excerptBlock(question: question, context: B.context([plain, policy, syllabus]))
        let ids = block.sources.map(\.documentID)
        #expect(!ids.contains(plain.id))
        #expect(ids.contains(policy.id))
        #expect(ids.contains(syllabus.id))
    }

    @Test("news picks stop at six so two search hits survive")
    func newsCap() throws {
        var posts: [CourseDocument] = []
        for n in 0..<10 {
            posts.append(F.ed(100 + n, title: "Board note \(n)", body: "Reminder number \(n) about the project.", posted: F.eastern(2026, 10, 20 + n)))
        }
        let pageA = B.page("a", title: "What is new in CIS 2620", text: "What is new in CIS 2620: what is new, new in cis 2620.")
        let pageB = B.page("b", title: "New in CIS 2620", text: "New in cis 2620, what is new.")
        let block = BackendAssistantResponder.excerptBlock(question: "what's new in cis 2620", context: B.context(posts + [pageA, pageB]))
        try #require(block.sources.count == BackendAssistantResponder.excerptLimit)
        let newestSix = posts.sorted { ($0.shownPostedAt ?? .distantPast) > ($1.shownPostedAt ?? .distantPast) }.prefix(6).map(\.id)
        #expect(Array(block.sources.prefix(6).map(\.documentID)) == Array(newestSix))
        let tail = Set(block.sources.suffix(2).map(\.documentID))
        #expect(tail == [pageA.id, pageB.id])
    }

    @Test("a specific question's block is exactly a plain search's, with no computed line and no rule")
    func specificUnchanged() throws {
        let question = "tell me about the project partners"
        #expect(F.tag(F.frame(question)) == "specific")
        let docs = [
            B.page("a", title: "Project partners", text: "Project partners are assigned by the staff in week three."),
            B.page("b", title: "Parking", text: "Parking permits are sold at the garage."),
        ]
        let context = B.context(docs, catalog: [B.catalog])
        let block = BackendAssistantResponder.excerptBlock(question: question, context: context)
        let plain = CourseSearch(knowledge: context.knowledge).search(
            question, courseIDs: nil, limit: BackendAssistantResponder.excerptLimit, perDocument: BackendAssistantResponder.excerptsPerDocument
        ).filter { !$0.isTextlessEdPost }
        try #require(!plain.isEmpty)
        var expected = [
            BackendAssistantResponder.localDateLine(askedAt: context.askedAt, timeZone: context.timeZone),
            "RETRIEVED EXCERPTS (from the student's synced course materials):",
        ]
        for (index, hit) in plain.enumerated() {
            let body = BackendAssistantResponder.cutAtWordBoundary(
                BackendAssistantResponder.structuredExcerptBody(hit.passage.text), limit: BackendAssistantResponder.excerptCharacterLimit
            )
            expected.append("[\(index + 1)] \(hit.document.course) · \(hit.document.kind.label) · \"\(hit.document.title)\": \(body)")
        }
        #expect(block.text == expected.joined(separator: "\n"))
    }
}

@Suite("Ask excerpts: the computed due list for a deadline question")
struct AskDueListTests {
    typealias B = BudgetFixture

    private func item(_ id: String, _ title: String, due: Date?, done: Bool = false, cancelled: Bool = false) -> WorkItem {
        WorkItem(id: id, course: "CIS 2620", title: title, kind: .assignment, dueAt: due, url: nil, isCompleted: done, isCancelled: cancelled)
    }

    @Test("exactly the items due in the asked day, sorted, with the document's status words")
    func listsInRange() throws {
        let work = [
            item("3", "Homework 6", due: F.eastern(2026, 11, 3, 23, 59)),
            item("1", "Homework 5", due: F.eastern(2026, 11, 3, 9, 0), done: true),
            item("2", "Quiz 4", due: F.eastern(2026, 11, 3, 9, 0), cancelled: true),
            item("4", "Today's lab", due: F.eastern(2026, 11, 2, 23, 59)),
            item("5", "Next week", due: F.eastern(2026, 11, 9, 12)),
            item("6", "No date", due: nil),
        ]
        let question = "what homework is due tomorrow"
        let block = BackendAssistantResponder.excerptBlock(question: question, context: B.context([F.schedule], work: work))
        let all = B.lines(block.text)
        #expect(all[1] == "Due in the asked range (2026-11-03 to 2026-11-03):")
        #expect(all[2] == "CIS 2620 · Homework 5 · due 2026-11-03T09:00:00-05:00 · done")
        #expect(all[3] == "CIS 2620 · Quiz 4 · due 2026-11-03T09:00:00-05:00 · cancelled")
        #expect(all[4] == "CIS 2620 · Homework 6 · due 2026-11-03T23:59:00-05:00 · outstanding")
        #expect(!block.text.contains("Next week"))
        #expect(!block.text.contains("Today's lab"))
    }

    @Test("an empty range says nothing is due")
    func nothingDue() {
        let block = BackendAssistantResponder.excerptBlock(
            question: "what homework is due tomorrow", context: B.context([F.schedule], work: [item("9", "Later", due: F.eastern(2026, 11, 20, 12))])
        )
        #expect(B.lines(block.text)[1] == "Nothing on the work list is due in the asked range (2026-11-03 to 2026-11-03).")
    }

    @Test("the list is capped at twenty lines")
    func capped() {
        let work = (0..<25).map { item("w\($0)", "Task \($0 < 10 ? "0" : "")\($0)", due: F.eastern(2026, 11, 3, 12)) }
        let lines = AskExcerptBudget.dueList(
            work: work, range: F.range(F.frame("what homework is due tomorrow"))!, timeZone: F.newYork
        )
        #expect(lines.count == 1 + AskExcerptBudget.dueListLimit + 1)
        #expect(lines.last == "(5 more not shown)")
    }

    @Test("the passages equal a plain search's and the computed list precedes them")
    func passagesAreAPlainSearchs() throws {
        let post = F.ed(9, title: "Homework 5", body: "Homework 5 is due tomorrow at noon.", posted: F.eastern(2026, 11, 2, 9))
        let documents = [F.schedule, post]
        let question = "what homework is due tomorrow"
        let context = B.context(documents, work: [item("1", "Homework 5", due: F.eastern(2026, 11, 3, 12))])
        let block = BackendAssistantResponder.excerptBlock(question: question, context: context)
        let plain = CourseSearch(knowledge: context.knowledge)
            .search(question, courseIDs: nil, limit: BackendAssistantResponder.excerptLimit, perDocument: BackendAssistantResponder.excerptsPerDocument)
            .filter { !$0.isTextlessEdPost }
        try #require(!plain.isEmpty)
        #expect(block.sources.map(\.documentID) == plain.map(\.document.id))
        let all = B.lines(block.text)
        let due = try #require(all.firstIndex { $0.hasPrefix("Due in the asked range") })
        let firstExcerpt = try #require(all.firstIndex { $0.hasPrefix("[1] ") })
        #expect(due < firstExcerpt)
    }
}
