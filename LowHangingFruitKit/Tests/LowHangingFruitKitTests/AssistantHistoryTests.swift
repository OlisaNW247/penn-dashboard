import Foundation
import Testing
@testable import LowHangingFruitUI

@MainActor
@Suite("Assistant chat history")
struct AssistantHistoryTests {
    private struct WaitingResponder: AssistantResponder {
        func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk> {
            AsyncStream { _ in }
        }
    }

    @Test("History survives relaunch with message IDs and source URLs intact")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantHistoryStore(directory: directory)
        let message = AssistantMessage(role: .assistant, text: "Due Friday", citations: [
            AssistantCitation(course: "CIS", source: "syllabus", detail: "Week 2", url: URL(string: "https://canvas.example.edu/courses/1/pages/syllabus"))
        ])
        let id = UUID()
        store.save(AssistantSavedChat(id: id, updatedAt: Date(), messages: [AssistantMessage(role: .student, text: "When is it due?"), message]))
        let restored = AssistantHistoryStore(directory: directory)
        #expect(restored.chats.count == 1)
        #expect(restored.chats.first?.id == id)
        #expect(restored.chats.first?.title == "When is it due?")
        #expect(restored.chats.first?.messages.last?.id == message.id)
        #expect(restored.chats.first?.messages.last?.citations == message.citations)
        #expect(restored.errorMessage == nil)
    }

    @Test("New chat archives the old one and reopening continues the same saved conversation")
    func switchingChats() async {
        let store = AssistantHistoryStore()
        let conversation = AssistantConversation(responder: WaitingResponder(), history: store)
        conversation.send("First question", context: AssistantContext(courseCodes: []))
        conversation.clear()
        let first = store.chats[0]
        #expect(conversation.isFresh)
        conversation.send("Second question", context: AssistantContext(courseCodes: []))
        conversation.open(first)
        #expect(store.chats.count == 2)
        #expect(conversation.messages.first?.text == "First question")
        #expect(!conversation.isResponding)
        let hasStreamingMessage = conversation.messages.contains { $0.isStreaming }
        #expect(!hasStreamingMessage)
        conversation.send("Follow-up", context: AssistantContext(courseCodes: []))
        await Task.yield()
        // A cancelled prior stream must not turn off the new answer.
        #expect(conversation.isResponding)
        conversation.stop()
        #expect(store.chats.count == 2)
        #expect(store.chats.first?.id == first.id)
        #expect(store.chats.first?.messages.contains { $0.text == "Follow-up" } == true)
    }

    @Test("A malformed history file is preserved and valid chats remain available")
    func corruptFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AssistantHistoryStore(directory: directory)
        store.save(AssistantSavedChat(id: UUID(), updatedAt: Date(), messages: [AssistantMessage(role: .student, text: "Keep me")]))
        let broken = directory.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: broken)
        let restored = AssistantHistoryStore(directory: directory)
        #expect(restored.chats.count == 1)
        #expect(restored.errorMessage != nil)
        #expect(try String(contentsOf: broken, encoding: .utf8) == "broken")
    }
}
