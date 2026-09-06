import Foundation

/// Turns Canvas HTML (syllabus bodies, assignment descriptions, announcement
/// messages, wiki pages) into readable plain text. Block-level tags become line
/// breaks so paragraphs and list items survive as separate lines, which the
/// passage chunker relies on.
public enum HTMLText {
    public static func plainText(from html: String) -> String {
        var s = html

        s = replace(in: s, pattern: #"<script\b[^>]*>.*?</script>"#, with: " ")
        s = replace(in: s, pattern: #"<style\b[^>]*>.*?</style>"#, with: " ")
        s = replace(in: s, pattern: #"<!--.*?-->"#, with: " ")

        // Block boundaries → newline. `<br>` and closing block tags both count.
        s = replace(in: s, pattern: #"<br\s*/?>"#, with: "\n")
        s = replace(in: s, pattern: #"</(p|div|li|h[1-6]|tr|blockquote|section|article|header|footer|table|ul|ol|pre)\s*>"#, with: "\n")
        s = replace(in: s, pattern: #"<(li)\b[^>]*>"#, with: "\n• ")
        s = replace(in: s, pattern: #"<(td|th)\b[^>]*>"#, with: " ")

        // Everything else: drop the tag.
        s = replace(in: s, pattern: #"<[^>]+>"#, with: " ")

        s = decodeEntities(s)

        // Collapse runs of spaces/tabs, then one line per block (the chunker
        // treats every line as a paragraph, so blank lines add nothing).
        s = replace(in: s, pattern: #"[ \t\r\x{00A0}]+"#, with: " ")
        s = replace(in: s, pattern: #" *\n *"#, with: "\n")
        s = replace(in: s, pattern: #"\n{2,}"#, with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes the named entities Canvas actually emits plus numeric forms.
    public static func decodeEntities(_ text: String) -> String {
        var s = text
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&ndash;", "–"), ("&mdash;", "—"),
            ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&rdquo;", "”"), ("&ldquo;", "“"), ("&bull;", "•"),
        ]
        for (entity, value) in named {
            s = s.replacingOccurrences(of: entity, with: value)
        }
        s = replaceNumericEntities(in: s)
        // `&amp;` last so we don't double-decode "&amp;lt;".
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replaceNumericEntities(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                value = UInt32(body.dropFirst(), radix: 16)
            } else {
                value = UInt32(body)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func replace(in text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: [.regularExpression, .caseInsensitive]
        )
    }
}
