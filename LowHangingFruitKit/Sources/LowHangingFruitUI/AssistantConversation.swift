import Foundation
import SwiftUI

/// One turn in the conversation.
struct AssistantMessage: Identifiable, Sendable {
    enum Role: Sendable { case student, assistant }

    let id = UUID()
    var role: Role
    var text: String
    var citations: [AssistantCitation] = []
    /// True from the moment the placeholder is appended until the stream
    /// finishes. The view uses it for the thinking indicator and for the
    /// caret at the end of the text, and — importantly — to keep the citation
    /// chips hidden until the answer has actually landed.
    var isStreaming: Bool = false
}

/// Holds the transcript and drives one responder.
///
/// Everything here is main-actor: it exists to be read by SwiftUI, the
/// transcript is small, and the only work of any duration is awaiting a
/// stream, which suspends rather than blocks. Hopping actors to append
/// strings to an array a view is observing would buy nothing and cost the
/// guarantee that a partial answer is never seen half-applied.
@MainActor
final class AssistantConversation: ObservableObject {
    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var isResponding = false

    /// True until the student sends anything. The screen keys its whole
    /// layout off this — branch at full strength and suggestions on show
    /// before, transcript over a faded branch after.
    var isFresh: Bool { messages.isEmpty }

    private let responder: AssistantResponder
    private var inFlight: Task<Void, Never>?

    init(responder: AssistantResponder = ScriptedAssistantResponder()) {
        self.responder = responder
    }

    func send(_ prompt: String, context: AssistantContext) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        messages.append(AssistantMessage(role: .student, text: trimmed))
        messages.append(AssistantMessage(role: .assistant, text: "", isStreaming: true))
        isResponding = true

        let index = messages.count - 1
        inFlight = Task { [responder] in
            for await chunk in responder.reply(to: trimmed, context: context) {
                guard !Task.isCancelled, messages.indices.contains(index) else { break }
                switch chunk {
                case let .text(piece):
                    messages[index].text += piece
                case let .citations(list):
                    messages[index].citations = list
                }
            }
            if messages.indices.contains(index) {
                messages[index].isStreaming = false
            }
            isResponding = false
        }
    }

    /// Abandons the answer in progress and leaves whatever arrived on screen —
    /// a stop control, not an undo. Deleting the partial text would throw away
    /// something the student may already have read.
    func stop() {
        inFlight?.cancel()
        inFlight = nil
        if let last = messages.indices.last {
            messages[last].isStreaming = false
        }
        isResponding = false
    }

    func clear() {
        inFlight?.cancel()
        inFlight = nil
        messages.removeAll()
        isResponding = false
    }
}
