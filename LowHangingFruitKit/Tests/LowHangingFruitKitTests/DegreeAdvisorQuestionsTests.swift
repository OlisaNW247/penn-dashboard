import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

private func questionsSource(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(
        contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/\(name)"), encoding: .utf8)
}

private func wire(
    _ id: String, _ text: String = "q", kind: String = "doubleCount",
    detail: String? = nil, answer: DegreeAdvisorAnswer? = nil
) -> DegreeAdvisorQuestionWire {
    DegreeAdvisorQuestionWire(id: id, kind: kind, question: text, detail: detail, answer: answer)
}

private func question(_ id: String, _ text: String = "q") -> DegreeAdvisorQuestion {
    DegreeAdvisorQuestion(id: id, kind: "doubleCount", question: text)
}

private func decodePlan(_ questionsJSON: String?) throws -> DegreeEnginePlan {
    var json = "{\"schedule\":[]"
    if let questionsJSON { json += ",\"advisorQuestions\":\(questionsJSON)" }
    json += "}"
    return try JSONDecoder().decode(DegreeEnginePlan.self, from: Data(json.utf8))
}

@Suite("Advisor questions: the wire")
struct DegreeAdvisorQuestionsWireTests {
    @Test("a good list decodes with kind, detail and the echoed answer")
    func good() throws {
        let plan = try decodePlan("""
        [{"id":"a","kind":"doubleCount","question":"q1","detail":"saves 1 cu","answer":null},
         {"id":"b","kind":"placement","question":"q2","answer":"yes"},
         {"id":"c","kind":"load","question":"q3","answer":"no"}]
        """)
        #expect(plan.advisorQuestions.map { $0.id } == ["a", "b", "c"])
        #expect(plan.advisorQuestions[0].detail == "saves 1 cu")
        #expect(plan.advisorQuestions[0].answer == nil)
        #expect(plan.advisorQuestions[1].answer == .yes)
        #expect(plan.advisorQuestions[2].answer == .no)
    }

    @Test("absent or malformed reads as none")
    func absentOrMalformed() throws {
        #expect(try decodePlan(nil).advisorQuestions.isEmpty)
        #expect(try decodePlan("7").advisorQuestions.isEmpty)
        #expect(try decodePlan("\"x\"").advisorQuestions.isEmpty)
    }

    @Test("a bad element is dropped and the rest survive")
    func badElement() throws {
        let plan = try decodePlan("""
        [{"id":"a","kind":"load","question":"q1"}, {"kind":"x"}, 5,
         {"id":"b","kind":"load","question":"q2"}]
        """)
        #expect(plan.advisorQuestions.map { $0.id } == ["a", "b"])
    }

    @Test("an unknown kind is kept as it is and an unknown answer reads as none")
    func unknownKind() throws {
        let plan = try decodePlan("""
        [{"id":"a","kind":"something new","question":"q","answer":"maybe"},
         {"id":"b","question":"q2"}]
        """)
        #expect(plan.advisorQuestions[0].kind == "something new")
        #expect(plan.advisorQuestions[0].answer == nil)
        #expect(plan.advisorQuestions[1].kind == "")
    }

    @Test("more than twelve are cut to twelve")
    func cap() throws {
        let items = (0..<15).map { "{\"id\":\"i\($0)\",\"kind\":\"load\",\"question\":\"q\"}" }
        let plan = try decodePlan("[" + items.joined(separator: ",") + "]")
        #expect(plan.advisorQuestions.count == 12)
        #expect(plan.advisorQuestions.last?.id == "i11")
    }
}

@Suite("Advisor questions: the notes")
struct DegreeAdvisorNotesTests {
    @Test("an answer is set, replaced and cleared")
    func setting() {
        var notes = DegreeAdvisorNotes(questions: [question("a"), question("b")])
        notes = notes.setting(.yes, for: "a")
        #expect(notes.answers == ["a": .yes])
        notes = notes.setting(.no, for: "a")
        #expect(notes.answers == ["a": .no])
        notes = notes.setting(nil, for: "a")
        #expect(notes.answers.isEmpty)
    }

    @Test("past forty answers the earliest question's answer goes first, never the one just set")
    func bound() {
        let questions = (0..<12).map { question(String(format: "q%02d", $0)) }
        var notes = DegreeAdvisorNotes(questions: questions)
        for index in 0..<40 {
            // Ids with no question first (sorted before any that has one).
            notes.answers[String(format: "z%02d", index)] = .yes
        }
        notes.answers["q00"] = .yes
        notes.answers.removeValue(forKey: "z00")
        #expect(notes.answers.count == 40)
        notes = notes.setting(.no, for: "q05")
        #expect(notes.answers.count == 40)
        #expect(notes.answers["q05"] == .no)
        // The id no question names went, before q00 whose question is first.
        #expect(notes.answers["z01"] == nil)
        #expect(notes.answers["q00"] == .yes)
    }

    @Test("receiving replaces the questions, keeps the phone's answer, adopts an echo")
    func receiving() {
        var notes = DegreeAdvisorNotes(questions: [question("old")], answers: ["a": .no, "old": .yes])
        notes = notes.receiving([
            wire("a", answer: .yes),    // the phone has no.. and keeps it
            wire("b", answer: .yes),    // adopted
            wire("c"),
        ])
        #expect(notes.questions.map { $0.id } == ["a", "b", "c"])
        #expect(notes.answers["a"] == .no)
        #expect(notes.answers["b"] == .yes)
        #expect(notes.answers["c"] == nil)
        // An answer for a question the list dropped is kept.
        #expect(notes.answers["old"] == .yes)
        #expect(notes.answersAtLastPlan == notes.answers)
        #expect(!notes.hasChanges)
    }

    @Test("receiving keeps each id once and at most twelve")
    func receivingCaps() {
        var list = (0..<15).map { wire("i\($0)") }
        list.insert(wire("i0", "again"), at: 1)
        let notes = DegreeAdvisorNotes().receiving(list)
        #expect(notes.questions.count == 12)
        #expect(notes.questions.filter { $0.id == "i0" }.count == 1)
        #expect(notes.questions[0].question == "q")
    }

    @Test("hasChanges and openCount")
    func changesAndOpen() {
        var notes = DegreeAdvisorNotes(questions: [question("a"), question("b"), question("c")])
        #expect(notes.openCount == 3)
        #expect(!notes.hasChanges)
        notes = notes.setting(.yes, for: "a")
        #expect(notes.openCount == 2)
        #expect(notes.hasChanges)
        notes = notes.receiving([wire("a"), wire("b"), wire("c")])
        #expect(!notes.hasChanges)
        notes = notes.setting(nil, for: "a")
        #expect(notes.hasChanges)
    }

    @Test("requestAnswers is sorted by id and capped at forty")
    func requestAnswers() {
        var notes = DegreeAdvisorNotes()
        notes.answers = ["b": .no, "a": .yes, "c": .yes]
        #expect(notes.requestAnswers.map { $0.id } == ["a", "b", "c"])
        #expect(notes.requestAnswers.map { $0.answer } == [.yes, .no, .yes])
        var many = DegreeAdvisorNotes()
        for index in 0..<55 { many.answers[String(format: "k%02d", index)] = .yes }
        #expect(many.requestAnswers.count == 40)
    }

    @Test("copyText lists only the open questions, numbered, nothing else")
    func copyText() {
        let notes = DegreeAdvisorNotes(
            questions: [question("a", "first?"), question("b", "second?"), question("c", "third?")],
            answers: ["b": .yes])
        #expect(notes.copyText == "1. first?\n2. third?")
        #expect(DegreeAdvisorNotes().copyText == "")
    }

    @Test("the line that opens the sheet")
    func entryText() {
        var notes = DegreeAdvisorNotes(questions: [question("a"), question("b")])
        #expect(DegreeAdvisorQuestionsSheet.entryText(notes) == "ask your advisor · 2")
        notes = notes.setting(.yes, for: "a").setting(.no, for: "b")
        #expect(DegreeAdvisorQuestionsSheet.entryText(notes) == "advisor answers · update plan")
        notes = notes.receiving([wire("a"), wire("b")])
        #expect(DegreeAdvisorQuestionsSheet.entryText(notes) == "advisor answers")
    }

    @Test("answered questions sort after unanswered ones")
    func ordering() {
        let notes = DegreeAdvisorNotes(
            questions: [question("a"), question("b"), question("c")], answers: ["a": .no])
        #expect(DegreeAdvisorQuestionsSheet.ordered(notes).map { $0.id } == ["b", "c", "a"])
    }
}

@Suite("Advisor questions: stored with the plan")
struct DegreeAdvisorQuestionsPlanTests {
    private func notes() -> DegreeAdvisorNotes {
        DegreeAdvisorNotes(
            questions: [question("a", "q?")], answers: ["a": .yes], answersAtLastPlan: [:])
    }

    private func plan() -> DegreePlan {
        DegreePlan(
            terms: [PlannedTerm(termCode: "202710", courses: [
                PlannedCourse(code: "CIS 1200", title: nil, credits: 1)]),
                    PlannedTerm(termCode: "202730")],
            summary: nil, advisor: notes())
    }

    @Test("a plan with notes round-trips through JSON")
    func roundTrip() throws {
        let data = try JSONEncoder().encode(plan())
        let back = try JSONDecoder().decode(DegreePlan.self, from: data)
        #expect(back == plan())
        #expect(back.advisor?.answers["a"] == .yes)
    }

    @Test("an old plan file without notes loads, and a malformed value costs only itself")
    func oldAndMalformed() throws {
        let old = try JSONDecoder().decode(
            DegreePlan.self, from: Data("{\"terms\":[{\"termCode\":\"202710\",\"courses\":[]}]}".utf8))
        #expect(old.advisor == nil)
        #expect(old.terms.count == 1)
        let bad = try JSONDecoder().decode(
            DegreePlan.self,
            from: Data("{\"terms\":[{\"termCode\":\"202710\",\"courses\":[]}],\"advisor\":7}".utf8))
        #expect(bad.advisor == nil)
        #expect(bad.terms.count == 1)
    }

    @Test("every hand edit of the table keeps the notes")
    func handEdits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = plan()
        let course = PlannedCourse(code: "CIS 1210", title: nil, credits: 1)
        let added = DegreePlanMath.adding(course, to: "202730", in: start)
        #expect(added != start)
        #expect(added.advisor == notes())
        let moved = DegreePlanMath.moving(courseCode: "CIS 1200", to: "202730", before: nil, in: start)
        #expect(moved != start)
        #expect(moved.advisor == notes())
        let removed = DegreePlanMath.removing(courseCode: "CIS 1200", from: "202710", in: start)
        #expect(removed != start)
        #expect(removed.advisor == notes())
        let longer = DegreePlanMath.withTermAdded(start, now: now)
        #expect(longer.terms.count == 3)
        #expect(longer.advisor == notes())
        let shorter = DegreePlanMath.removingLastTermIfEmpty(start)
        #expect(shorter.terms.count == 1)
        #expect(shorter.advisor == notes())
        #expect(DegreePlanMath.ensuringFirstTerm(DegreePlan(advisor: notes()), now: now).advisor == notes())
    }

    @Test("an engine plan folds in its questions and keeps the student's answers")
    func engineFolds() {
        let engine = DegreeEnginePlan(
            remainingCredits: 4, remainingCreditsWithoutOverlap: 5,
            scenarios: [], chosen: "",
            schedule: [DegreeEngineTerm(term: "202710", credits: 1, courses: [
                DegreeEngineCourse(code: "CIS 1210", title: "x", credits: 1)])],
            advisorQuestions: [wire("a", answer: .no), wire("b", "second?")])
        let outcome = DegreeAdvisor.applyEnginePlan(
            engine, to: plan(), currentTerm: "202630", now: Date(timeIntervalSince1970: 0))
        let result = outcome.plan.advisor
        #expect(result?.questions.map { $0.id } == ["a", "b"])
        // The phone's own yes beats the echoed no.
        #expect(result?.answers["a"] == .yes)
        #expect(result?.hasChanges == false)
    }

    @Test("an engine plan with no questions and no notes leaves notes nil")
    func engineWithoutNotes() {
        let engine = DegreeEnginePlan(
            remainingCredits: 4, remainingCreditsWithoutOverlap: 5,
            scenarios: [], chosen: "",
            schedule: [DegreeEngineTerm(term: "202710", credits: 1, courses: [
                DegreeEngineCourse(code: "CIS 1210", title: "x", credits: 1)])])
        let outcome = DegreeAdvisor.applyEnginePlan(
            engine, to: DegreePlan(), currentTerm: "202630", now: Date(timeIntervalSince1970: 0))
        #expect(outcome.plan.advisor == nil)
    }
}

@Suite("Advisor questions: the request")
struct DegreeAdvisorQuestionsRequestTests {
    private func encoded(_ answers: [DegreeAdvisorAnswerEntry]) throws -> [String: Any] {
        let brief = DegreeAdvisorBrief(context: "ctx", terms: [], addable: [:])
        let request = DegreeAdvisor.request(
            question: "q", turns: [], brief: brief, now: Date(timeIntervalSince1970: 0),
            advisorAnswers: answers)
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("the answers are a top-level key")
    func present() throws {
        let object = try encoded([
            DegreeAdvisorAnswerEntry(id: "a", answer: .yes),
            DegreeAdvisorAnswerEntry(id: "b", answer: .no)])
        let list = try #require(object["advisorAnswers"] as? [[String: Any]])
        #expect(list.count == 2)
        #expect(list[0]["id"] as? String == "a")
        #expect(list[0]["answer"] as? String == "yes")
        #expect(list[1]["answer"] as? String == "no")
    }

    @Test("the key is omitted when there are none")
    func omitted() throws {
        let object = try encoded([])
        #expect(object["advisorAnswers"] == nil)
    }

    @Test("more than forty are cut to forty")
    func capped() throws {
        let many = (0..<45).map { DegreeAdvisorAnswerEntry(id: String(format: "k%02d", $0), answer: .yes) }
        let list = try #require(try encoded(many)["advisorAnswers"] as? [[String: Any]])
        #expect(list.count == 40)
    }
}

@Suite("Advisor questions: where they are shown, in the source")
struct DegreeAdvisorQuestionsSourceTests {
    @Test("the table and the chat both open the sheet")
    func presenters() throws {
        let table = try questionsSource("DegreeSemesterTable.swift")
        let chat = try questionsSource("DegreeAdvisorView.swift")
        #expect(table.contains("DegreeAdvisorQuestionsSheet"))
        #expect(chat.contains("DegreeAdvisorQuestionsSheet"))
    }

    @Test("the sheet offers update plan and keeps to the copy rule")
    func sheet() throws {
        let sheet = try questionsSource("DegreeAdvisorQuestionsSheet.swift")
        #expect(sheet.contains("update plan"))
        #expect(sheet.contains("ask your advisor"))
        let lowered = sheet.lowercased()
        #expect(!lowered.contains("recommend"))
        #expect(!lowered.contains("average"))
        #expect(!lowered.contains("graduate"))
    }

    @Test("the pending prompt is cleared where the chat takes it, before it is sent")
    func pendingConsumed() throws {
        let chat = try questionsSource("DegreeAdvisorView.swift")
        let clear = try #require(chat.range(of: "state.degreeAdvisorPendingPrompt = nil"))
        let send = try #require(chat.range(of: "send(prompt)"))
        #expect(clear.lowerBound < send.lowerBound)
    }

    @Test("every plan request carries the answers")
    func requestsCarryAnswers() throws {
        let source = try questionsSource("AppState+DegreeAdvisor.swift")
        let count = source.components(separatedBy: "advisorAnswers: degreePlan.advisor?.requestAnswers ?? []").count - 1
        #expect(count == 3)
    }
}
