import Foundation
import Testing
@testable import LowHangingFruitKit

/// The on-device answerer's canned text, cut to the shortest true thing
/// ("I still get way too much text"). Every assertion here is an exact
/// match, so a sentence creeping back in fails loudly. Sync is automatic
/// and there is no sync button in Settings, so none of these tells a student
/// to go and sync.
@Suite("On-device canned answers")
struct AskShortAnswersTests {
    private static func answerer(knowledge: CourseKnowledgeBase = .empty, items: [WorkItem] = [], userName: String = "") -> ClassQuestionAnswerer {
        ClassQuestionAnswerer(context: AskKnowledgeContext(
            userName: userName, now: AssistantFixture.now, calendar: AssistantFixture.calendar, items: items, knowledge: knowledge
        ))
    }

    @Test("nothing synced is one short line, whichever question finds it out")
    func nothingSynced() {
        let answerer = Self.answerer(items: AssistantFixture.items)
        // A content question with no course materials.
        #expect(answerer.answer("late policy").text == "Nothing synced yet.")
        // "Latest announcements" with no course materials.
        #expect(answerer.answer("Latest announcements").text == "Nothing synced yet.")
        // "What have I not submitted?" with no assignment documents.
        let submission = QuestionParser.parse("what have I not submitted yet", courses: AssistantFixture.courses)
        #expect(submission.intent == .submissionStatus(query: ""))
        #expect(answerer.answer("what have I not submitted yet").text == "Nothing synced yet.")
    }

    @Test("no courses at all is 'No classes yet.'")
    func noClasses() {
        let text = Self.answerer().answer("What classes am I taking?").text
        #expect(text == "No classes yet.")
    }

    @Test("a question the materials do not answer is 'Couldn't find that.', named course or not")
    func couldntFindThat() {
        let knowledge = AssistantFixture.knowledge
        #expect(Self.answerer(knowledge: knowledge).answer("what is the dress code for the gala").text == "Couldn't find that.")
        // The course the question names is no longer repeated back. MGMT 1010
        // is a known class with no synced documents, so nothing matches.
        let scoped = Self.answerer(knowledge: knowledge).answer("what is the dress code for the gala in mgmt 1010")
        #expect(scoped.question.course?.code == "MGMT 1010")
        #expect(scoped.text == "Couldn't find that.")
        #expect(scoped.sources.isEmpty)
    }

    @Test("a class with materials but no announcements still says so, without a hint")
    func noAnnouncementsWithMaterials() {
        let knowledge = CourseKnowledgeBase(courses: AssistantFixture.courses, documents: [AssistantFixture.knowledge.documents[0]])
        let text = Self.answerer(knowledge: knowledge).answer("Latest announcements").text
        #expect(text == "No announcements yet.")
    }

    @Test("the help answer is the example lines only: no greeting, with or without a name")
    func helpIsExamplesOnly() {
        for name in ["", "Olisa"] {
            let text = Self.answerer(knowledge: AssistantFixture.knowledge, userName: name).answer("help").text
            let lines = text.components(separatedBy: "\n")
            #expect(lines.count == 5)
            #expect(lines[0] == "1. What's due this week?")
            #expect(lines[1] == "2. When is my next midterm?")
            #expect(lines[2] == "3. Did I submit the lab?")
            #expect(lines[3].hasPrefix("4. What's the late policy in "))
            #expect(lines[4] == "5. Latest announcements")
            #expect(!text.contains("Ask me anything"))
            #expect(!text.contains("Hi"))
            #expect(!text.contains("Olisa"))
        }
    }

    @Test("no canned answer sends the student to Settings or tells them to sync or ask again")
    func noInstructions() {
        let answerer = Self.answerer(items: AssistantFixture.items)
        let texts = [
            answerer.answer("late policy").text,
            answerer.answer("Latest announcements").text,
            answerer.answer("what have I not submitted yet").text,
            Self.answerer().answer("What classes am I taking?").text,
            Self.answerer(knowledge: AssistantFixture.knowledge).answer("what is the dress code for the gala").text,
        ]
        for text in texts {
            let lowered = text.lowercased()
            #expect(!lowered.contains("settings"))
            #expect(!lowered.contains("ask again"))
            #expect(!lowered.contains("try different"))
            #expect(!lowered.contains("connect canvas"))
        }
    }

    @Test("the starter chip 'what's due this week?' is a structured question the answerer handles")
    func dueThisWeekChip() {
        let chip = "what's due this week?"
        let parsed = QuestionParser.parse(chip, courses: AssistantFixture.courses)
        #expect(parsed.intent == .upcomingWork(window: .thisWeek, kind: .any))
        let answer = Self.answerer(knowledge: AssistantFixture.knowledge, items: AssistantFixture.items).answer(chip)
        #expect(answer.isExact)
        #expect(answer.text.hasPrefix("4 things due"))
    }
}
