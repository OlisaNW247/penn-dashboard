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

    /// Every `<a href="…">…</a>` in `html`, with the link text stripped of
    /// nested tags and entity-decoded. This is the seam
    /// `CourseDocumentBuilder.links(from:)` uses to find the outbound
    /// pointers a Canvas page, assignment description, or module item makes
    /// to an external course website — the server (`discover-websites`,
    /// `backend/PROTOCOL.md`) decides which of those are worth crawling;
    /// this function only extracts what's there, uninterpreted.
    ///
    /// Deliberately not a raw string (see CLAUDE.md's regex trap): the `#`
    /// anchor-only check below needs no Unicode escape, but the attribute
    /// pattern is easiest to read without doubled backslashes, so this uses
    /// a normal string literal throughout rather than mixing the two forms.
    public static func links(in html: String) -> [HTMLLink] {
        // `<a ...href="...".../>` — the href may be single- or double-quoted
        // and may appear before or after other attributes, so the pattern
        // captures the opening tag (group 1) and the inner text (group 2)
        // separately and pulls `href` out of the opening tag alone, rather
        // than anchoring on attribute order or risking a false match on an
        // `href=`-looking substring inside the link's own text.
        let tagPattern = "(<a\\b[^>]*>)(.*?)</a>"
        guard let tagRegex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let ns = html as NSString
        var links: [HTMLLink] = []
        for match in tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let openingTagRange = match.range(at: 1)
            guard openingTagRange.location != NSNotFound else { continue }
            let opening = ns.substring(with: openingTagRange)
            guard let href = firstHref(in: opening) else { continue }
            let trimmedHref = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHref.isEmpty, trimmedHref != "#", !trimmedHref.hasPrefix("#") else { continue }

            let innerRange = match.range(at: 2)
            let inner = innerRange.location == NSNotFound ? "" : ns.substring(with: innerRange)
            // `plainText` already strips nested tags, decodes entities and
            // collapses whitespace — exactly what link text needs, and
            // reusing it means link text and body text agree on what
            // "plain" means rather than a second, slightly different
            // definition living here.
            let text = plainText(from: inner).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            links.append(HTMLLink(href: trimmedHref, text: text))
        }
        return links
    }

    /// Pulls the value of the first `href="…"` or `href='…'` attribute out
    /// of one opening `<a …>` tag's raw text.
    private static func firstHref(in openingTag: String) -> String? {
        let pattern = "href\\s*=\\s*\"([^\"]*)\"|href\\s*=\\s*'([^']*)'"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = openingTag as NSString
        guard let match = regex.firstMatch(in: openingTag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let doubleQuoted = match.range(at: 1)
        if doubleQuoted.location != NSNotFound { return ns.substring(with: doubleQuoted) }
        let singleQuoted = match.range(at: 2)
        if singleQuoted.location != NSNotFound { return ns.substring(with: singleQuoted) }
        return nil
    }
}

/// One `<a href="…">…</a>` found in a Canvas HTML body. `href` is kept
/// exactly as written (relative or absolute) — resolving it against the
/// page's own URL, and deciding whether it points off-Canvas at all, is the
/// server's job (`discover-websites`), not this client's.
public struct HTMLLink: Sendable, Hashable {
    public let href: String
    public let text: String

    public init(href: String, text: String) {
        self.href = href
        self.text = text
    }
}
