import Foundation

/// A searchable slice of a `CourseDocument`. Documents are split so that a
/// hit points at the few sentences that answer the question, and so that
/// what we hand a small on-device model stays within its context window.
public struct Passage: Sendable, Hashable, Identifiable {
    public let id: String
    public let documentID: String
    public let ordinal: Int
    public let text: String

    public init(documentID: String, ordinal: Int, text: String) {
        self.id = "\(documentID)#\(ordinal)"
        self.documentID = documentID
        self.ordinal = ordinal
        self.text = text
    }
}

public enum PassageChunker {
    /// Target and hard-cap sizes in words. Paragraph boundaries are respected
    /// where possible; very long paragraphs are split on sentence boundaries.
    public static let targetWords = 160
    public static let maxWords = 220

    public static func passages(for document: CourseDocument) -> [Passage] {
        chunk(document.text).enumerated().map { index, text in
            Passage(documentID: document.id, ordinal: index, text: text)
        }
    }

    /// Splits plain text into word-budgeted chunks. Exposed for tests.
    public static func chunk(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0

        func flush() {
            if !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentWords = 0
            }
        }

        for paragraph in paragraphs {
            let words = wordCount(paragraph)
            if words > maxWords {
                flush()
                chunks.append(contentsOf: splitLongParagraph(paragraph))
                continue
            }
            if currentWords + words > targetWords, !current.isEmpty {
                flush()
            }
            current.append(paragraph)
            currentWords += words
        }
        flush()
        return chunks
    }

    private static func splitLongParagraph(_ paragraph: String) -> [String] {
        let sentences = paragraph
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0
        for sentence in sentences {
            let words = wordCount(sentence)
            if currentWords + words > targetWords, !current.isEmpty {
                chunks.append(current.joined(separator: ". ") + ".")
                current = []
                currentWords = 0
            }
            current.append(sentence)
            currentWords += words
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: ". ") + ".")
        }
        return chunks
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
