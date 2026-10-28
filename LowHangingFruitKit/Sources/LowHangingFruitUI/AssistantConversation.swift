import Foundation
import LowHangingFruitKit
import SwiftUI
import os

/// One turn in the conversation.
struct AssistantMessage: Identifiable, Sendable, Codable {
    enum Role: String, Sendable, Codable { case student, assistant }

    var id = UUID()
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
    private var requestID = UUID()
    private var chatID = UUID()
    private var lastSave = Date.distantPast
    private let history: AssistantHistoryStore?

    init(responder: AssistantResponder = ScriptedAssistantResponder(), history: AssistantHistoryStore? = nil) {
        self.responder = responder
        self.history = history
    }

    func send(_ prompt: String, context: AssistantContext) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        // The transcript is the only place that knows what was asked before
        // this, so the earlier questions are attached here, before the new
        // one is appended, rather than by each caller: the student's own
        // words only, newest first, never an answer, at most as many as
        // retrieval will look back through. They ride along only so
        // retrieval can follow a follow-up into the right course
        // (`FollowUpRetrieval`); no responder sends them anywhere. Whatever
        // the caller put in these fields is replaced: a stale value there
        // would search the wrong course.
        let turnContext: AssistantContext = {
            var copy = context
            let earlier = messages.reversed()
                .filter { $0.role == .student }
                .prefix(FollowUpRetrieval.maxEarlierQuestions)
                .map(\.text)
            copy.previousQuestion = earlier.first
            copy.olderQuestions = Array(earlier.dropFirst())
            return copy
        }()

        messages.append(AssistantMessage(role: .student, text: trimmed))
        messages.append(AssistantMessage(role: .assistant, text: "", isStreaming: true))
        isResponding = true

        saveToHistory()
        let currentRequest = UUID()
        requestID = currentRequest
        let index = messages.count - 1
        askTrace.info("0 send: consumer task starting")
        inFlight = Task { [responder] in
            for await chunk in responder.reply(to: trimmed, context: turnContext) {
                askTrace.info("8 chunk delivered to conversation")
                guard !Task.isCancelled, requestID == currentRequest, messages.indices.contains(index) else { break }
                switch chunk {
                case let .text(piece):
                    messages[index].text += piece
                case let .citations(list):
                    messages[index].citations = list
                }
                if Date().timeIntervalSince(lastSave) > 0.75 { saveToHistory() }
            }
            guard requestID == currentRequest else { return }
            askTrace.info("9 consumer loop ended")
            if messages.indices.contains(index) {
                messages[index].isStreaming = false
            }
            isResponding = false
            saveToHistory()
        }
    }

    /// Abandons the answer in progress and leaves whatever arrived on screen —
    /// a stop control, not an undo. Deleting the partial text would throw away
    /// something the student may already have read.
    func stop() {
        askTrace.info("S stop() called; cancelling the in-flight answer")
        requestID = UUID()
        inFlight?.cancel()
        inFlight = nil
        if let last = messages.indices.last {
            messages[last].isStreaming = false
        }
        isResponding = false
        saveToHistory()
    }

    func saveToHistory() {
        guard !messages.isEmpty else { return }
        history?.save(AssistantSavedChat(id: chatID, updatedAt: Date(), messages: messages))
        lastSave = Date()
    }

    func open(_ chat: AssistantSavedChat) {
        stop()
        chatID = chat.id
        messages = chat.messages.map { message in
            var copy = message
            copy.isStreaming = false
            return copy
        }
    }

    func clear() {
        stop()
        chatID = UUID()
        messages.removeAll()
        isResponding = false
    }
}
