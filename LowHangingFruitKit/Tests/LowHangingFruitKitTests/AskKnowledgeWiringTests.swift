import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// How the knowledge engine plugs into Marco's `ask`: the no-backend
/// responder streams a grounded answer with citations, and the backend
/// responder sends retrieved passages as a separate request field, after the
/// cache breakpoint, without disturbing the cached document.
@Suite("Ask knowledge wiring")
struct AskKnowledgeWiringTests {
    private static var context: AssistantContext {
        AssistantContext(
            courseCodes: AssistantFixture.courses.map(\.code),
            contextDocument: "doc",
            askedAt: AssistantFixture.now,
            knowledge: AssistantFixture.knowledge,
            work: AssistantFixture.items,
            userName: "Olisa"
        )
    }

    private static func collect(_ stream: AsyncStream<AssistantChunk>) async -> (text: String, citations: [AssistantCitation]) {
        var text = ""
        var citations: [AssistantCitation] = []
        for await chunk in stream {
            switch chunk {
            case let .text(piece): text += piece
            case let .citations(list): citations = list
            }
        }
        return (text, citations)
    }

    @Test("on-device responder streams an exact answer with no network")
    func onDeviceExact() async {
        let responder = OnDeviceAssistantResponder(wordDelay: 0)
        let result = await Self.collect(responder.reply(to: "What's due this week?", context: Self.context))
        #expect(result.text.hasPrefix("4 things due in the next 7 days:"))
        #expect(result.text.contains("PSet 3: caches"))
    }

    @Test("on-device responder cites the syllabus it quoted")
    func onDeviceCitations() async {
        let responder = OnDeviceAssistantResponder(wordDelay: 0)
        let result = await Self.collect(responder.reply(to: "What's the late policy in CIS 2400?", context: Self.context))
        #expect(result.text.contains("three late days"))
        #expect(result.citations.first?.course == "CIS 2400")
        #expect(result.citations.first?.source == "syllabus")
        #expect(result.citations.first?.detail == "CIS 2400 syllabus")
    }

    @Test("backend request carries retrieved excerpts as a field separate from the cached document")
    func backendExcerpts() {
        let request = BackendAssistantResponder.makeRequest(question: "What's the late policy in CIS 2400?", context: Self.context)
        #expect(request.contextDocument == "doc")   // untouched cache prefix
        #expect(request.askedAt == AssistantFixture.now)
        #expect(request.excerpts.contains("three late days"))
        #expect(!request.excerpts.contains("ECON 1 syllabus"))   // course filter applied
    }

    @Test("excerpts field is empty when nothing is synced")
    func backendNoExcerpts() {
        let context = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "doc", askedAt: AssistantFixture.now)
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "attendance policy", context: context)
        #expect(excerpts.isEmpty)
    }

    @Test("question and excerpts travel as separate request fields; the server joins them")
    func questionAndExcerptsAreSeparateFields() {
        let request = BackendAssistantResponder.makeRequest(question: "What's the late policy in CIS 2400?", context: Self.context)
        #expect(request.question == "What's the late policy in CIS 2400?")
        #expect(!request.question.contains("RETRIEVED EXCERPTS"))
        #expect(!request.excerpts.contains("QUESTION:"))
    }

    @Test("sample knowledge answers the flagship policy question in preview mode")
    func sampleKnowledge() {
        let knowledge = SampleData.knowledge()
        let items = SampleData.items().map { WorkItem(assignment: $0.assignment, isCompleted: $0.isCompleted, dueOverride: $0.dueOverride) }
        let context = AskKnowledgeContext(items: items, knowledge: knowledge)
        let answer = ClassQuestionAnswerer(context: context).answer("what's my cis attendance policy?")
        #expect(answer.text.contains("two absences are free"))
        #expect(answer.sources.first?.title == "CIS 1210 syllabus")
    }
}
