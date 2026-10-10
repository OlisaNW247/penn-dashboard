import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Two courses, one where the earlier question's answer lives and one that is
/// a much stronger match for the follow-up's own words. If a follow-up were
/// retrieved on its own it would land in ECON 1; the tests below hold it in
/// CIS 2400.
private enum FollowUpFixture {
    static let cis = CourseSummary(courseID: "1", code: "CIS 2400", name: "CIS 2400 Introduction to Computer Systems", url: nil)
    static let econ = CourseSummary(courseID: "2", code: "ECON 1", name: "ECON 1 Introduction to Micro Economics", url: nil)
    static let courses = [cis, econ]

    /// What a student would have just asked, and the fragment that follows it.
    static let first = "What's the late policy in CIS 2400?"
    static let followUp = "and for the final?"

    static var knowledge: CourseKnowledgeBase {
        CourseKnowledgeBase(courses: courses, documents: [
            CourseDocument(
                courseID: "1", course: "CIS 2400", kind: .syllabus, sourceID: "syllabus", title: "CIS 2400 syllabus", url: nil,
                text: "Late policy\nYou have three late days for the semester. After that, late work loses ten percent per day.\nExams\nThe cumulative final is held during the university exam period."
            ),
            CourseDocument(
                courseID: "2", course: "ECON 1", kind: .syllabus, sourceID: "syllabus", title: "ECON 1 syllabus", url: nil,
                text: "Final exam\nThe final exam is the biggest exam. The final exam is worth forty percent of the final grade. The final exam review is mandatory before the final exam."
            ),
            CourseDocument(
                courseID: "2", course: "ECON 1", kind: .announcement, sourceID: "a1", title: "Final exam room", url: nil,
                text: "The final exam is in Huntsman 245. Bring ID to the final exam. The final exam starts at nine."
            ),
        ])
    }

    static func assistantContext(previous: String?, older: [String] = []) -> AssistantContext {
        AssistantContext(
            courseCodes: courses.map(\.code),
            contextDocument: "doc",
            askedAt: AssistantFixture.now,
            knowledge: knowledge,
            previousQuestion: previous,
            olderQuestions: older
        )
    }

    static func knowledgeContext(previous: String?, older: [String] = [], items: [WorkItem] = [], knowledge: CourseKnowledgeBase? = nil) -> AskKnowledgeContext {
        AskKnowledgeContext(
            userName: "Olisa", now: AssistantFixture.now, calendar: AssistantFixture.calendar,
            items: items, knowledge: knowledge ?? Self.knowledge, previousQuestion: previous, olderQuestions: older
        )
    }

    /// The second link of the chain, and the third question that follows it.
    /// Neither names a course; only `first` does.
    static let midterm = "what about the midterm?"

    /// Which of the fixture's course codes appear in a rendered excerpts block.
    static func courses(in excerpts: String) -> Set<String> {
        Set(courses.map(\.code).filter { excerpts.contains($0) })
    }
}

@Suite("Follow-up retrieval")
struct FollowUpRetrievalTests {
    private func resolve(_ question: String, previous: String?) -> FollowUpRetrieval {
        FollowUpRetrieval.resolve(question: question, previousQuestion: previous, courses: FollowUpFixture.courses)
    }

    // MARK: - The pure rule

    @Test("a question that names no course inherits the one the previous question named")
    func inheritsTheCourse() {
        let result = resolve(FollowUpFixture.followUp, previous: FollowUpFixture.first)
        #expect(result.course?.code == "CIS 2400")
    }

    @Test("a question that names its own course inherits neither the course nor the earlier words")
    func ownCourseInheritsNothing() {
        // Five words, so short enough to be concatenated if it inherited.
        let question = "what about the econ final?"
        let result = resolve(question, previous: FollowUpFixture.first)
        #expect(result.course?.code == "ECON 1")
        #expect(result.query == question)
    }

    @Test("a short question is searched as the earlier question followed by the new one")
    func shortQuestionConcatenates() {
        let result = resolve(FollowUpFixture.followUp, previous: FollowUpFixture.first)
        #expect(result.query == "What's the late policy in CIS 2400? and for the final?")
    }

    @Test("a longer question is searched on its own words but still inherits the course")
    func longQuestionDoesNotConcatenate() {
        let question = "what is the penalty for turning in the final project late"
        let result = resolve(question, previous: FollowUpFixture.first)
        #expect(result.query == question)
        #expect(result.course?.code == "CIS 2400")
    }

    @Test("six words concatenate and seven do not")
    func theLimitIsSixWords() {
        let six = "tell me about the final exam"
        let seven = "tell me about the final exam please"
        #expect(six.split(separator: " ").count == FollowUpRetrieval.shortQuestionWordLimit)
        #expect(resolve(six, previous: FollowUpFixture.first).query == "\(FollowUpFixture.first) \(six)")
        #expect(resolve(seven, previous: FollowUpFixture.first).query == seven)
    }

    @Test("with no previous question the result is the question and the course it names, and nothing else")
    func nilPreviousIsANoOp() {
        let plain = resolve(FollowUpFixture.followUp, previous: nil)
        #expect(plain.query == FollowUpFixture.followUp)
        #expect(plain.course == nil)

        let named = resolve("late policy in CIS 2400", previous: nil)
        #expect(named.query == "late policy in CIS 2400")
        #expect(named.course?.code == "CIS 2400")
    }

    @Test("a blank previous question counts as none")
    func blankPreviousIsANoOp() {
        let result = resolve(FollowUpFixture.followUp, previous: "  \n ")
        #expect(result.query == FollowUpFixture.followUp)
        #expect(result.course == nil)
    }

    @Test("a previous question that named no course lends its words to a short follow-up, but no scope")
    func previousWithoutACourseLendsNoScope() {
        let result = resolve(FollowUpFixture.followUp, previous: "what is the late policy?")
        #expect(result.course == nil)
        #expect(result.query == "what is the late policy? and for the final?")
    }

    // MARK: - Backend path, on fixtures

    private func courses(in excerpts: String) -> Set<String> {
        let found = FollowUpFixture.courses.map(\.code).filter { excerpts.contains($0) }
        return Set(found)
    }

    @Test("alone, the follow-up's own words reach the course with the stronger matches")
    func followUpAloneGoesToTheStrongerCourse() {
        // The control for the tests below: without a previous question the
        // fixture really does send "and for the final?" to ECON 1.
        let excerpts = BackendAssistantResponder.retrievedExcerpts(
            question: FollowUpFixture.followUp,
            context: FollowUpFixture.assistantContext(previous: nil)
        )
        #expect(courses(in: excerpts).contains("ECON 1"))
    }

    @Test("a short follow-up retrieves from the earlier course even though another course matches its words better")
    func backendFollowUpStaysInTheEarlierCourse() {
        let excerpts = BackendAssistantResponder.retrievedExcerpts(
            question: FollowUpFixture.followUp,
            context: FollowUpFixture.assistantContext(previous: FollowUpFixture.first)
        )
        #expect(excerpts.contains("cumulative final"))
        #expect(courses(in: excerpts) == ["CIS 2400"])
    }

    @Test("a follow-up that names another course is not pulled back to the earlier one")
    func backendFollowUpNamingAnotherCourse() {
        let excerpts = BackendAssistantResponder.retrievedExcerpts(
            question: "and the final for econ?",
            context: FollowUpFixture.assistantContext(previous: FollowUpFixture.first)
        )
        #expect(courses(in: excerpts) == ["ECON 1"])
    }

    // MARK: - On-device path, on fixtures

    @Test("the on-device answerer also holds a short follow-up in the earlier course")
    func onDeviceFollowUpStaysInTheEarlierCourse() {
        let answer = ClassQuestionAnswerer(context: FollowUpFixture.knowledgeContext(previous: FollowUpFixture.first)).answer(FollowUpFixture.followUp)
        // The follow-up has to reach the retrieval path for this to test it.
        #expect(answer.question.intent == .lookup(query: FollowUpFixture.followUp))
        #expect(!answer.sources.isEmpty)
        #expect(answer.sources.allSatisfy { $0.course == "CIS 2400" })
        #expect(answer.text.contains("cumulative final"))
    }

    @Test("on-device, the same follow-up asked cold reaches the other course")
    func onDeviceFollowUpAloneGoesToTheStrongerCourse() {
        let answer = ClassQuestionAnswerer(context: FollowUpFixture.knowledgeContext(previous: nil)).answer(FollowUpFixture.followUp)
        #expect(answer.sources.contains { $0.course == "ECON 1" })
    }

    @Test("the on-device responder passes the previous question through to retrieval")
    func onDeviceResponderCarriesThePreviousQuestion() async {
        let responder = OnDeviceAssistantResponder(wordDelay: 0)
        var citations: [AssistantCitation] = []
        for await chunk in responder.reply(to: FollowUpFixture.followUp, context: FollowUpFixture.assistantContext(previous: FollowUpFixture.first)) {
            if case let .citations(list) = chunk { citations = list }
        }
        #expect(!citations.isEmpty)
        #expect(citations.allSatisfy { $0.course == "CIS 2400" })
    }

    @Test("a structured answer is not scoped by the previous question")
    func structuredAnswersIgnoreThePreviousQuestion() {
        // "what's due this week?" right after a CIS 2400 question still lists
        // every course: only retrieval borrows the earlier question's course.
        let cold = ClassQuestionAnswerer(context: FollowUpFixture.knowledgeContext(previous: nil, items: AssistantFixture.items, knowledge: AssistantFixture.knowledge))
            .answer("What's due this week?")
        let afterCIS = ClassQuestionAnswerer(context: FollowUpFixture.knowledgeContext(previous: FollowUpFixture.first, items: AssistantFixture.items, knowledge: AssistantFixture.knowledge))
            .answer("What's due this week?")
        #expect(afterCIS.text == cold.text)
        #expect(afterCIS.text.contains("ECON 1"))
    }
}

// MARK: - A chain of fragments

/// "late policy in CIS 2400?" -> "and for the final?" -> "what about the
/// midterm?". The third question's immediate predecessor names no course, so
/// the scope has to reach back past it. The scope looks back through the
/// earlier questions; the words of the search never do (only the previous
/// question is concatenated).
@Suite("Follow-up chains")
struct FollowUpChainTests {
    private func resolve(_ question: String, previous: String?, older: [String]) -> FollowUpRetrieval {
        FollowUpRetrieval.resolve(question: question, previousQuestion: previous, olderQuestions: older, courses: FollowUpFixture.courses)
    }

    // Questions that name no course, to stand between a course and the present.
    private static let fillers = ["and the quiz?", "what about labs?", "how about homework?"]

    // MARK: The pure rule

    @Test("a course named two questions back is inherited through a question that named none")
    func inheritsThroughTheChain() {
        let result = resolve(FollowUpFixture.midterm, previous: FollowUpFixture.followUp, older: [FollowUpFixture.first])
        #expect(result.course?.code == "CIS 2400")
    }

    @Test("the search words are still only the immediately previous question's, not the whole chain's")
    func onlyThePreviousQuestionIsConcatenated() {
        let result = resolve(FollowUpFixture.midterm, previous: FollowUpFixture.followUp, older: [FollowUpFixture.first])
        #expect(result.query == "and for the final? what about the midterm?")
    }

    @Test("a long question inherits the chain's course and is searched on its own words")
    func longQuestionInheritsButDoesNotConcatenate() {
        let question = "what is the penalty for turning in the final project late"
        let result = resolve(question, previous: FollowUpFixture.followUp, older: [FollowUpFixture.first])
        #expect(result.course?.code == "CIS 2400")
        #expect(result.query == question)
    }

    @Test("a different course named one question back overrides the one named two back")
    func nearerCourseWins() {
        let econNearer = resolve(FollowUpFixture.midterm, previous: "and the econ final?", older: [FollowUpFixture.first])
        #expect(econNearer.course?.code == "ECON 1")
        // And the other way round, so it is recency and not course order.
        let cisNearer = resolve(FollowUpFixture.midterm, previous: FollowUpFixture.first, older: ["and the econ final?"])
        #expect(cisNearer.course?.code == "CIS 2400")
    }

    @Test("the fourth earlier question still counts and the fifth does not")
    func lookBackStopsAtFour() {
        // previous + three older = four earlier questions.
        let fourthBack = resolve(FollowUpFixture.midterm, previous: Self.fillers[0], older: [Self.fillers[1], Self.fillers[2], FollowUpFixture.first])
        #expect(fourthBack.course?.code == "CIS 2400")
        // previous + four older: the course is five back.
        let fifthBack = resolve(FollowUpFixture.midterm, previous: Self.fillers[0], older: [Self.fillers[1], Self.fillers[2], "and the project?", FollowUpFixture.first])
        #expect(fifthBack.course == nil)
        #expect(FollowUpRetrieval.maxEarlierQuestions == 4)
    }

    @Test("a question that names its own course inherits nothing from the chain either")
    func ownCourseIgnoresTheChain() {
        let question = "what about the econ midterm?"
        let result = resolve(question, previous: FollowUpFixture.followUp, older: [FollowUpFixture.first])
        #expect(result.course?.code == "ECON 1")
        #expect(result.query == question)
    }

    @Test("no older questions means exactly the single-previous-question behaviour")
    func noOlderQuestionsChangesNothing() {
        let single = FollowUpRetrieval.resolve(question: FollowUpFixture.followUp, previousQuestion: FollowUpFixture.first, courses: FollowUpFixture.courses)
        let withEmpty = resolve(FollowUpFixture.followUp, previous: FollowUpFixture.first, older: [])
        #expect(single == withEmpty)
    }

    // MARK: Backend path

    @Test("backend: the third question of the chain stays in the first question's course")
    func backendChainStaysInTheCourse() {
        let context = FollowUpFixture.assistantContext(previous: FollowUpFixture.followUp, older: [FollowUpFixture.first])
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: FollowUpFixture.midterm, context: context)
        #expect(excerpts.contains("cumulative final"))
        #expect(FollowUpFixture.courses(in: excerpts) == ["CIS 2400"])
    }

    @Test("backend: without the older question the same third question leaks to the stronger course")
    func backendChainWithoutTheOlderQuestionLeaks() {
        // The control: this is what the single-previous-question rule did.
        let context = FollowUpFixture.assistantContext(previous: FollowUpFixture.followUp)
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: FollowUpFixture.midterm, context: context)
        #expect(FollowUpFixture.courses(in: excerpts).contains("ECON 1"))
    }

    @Test("backend: a nearer course overrides an older one")
    func backendNearerCourseWins() {
        let context = FollowUpFixture.assistantContext(previous: "and the econ final?", older: [FollowUpFixture.first])
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: FollowUpFixture.midterm, context: context)
        #expect(FollowUpFixture.courses(in: excerpts) == ["ECON 1"])
    }

    @Test("backend: a course five questions back is not inherited")
    func backendFifthBackIsForgotten() {
        let context = FollowUpFixture.assistantContext(
            previous: Self.fillers[0],
            older: [Self.fillers[1], Self.fillers[2], "and the project?", FollowUpFixture.first]
        )
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "and for the final?", context: context)
        #expect(FollowUpFixture.courses(in: excerpts).contains("ECON 1"))
    }

    // MARK: On-device path

    @Test("on-device: the third question of the chain stays in the first question's course")
    func onDeviceChainStaysInTheCourse() {
        let context = FollowUpFixture.knowledgeContext(previous: FollowUpFixture.followUp, older: [FollowUpFixture.first])
        let answer = ClassQuestionAnswerer(context: context).answer(FollowUpFixture.midterm)
        #expect(answer.question.intent == .lookup(query: FollowUpFixture.midterm))
        #expect(!answer.sources.isEmpty)
        #expect(answer.sources.allSatisfy { $0.course == "CIS 2400" })
    }

    @Test("on-device: without the older question it leaks to the stronger course")
    func onDeviceChainWithoutTheOlderQuestionLeaks() {
        let context = FollowUpFixture.knowledgeContext(previous: FollowUpFixture.followUp)
        let answer = ClassQuestionAnswerer(context: context).answer(FollowUpFixture.midterm)
        #expect(answer.sources.contains { $0.course == "ECON 1" })
    }

    @Test("on-device: a course five questions back is not inherited")
    func onDeviceFifthBackIsForgotten() {
        let context = FollowUpFixture.knowledgeContext(
            previous: Self.fillers[0],
            older: [Self.fillers[1], Self.fillers[2], "and the project?", FollowUpFixture.first]
        )
        let answer = ClassQuestionAnswerer(context: context).answer(FollowUpFixture.followUp)
        #expect(answer.sources.contains { $0.course == "ECON 1" })
    }

    @Test("the on-device responder passes the older questions through to retrieval")
    func onDeviceResponderCarriesTheOlderQuestions() async {
        let responder = OnDeviceAssistantResponder(wordDelay: 0)
        var citations: [AssistantCitation] = []
        let context = FollowUpFixture.assistantContext(previous: FollowUpFixture.followUp, older: [FollowUpFixture.first])
        for await chunk in responder.reply(to: FollowUpFixture.midterm, context: context) {
            if case let .citations(list) = chunk { citations = list }
        }
        #expect(!citations.isEmpty)
        #expect(citations.allSatisfy { $0.course == "CIS 2400" })
    }

    // MARK: The wire

    @Test("none of the earlier questions' words reach the encoded request, and history stays empty")
    func earlierQuestionsNeverEncoded() throws {
        let context = FollowUpFixture.assistantContext(
            previous: "and for the zxqvtwo final?",
            older: ["What's the zxqvone late policy in CIS 2400?", "tell me zxqvthree about labs"]
        )
        let request = BackendAssistantResponder.makeRequest(question: FollowUpFixture.midterm, context: context)
        #expect(request.question == FollowUpFixture.midterm)
        #expect(request.history.isEmpty)
        #expect(request.contextDocument == "doc")
        let json = try String(data: JSONEncoder().encode(request), encoding: .utf8) ?? ""
        #expect(!json.isEmpty)
        for marker in ["zxqvone", "zxqvtwo", "zxqvthree"] {
            #expect(!json.contains(marker), "\(marker) reached the wire")
        }
    }
}

// MARK: - Where the previous question comes from

/// `AssistantConversation.send` owns the transcript, so it is what attaches
/// the earlier question to each turn's context. These drive it with a
/// responder that records what it was handed.
@Suite("Previous question plumbing")
@MainActor
struct PreviousQuestionPlumbingTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String?] = []
        private var storedOlder: [[String]] = []
        func record(_ question: String?, older: [String]) {
            lock.lock(); stored.append(question); storedOlder.append(older); lock.unlock()
        }
        /// The previous question each reply was handed.
        var all: [String?] { lock.lock(); defer { lock.unlock() }; return stored }
        /// The older questions each reply was handed.
        var older: [[String]] { lock.lock(); defer { lock.unlock() }; return storedOlder }
    }

    private struct RecordingResponder: AssistantResponder {
        let recorder: Recorder
        func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk> {
            recorder.record(context.previousQuestion, older: context.olderQuestions)
            return AsyncStream { continuation in
                continuation.yield(.text("an answer that must never be mistaken for a question"))
                continuation.finish()
            }
        }
    }

    /// Sends and waits for the reply to finish, so the next send is accepted.
    private func ask(_ conversation: AssistantConversation, _ question: String, context: AssistantContext = AssistantContext(courseCodes: [])) async {
        conversation.send(question, context: context)
        for _ in 0..<600 {
            if !conversation.isResponding { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("the reply to \"\(question)\" never finished")
    }

    @Test("the first question has no previous one, and the second is handed the first as typed")
    func firstThenSecond() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        await ask(conversation, "  What's the late policy in CIS 2400?  ")
        await ask(conversation, "and for the final?")
        #expect(recorder.all == [nil, "What's the late policy in CIS 2400?"])
    }

    @Test("it is the most recent student question each time, never an answer")
    func mostRecentQuestion() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        await ask(conversation, "one")
        await ask(conversation, "two")
        await ask(conversation, "three")
        #expect(recorder.all == [nil, "one", "two"])
    }

    @Test("starting a new conversation forgets the old questions")
    func clearForgets() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        await ask(conversation, "one")
        conversation.clear()
        await ask(conversation, "two")
        #expect(recorder.all == [nil, nil])
    }

    @Test("a value the caller put in the context is replaced by the transcript's")
    func callerValueIsReplaced() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        var stale = AssistantContext(courseCodes: [])
        stale.previousQuestion = "a question from some other conversation"
        await ask(conversation, "one", context: stale)
        #expect(recorder.all == [nil])
    }

    // MARK: Older questions

    @Test("older questions are the earlier student questions, newest first, and empty for the first two turns")
    func olderQuestionsNewestFirst() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        for question in ["one", "two", "three", "four"] { await ask(conversation, question) }
        #expect(recorder.all == [nil, "one", "two", "three"])
        #expect(recorder.older == [[], [], ["one"], ["two", "one"]])
    }

    @Test("at most four earlier questions are handed over, the previous one included")
    func cappedAtFourEarlierQuestions() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        for question in ["one", "two", "three", "four", "five", "six", "seven"] { await ask(conversation, question) }
        // The seventh question sees six, five, four and three; one and two are out of reach.
        #expect(recorder.all.last == "six")
        #expect(recorder.older.last == ["five", "four", "three"])
    }

    @Test("starting a new conversation forgets the older questions too")
    func clearForgetsOlderQuestions() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        for question in ["one", "two", "three"] { await ask(conversation, question) }
        conversation.clear()
        await ask(conversation, "four")
        #expect(recorder.all.last == .some(nil))
        #expect(recorder.older.last == [])
    }

    @Test("older questions a caller put in the context are replaced by the transcript's")
    func callerOlderQuestionsAreReplaced() async {
        let recorder = Recorder()
        let conversation = AssistantConversation(responder: RecordingResponder(recorder: recorder))
        var stale = AssistantContext(courseCodes: [])
        stale.olderQuestions = ["a question from some other conversation"]
        await ask(conversation, "one", context: stale)
        #expect(recorder.older == [[]])
    }

    // MARK: The three-turn chain, through the conversation

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AskRequest] = []
        func record(_ request: AskRequest) { lock.lock(); stored.append(request); lock.unlock() }
        var all: [AskRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Builds each turn's real backend request from the context the
    /// conversation hands it, which is everything `BackendAssistantResponder`
    /// does short of opening a connection.
    private struct RequestBuildingResponder: AssistantResponder {
        let box: RequestBox
        func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk> {
            box.record(BackendAssistantResponder.makeRequest(question: prompt, context: context))
            return AsyncStream { continuation in
                continuation.yield(.text("ok"))
                continuation.finish()
            }
        }
    }

    @Test("backend: typing the three-turn chain keeps the third request in CIS 2400 and puts no earlier question on the wire")
    func backendChainThroughTheConversation() async throws {
        let box = RequestBox()
        let conversation = AssistantConversation(responder: RequestBuildingResponder(box: box))
        let context = FollowUpFixture.assistantContext(previous: nil)
        await ask(conversation, "What's the zxqvone late policy in CIS 2400?", context: context)
        await ask(conversation, "and for the zxqvtwo final?", context: context)
        await ask(conversation, FollowUpFixture.midterm, context: context)

        let third = try #require(box.all.last)
        #expect(box.all.count == 3)
        #expect(FollowUpFixture.courses(in: third.excerpts) == ["CIS 2400"])
        #expect(third.question == FollowUpFixture.midterm)
        #expect(third.history.isEmpty)
        let json = try String(data: JSONEncoder().encode(third), encoding: .utf8) ?? ""
        #expect(!json.contains("zxqvone") && !json.contains("zxqvtwo"))
    }

    @Test("on-device: typing the three-turn chain keeps the third answer in CIS 2400")
    func onDeviceChainThroughTheConversation() async {
        let conversation = AssistantConversation(responder: OnDeviceAssistantResponder(wordDelay: 0))
        let context = FollowUpFixture.assistantContext(previous: nil)
        await ask(conversation, FollowUpFixture.first, context: context)
        await ask(conversation, FollowUpFixture.followUp, context: context)
        await ask(conversation, FollowUpFixture.midterm, context: context)

        let citations = conversation.messages.last?.citations ?? []
        #expect(!citations.isEmpty)
        #expect(citations.allSatisfy { $0.course == "CIS 2400" })
    }
}
