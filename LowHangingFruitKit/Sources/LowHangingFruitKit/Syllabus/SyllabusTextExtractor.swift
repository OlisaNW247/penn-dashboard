import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Turns the shapes a syllabus arrives in — Canvas HTML, a PDF, plain pasted
/// text — into the line-structured plain text `SyllabusParser` reads.
///
/// The structure matters as much as the words: a grading table is only
/// parseable if each row survives as one line, so HTML block and cell
/// boundaries become newlines and separators rather than being flattened away
/// with the rest of the markup.
public enum SyllabusTextExtractor {
    public static func text(fromHTML html: String) -> String {
        var s = html

        // Scripts and styles carry braces and percent signs that read as
        // grading tables to a regex.
        s = s.replacingOccurrences(of: #"<script\b[^>]*>[\s\S]*?</script>"#, with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<style\b[^>]*>[\s\S]*?</style>"#, with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: " ", options: .regularExpression)

        // Cell boundaries become a separator so "<td>Homework</td><td>30%</td>"
        // stays one line and still has a gap between name and weight.
        s = s.replacingOccurrences(of: #"</t[dh]>"#, with: " \t ",
                                   options: [.regularExpression, .caseInsensitive])
        // Block boundaries become line breaks.
        s = s.replacingOccurrences(of: #"<(br|/tr|/p|/div|/li|/h[1-6]|/table)\b[^>]*>"#, with: "\n",
                                   options: [.regularExpression, .caseInsensitive])

        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return SyllabusParser.normalizedText(s)
    }

    /// Extracts text from a PDF's pages. Returns nil for image-only scans —
    /// nothing to read, and the caller should say so rather than show an empty
    /// "no weights found" result.
    public static func text(fromPDF data: Data) -> String? {
#if canImport(PDFKit)
        guard let document = PDFDocument(data: data) else { return nil }
        var pages: [String] = []
        // A syllabus's grading section is always near the front; this also
        // keeps a 200-page course packet from being walked in full.
        for index in 0..<min(document.pageCount, 20) {
            guard let page = document.page(at: index), let text = page.string else { continue }
            pages.append(text)
        }
        let joined = pages.joined(separator: "\n")
        let normalized = SyllabusParser.normalizedText(joined)
        return normalized.isEmpty ? nil : normalized
#else
        return nil
#endif
    }

    public static func text(fromPasted raw: String) -> String {
        SyllabusParser.normalizedText(raw)
    }

    private static func decodeEntities(_ raw: String) -> String {
        var s = raw
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&ldquo;", "\""), ("&rdquo;", "\""), ("&ndash;", "-"), ("&mdash;", "-"),
            ("&percnt;", "%"), ("&ge;", "\u{2265}"),
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric entities (&#8211; and friends).
        s = s.replacingOccurrences(of: #"&#\d+;"#, with: " ", options: .regularExpression)
        return s
    }
}
