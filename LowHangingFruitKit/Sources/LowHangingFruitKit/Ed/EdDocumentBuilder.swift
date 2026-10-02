import Foundation

/// Builds the strings of a pooled course document from a kept Ed thread.
/// Deliberately strings only: the `CourseDocument` itself is assembled where
/// the other course sources are, so this file has no opinion about the
/// upload type and a change to that type cannot break it.
public enum EdDocumentBuilder {
    /// The `kind` Ed documents are filed under, beside "syllabus", "page" and
    /// the rest.
    public static let kind = "ed"

    /// The document's id within its course: Ed's global thread id. Stable
    /// across edits, so a re-synced thread replaces its old copy.
    public static func sourceID(for thread: EdThread) -> String {
        String(thread.id)
    }

    /// The thread title, or a stand-in so a document is never untitled.
    public static func title(for thread: EdThread) -> String {
        let trimmed = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Ed thread #\(thread.number ?? thread.id)"
    }

    /// A one-line header, then the body as plain text.
    ///
    /// The header, `[ed · pinned] Homework / Hw 3`, tells a model reading an
    /// excerpt where it came from and how much to trust it ("announcement"
    /// outranks a pinned FAQ), and puts the category words into the keyword
    /// index. It never names the author. The body is the XML `document`; the
    /// older `content` field is only a fallback, for a thread whose document
    /// is missing or comes out empty.
    public static func text(for thread: EdThread, decision: EdThreadDecision) -> String {
        var header = "[ed · \(decision.reason)]"
        if let category = nonEmpty(thread.category) {
            header += " " + category
            if let subcategory = nonEmpty(thread.subcategory) {
                header += " / " + subcategory
            }
        }

        var body = ""
        if let document = thread.document {
            body = EdDocumentText.plainText(fromDocument: document)
        }
        if body.isEmpty, let content = thread.content {
            body = EdDocumentText.strippingTags(content)
        }
        return body.isEmpty ? header : header + "\n" + body
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
