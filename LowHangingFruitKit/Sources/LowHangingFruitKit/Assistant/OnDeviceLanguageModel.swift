import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Thin wrapper over Apple's on-device language model (Foundation Models
/// framework, iOS 26 / macOS 26, Apple Intelligence devices). No API key, no
/// network: the model runs on the phone. Older devices, or builds made with an
/// older SDK, report `isAvailable == false` and the deterministic answer is
/// shown as-is.
///
/// The model is only ever asked to *rephrase grounded facts*. It never sees a
/// question without the retrieved passages and the deterministic draft, and
/// exact answers (dates, counts, lists) bypass it entirely.
public enum OnDeviceLanguageModel {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why the model can't run, for a Settings footnote. Nil when available.
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case let .unavailable(reason):
                return String(describing: reason)
            }
        }
        return "Requires iOS 26 or macOS 26."
        #else
        return "Not included in this build."
        #endif
    }

    static let instructions = """
    You are LHF's class assistant for a university student. Rewrite the DRAFT ANSWER into a short, \
    friendly reply using only the facts in the DRAFT ANSWER and SOURCE PASSAGES. Rules: lead with the \
    answer in the first sentence; keep every date, time, number, and course code exactly as written; \
    never add facts that are not in the sources; if the sources do not answer the question, say you \
    couldn't find it in the course materials; no greetings, no sign-offs; at most 90 words.
    """

    /// Returns a rephrased answer, or nil when the model is unavailable, the
    /// answer is exact, or generation fails for any reason (guardrails, context
    /// size). Callers always keep the deterministic text as the fallback.
    public static func compose(question: String, answer: AssistantAnswer) async -> String? {
        guard !answer.isExact, !answer.grounding.isEmpty else { return nil }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *), isAvailable else { return nil }
        let prompt = buildPrompt(question: question, answer: answer)
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return validated(text, against: answer)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Keeps the prompt well inside the on-device model's ~4K-token window:
    /// three passages, each trimmed, plus the draft.
    static func buildPrompt(question: String, answer: AssistantAnswer) -> String {
        var lines = ["QUESTION: \(question)", "", "DRAFT ANSWER:", answer.text, "", "SOURCE PASSAGES:"]
        for (index, hit) in answer.grounding.prefix(3).enumerated() {
            let body = String(hit.passage.text.prefix(700)).replacingOccurrences(of: "\n", with: " ")
            lines.append("[\(index + 1)] \(hit.document.course) \(hit.document.kind.label) \"\(hit.document.title)\": \(body)")
        }
        return lines.joined(separator: "\n")
    }

    /// Rejects rewrites that drop or invent dates/numbers relative to the draft
    /// and its sources. Cheap insurance against a small model getting creative.
    static func validated(_ text: String, against answer: AssistantAnswer) -> String? {
        guard text.count >= 12, text.count <= 900 else { return nil }
        let allowed = Set(numbers(in: answer.text + " " + answer.grounding.map(\.passage.text).joined(separator: " ")))
        let produced = Set(numbers(in: text))
        guard produced.isSubset(of: allowed) else { return nil }
        return text
    }

    static func numbers(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:[:.]\d+)?"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}

/// The entry point the UI calls: deterministic answer first, on-device model
/// polish when it's available and the answer isn't exact.
public struct ClassAssistant: Sendable {
    public let context: AskKnowledgeContext

    public init(context: AskKnowledgeContext) {
        self.context = context
    }

    public func respond(to question: String) async -> AssistantAnswer {
        let draft = ClassQuestionAnswerer(context: context).answer(question)
        guard let polished = await OnDeviceLanguageModel.compose(question: question, answer: draft) else {
            return draft
        }
        return AssistantAnswer(text: polished, sources: draft.sources, question: draft.question, grounding: draft.grounding, isExact: false)
    }
}
