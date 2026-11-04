import Foundation
import Testing
@testable import LowHangingFruitKit

/// The conversation the phone sends with a question (2026-11-02). Pure: no
/// UI, no network. The point of the cap is that a long chat does not make
/// every later question carry the whole session, and that a half-streamed
/// answer is never shown to the model as its own words.
@Suite("Conversation history for ask")
struct ConversationHistoryTests {
    private typealias Message = ConversationHistory.Message

    private static func student(_ text: String) -> Message { Message(role: .student, text: text) }
    private static func assistant(_ text: String, pending: Bool = false) -> Message {
        Message(role: .assistant, text: text, isPending: pending)
    }

    @Test("a student message is a user turn and an assistant message is an assistant turn, in order")
    func roleMapping() {
        let turns = ConversationHistory.turns(from: [Self.student("hi"), Self.assistant("hello")])
        #expect(turns == [AskTurn(role: "user", content: "hi"), AskTurn(role: "assistant", content: "hello")])
    }

    @Test("an empty transcript sends nothing")
    func emptyTranscript() {
        #expect(ConversationHistory.turns(from: []).isEmpty)
    }

    @Test("only the last six messages are kept, newest last")
    func capByMessages() {
        var messages: [Message] = []
        for index in 0..<5 {
            messages.append(Self.student("q\(index)"))
            messages.append(Self.assistant("a\(index)"))
        }
        let turns = ConversationHistory.turns(from: messages)
        #expect(turns.map(\.content) == ["q2", "a2", "q3", "a3", "q4", "a4"])
        #expect(turns.map(\.role) == ["user", "assistant", "user", "assistant", "user", "assistant"])
    }

    @Test("over the character cap, whole oldest turns go first and no turn is cut")
    func capByCharacters() {
        let a = String(repeating: "a", count: 100)
        let b = String(repeating: "b", count: 100)
        let c = String(repeating: "c", count: 100)
        let d = String(repeating: "d", count: 100)
        let messages = [Self.student(a), Self.assistant(b), Self.student(c), Self.assistant(d)]

        // 400 characters fit in 450: nothing is dropped.
        #expect(ConversationHistory.turns(from: messages, maxCharacters: 450).map(\.content) == [a, b, c, d])
        // 400 does not fit in 250: the two oldest turns go, whole.
        #expect(ConversationHistory.turns(from: messages, maxCharacters: 250).map(\.content) == [c, d])
        // Every kept turn is whole.
        #expect(ConversationHistory.turns(from: messages, maxCharacters: 250).allSatisfy { $0.content.count == 100 })
    }

    @Test("a history that would open on an assistant turn drops it")
    func noLeadingAssistant() {
        let a = String(repeating: "a", count: 100)
        let b = String(repeating: "b", count: 100)
        let c = String(repeating: "c", count: 100)
        let d = String(repeating: "d", count: 100)
        let messages = [Self.student(a), Self.assistant(b), Self.student(c), Self.assistant(d)]
        // 300 characters fit in 350 after the first turn goes, which would
        // leave b, a reply to a question the model is not shown.
        let turns = ConversationHistory.turns(from: messages, maxCharacters: 350)
        #expect(turns.map(\.content) == [c, d])
    }

    @Test("the newest turn is kept even when it alone is over the character cap")
    func newestTurnKept() {
        let long = String(repeating: "q", count: 500)
        let turns = ConversationHistory.turns(from: [Self.student(long)], maxCharacters: 100)
        #expect(turns.map(\.content) == [long])
    }

    @Test("a reply still streaming is skipped, and so is a reply with no text")
    func streamingAndEmptySkipped() {
        let streaming = ConversationHistory.turns(from: [
            Self.student("q1"), Self.assistant("a1"), Self.student("q2"), Self.assistant("half an ans", pending: true),
        ])
        #expect(streaming.map(\.content) == ["q1", "a1", "q2"])

        let empty = ConversationHistory.turns(from: [
            Self.student("q1"), Self.assistant("   \n"), Self.student("q2"), Self.assistant("a2"),
        ])
        #expect(empty.map(\.content) == ["q1", "q2", "a2"])
    }

    @Test("a cap of zero messages sends nothing")
    func zeroMessages() {
        #expect(ConversationHistory.turns(from: [Self.student("q")], maxMessages: 0).isEmpty)
    }
}
