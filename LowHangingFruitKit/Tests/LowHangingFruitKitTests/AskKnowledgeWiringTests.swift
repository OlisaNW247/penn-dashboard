import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// How the knowledge engine plugs into Marco's `ask`: the no-key responder
/// streams a grounded answer with citations, and the Claude responder sends
/// retrieved passages after the cache breakpoint without disturbing the
/// cached document.
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

    @Test("Claude request carries retrieved excerpts in the user turn, not the cached document")
    func claudeExcerpts() throws {
        let body = ClaudeAssistantResponder.buildRequestBody(question: "What's the late policy in CIS 2400?", context: Self.context)
        let data = try JSONEncoder().encode(body)
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let system = try #require(dict["system"] as? [[String: Any]])
        #expect(system.count == 2)
        #expect(system[1]["text"] as? String == "doc")   // untouched cache prefix
        let messages = try #require(dict["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? String)
        #expect(content.hasPrefix("Current date: "))
        #expect(content.contains("RETRIEVED EXCERPTS"))
        #expect(content.contains("three late days"))
        #expect(content.contains("QUESTION: What's the late policy in CIS 2400?"))
        #expect(!content.contains("ECON 1 syllabus"))   // course filter applied
    }

    @Test("Claude user turn is unchanged when nothing is synced")
    func claudeNoExcerpts() {
        let context = AssistantContext(courseCodes: ["PHYS 0151"], contextDocument: "doc", askedAt: AssistantFixture.now)
        let excerpts = ClaudeAssistantResponder.retrievedExcerpts(question: "attendance policy", context: context)
        #expect(excerpts.isEmpty)
        let content = ClaudeAssistantResponder.userContent(question: "q", askedAt: AssistantFixture.now)
        #expect(content.hasSuffix("\n\nq"))
        #expect(!content.contains("QUESTION:"))
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
