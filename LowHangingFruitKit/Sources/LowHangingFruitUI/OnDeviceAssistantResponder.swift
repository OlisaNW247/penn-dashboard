import Foundation
import LowHangingFruitKit

/// The responder `ask` falls back to when LHF's backend is unconfigured,
/// unreachable, or over quota (`BackendAssistantResponder` delegates here),
/// and the only one under tests. Nothing here touches
/// the network: `ClassQuestionAnswerer` computes exact answers (what's due,
/// next exam, did I submit) from `context.work` and answers policy and
/// content questions by retrieval over `context.knowledge`; on iOS 26 /
/// macOS 26 devices with Apple Intelligence, Apple's on-device model
/// rephrases the retrieval answers and is skipped otherwise. Either way the
/// answer is grounded in the student's own Canvas data and carries citations.
///
/// This replaces `ScriptedAssistantResponder` at the call site. The scripted
/// stand-in stays for previews, where there is no data to answer from.
///
/// Streaming is kept even though the answer is computed in one piece, for
/// the reason `AssistantResponder.swift`'s header gives: the screen was
/// designed against incremental arrival, and a paragraph landing at once
/// reads as a glitch next to the Claude path.
struct OnDeviceAssistantResponder: AssistantResponder {
    /// Milliseconds between words — matches the scripted stand-in so the two
    /// no-network paths feel identical.
    var wordDelay: UInt64 = 22

    func reply(to prompt: String, context: AssistantContext) -> AsyncStream<AssistantChunk> {
        let delay = wordDelay
        let knowledgeContext = AskKnowledgeContext(
            userName: context.userName,
            now: context.askedAt,
            items: context.work,
            knowledge: context.knowledge
        )
        return AsyncStream { continuation in
            let task = Task {
                let answer = await ClassAssistant(context: knowledgeContext).respond(to: prompt)
                for word in answer.text.splittingKeepingSeparators() {
                    if Task.isCancelled { break }
                    continuation.yield(.text(word))
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                }
                let citations = Self.citations(for: answer.sources)
                if !citations.isEmpty, !Task.isCancelled {
                    continuation.yield(.citations(citations))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `SourceReference` → the chip the screen already knows how to draw.
    /// `source` is the material's kind ("syllabus", "announcement",
    /// "assignment"); `detail` is the document title so the student can find
    /// it on Canvas.
    static func citations(for sources: [SourceReference]) -> [AssistantCitation] {
        var seen: Set<String> = []
        return sources.compactMap { source in
            let citation = AssistantCitation(course: source.course, source: source.kind, detail: source.title)
            guard seen.insert(citation.id).inserted else { return nil }
            return citation
        }
    }
}
