import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Turns an Ed Discussion document into plain text.
///
/// **Why plain text and not the XML or an HTML rendering.** Everything
/// downstream of this wants a string a model and a search index can read:
/// `ask` puts excerpts in a prompt, `CourseSearch` ranks them with BM25, and
/// the backend stores a course document's `text`, never markup (see
/// `backend/PROTOCOL.md`). Tags would cost tokens, pollute the keyword index
/// with words like "paragraph", and give the server a document format it has
/// no reason to know about. The Markdown-ish conventions below (`#` for
/// headings, `- ` for bullets, `> ` for callouts, fenced code) survive a trip
/// through a model well and cost almost nothing.
///
/// Ed's document format (`<document version="2.0">`) is XML in the strict
/// sense, so `XMLParser` does the structure and the entity decoding. But Ed
/// is not strict about what it writes inside it: a raw `&` or an HTML entity
/// like `&nbsp;` makes `XMLParser` fail outright. A parse failure therefore
/// never produces an empty string for a post that had text in it: the
/// fallback is `strippingTags`, which loses the structure but keeps every
/// word. The wrong fix is to return whatever the delegate had emitted before
/// the error, which silently truncates the post at the bad character.
public enum EdDocumentText {
    public static func plainText(fromDocument xml: String) -> String {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let delegate = Converter()
        let parser = XMLParser(data: Data(trimmed.utf8))
        parser.delegate = delegate
        let ok = parser.parse()

        if ok {
            let text = normalize(delegate.output)
            if !text.isEmpty { return text }
        }
        return strippingTags(trimmed)
    }

    /// Tag-stripped text of an HTML-ish or malformed-XML string: tags
    /// removed, block-level tags turned into line breaks, the common
    /// entities decoded, whitespace normalized. Also what the builder uses
    /// for a thread's older `content` field when it has no `document`.
    public static func strippingTags(_ markup: String) -> String {
        let chars = Array(markup)
        var out = ""
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            // A '<' only opens a tag when a name (or '/', or '!') follows.
            // "a < b" in a malformed document is prose, not markup.
            if ch == "<", i + 1 < chars.count,
               chars[i + 1].isLetter || chars[i + 1] == "/" || chars[i + 1] == "!",
               let close = chars[(i + 1)...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                let name = inner.prefix(while: { !$0.isWhitespace && $0 != "/" }).lowercased()
                if blockTags.contains(name) { out += "\n" }
                i = close + 1
                continue
            }
            out.append(ch)
            i += 1
        }
        return normalize(decodeEntities(out))
    }

    private static let blockTags: Set<String> = [
        "paragraph", "heading", "list-item", "callout", "pre", "snippet", "break", "figure",
        "p", "br", "li", "div", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
    ]

    /// Collapse runs of three or more newlines to one blank line, trim the
    /// ends of every line (a bullet's trailing space is not content), and
    /// trim the whole.
    static func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line)
                while let last = l.last, last == " " || last == "\t" { l.removeLast() }
                return l
            }
            .joined(separator: "\n")
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The handful of entities worth decoding by hand in the fallback path
    /// (the XML path gets them from `XMLParser`). `&amp;` goes last so that
    /// "&amp;lt;" decodes to "&lt;" and not to "<".
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
        ]
        for (entity, value) in named {
            s = s.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") {
            let ns = s as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let body = ns.substring(with: match.range(at: 1))
                let scalarValue = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
                if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += ns.substring(with: match.range)
                }
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            s = result
        }
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The `XMLParser` delegate. A final class on purpose, created fresh for
    /// each call and never shared: it is mutable state with no
    /// synchronization, and `XMLParser` calls it synchronously on the calling
    /// thread from inside `parse()`, so it is not (and must not be made)
    /// `Sendable`.
    ///
    /// The model is "lines". `lineOpen` says whether text has already been
    /// written on the current output line; the line's prefix (quote marks,
    /// list marker, heading hashes) is written lazily, by the first text that
    /// lands on it, so an empty paragraph or an empty list item emits nothing
    /// rather than a lone "- ".
    private final class Converter: NSObject, XMLParserDelegate {
        private(set) var output = ""

        private struct ListContext {
            let ordered: Bool
            var counter = 0
        }

        private var lineOpen = false
        private var quoteDepth = 0
        private var lists: [ListContext] = []
        private var pendingMarker: String?
        private var pendingHeading: String?
        private var blockDepth = 0     // paragraphs and headings
        private var inCode = false
        /// Link labels are captured, not written, because the rendering
        /// ("label (href)") depends on the label text, which is only known at
        /// the closing tag.
        private var captures: [String] = []
        private var linkHrefs: [String] = []

        // MARK: output primitives

        private func write(_ text: String) {
            if captures.isEmpty {
                output += text
            } else {
                captures[captures.count - 1] += text
            }
        }

        private func linePrefix() -> String {
            var prefix = String(repeating: "> ", count: quoteDepth)
            if !lists.isEmpty {
                prefix += String(repeating: "  ", count: lists.count - 1)
                prefix += pendingMarker ?? "  "
                pendingMarker = nil
            }
            if let heading = pendingHeading {
                prefix += heading
                pendingHeading = nil
            }
            return prefix
        }

        private func beginLineIfNeeded() {
            guard !lineOpen else { return }
            output += linePrefix()
            lineOpen = true
        }

        private func endLine() {
            guard lineOpen, captures.isEmpty else { return }
            output += "\n"
            lineOpen = false
        }

        // MARK: XMLParserDelegate

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "paragraph":
                endLine()
                blockDepth += 1
            case "heading":
                endLine()
                blockDepth += 1
                let level = min(max(Int(attributeDict["level"] ?? "") ?? 1, 1), 6)
                pendingHeading = String(repeating: "#", count: level) + " "
            case "list":
                endLine()
                let style = attributeDict["style"]?.lowercased() ?? "bullet"
                lists.append(ListContext(ordered: style == "number" || style == "ordered"))
            case "list-item":
                endLine()
                if !lists.isEmpty {
                    lists[lists.count - 1].counter += 1
                    let top = lists[lists.count - 1]
                    pendingMarker = top.ordered ? "\(top.counter). " : "- "
                }
            case "callout":
                endLine()
                quoteDepth += 1
            case "pre", "snippet":
                endLine()
                let language = attributeDict["language"] ?? attributeDict["lang"] ?? ""
                output += String(repeating: "> ", count: quoteDepth) + "```" + language + "\n"
                inCode = true
            case "link":
                beginLineIfNeeded()
                captures.append("")
                linkHrefs.append(attributeDict["href"] ?? "")
            case "break":
                // A line break inside a paragraph: the next text on the new
                // line still needs the quote/list prefix, hence lineOpen off.
                write("\n")
                if captures.isEmpty { lineOpen = false }
            case "image":
                beginLineIfNeeded()
                write("[image]")
                if blockDepth == 0 { endLine() }
            default:
                // document, bold, italic, underline, code, math, spoiler,
                // figure and anything Ed adds later are transparent: their
                // text is kept and their tags dropped.
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "paragraph", "heading":
                endLine()
                blockDepth = max(blockDepth - 1, 0)
                pendingHeading = nil
            case "list":
                endLine()
                if !lists.isEmpty { lists.removeLast() }
                pendingMarker = nil
            case "list-item":
                endLine()
                pendingMarker = nil
            case "callout":
                endLine()
                quoteDepth = max(quoteDepth - 1, 0)
            case "pre", "snippet":
                if !output.hasSuffix("\n") { output += "\n" }
                output += String(repeating: "> ", count: quoteDepth) + "```\n"
                inCode = false
                lineOpen = false
            case "link":
                guard let label = captures.popLast(), let href = linkHrefs.popLast() else { return }
                let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if href.isEmpty || text.isEmpty {
                    write(href.isEmpty ? text : href)
                } else if text == href {
                    write(href)
                } else {
                    write("\(text) (\(href))")
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func append(_ string: String) {
            if inCode {
                output += string
                return
            }
            // Whitespace between tags (pretty-printed XML) lands here with no
            // line open; it is layout, not content.
            if !lineOpen, captures.isEmpty, string.allSatisfy(\.isWhitespace) { return }
            beginLineIfNeeded()
            write(string)
        }
    }
}
