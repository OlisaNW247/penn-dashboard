import Foundation
import CoreText
import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A text draft rendered to a PDF on the phone, ready for the file path.
public struct RenderedDraftPDF: Equatable, Sendable {
    public let name: String
    public let data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

/// What the review sheet will send for a text draft.
public enum AgentDraftSubmitChoice: String, Equatable, Sendable {
    case text, pdf

    /// PDF when the draft is a text draft that reads as markdown, text
    /// otherwise.
    public static func defaultChoice(for draft: AgentDraft) -> AgentDraftSubmitChoice {
        draft.kind == .text && DraftDocumentRenderer.isMarkdown(draft) ? .pdf : .text
    }
}

/// A document the agent wrote travels as source text (claude.ai will not emit
/// a 144,000-character base64 PDF) and is rendered here, on the phone, so the
/// student sees exactly what goes to Canvas. The pure parts (detection, file
/// names, the attributed string) work everywhere; the PDF pagination is behind
/// a `#if canImport(UIKit)` seam and answers nil on macOS.
///
/// Math in `$...$` is left as text: there is no TeX on the device.
public enum DraftDocumentRenderer {
    public static let markerLine = "<!-- format: markdown -->"
    public static let pdfMimeType = "application/pdf"
    public static let maxNameCharacters = 120

    // MARK: Detection

    /// The server's `format` when it sends one, else the body's own shape.
    public static func isMarkdown(_ draft: AgentDraft) -> Bool {
        guard let body = draft.body else { return false }
        return isMarkdown(body: body, format: draft.format)
    }

    public static func isMarkdown(body: String, format: String? = nil) -> Bool {
        switch format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "markdown"?, "md"?, "text/markdown"?: return true
        case "text"?, "plain"?, "plaintext"?, "text/plain"?: return false
        default: return looksLikeMarkdown(body)
        }
    }

    /// An explicit first line, a heading, a list, a code fence or emphasis.
    public static func looksLikeMarkdown(_ body: String) -> Bool {
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           first.trimmingCharacters(in: .whitespaces).lowercased() == markerLine { return true }
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if patterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) { return true }
        }
        return false
    }

    private static let patterns: [NSRegularExpression] = [
        #"^\s{0,3}#{1,6}\s+\S"#,                 // heading
        #"^\s*([-*+]|\d{1,3}[.)])\s+\S"#,         // list item
        #"^\s*(```|~~~)"#,                        // code fence
        #"\*\*[^*\s][^*\n]*\*\*"#,                // strong
        #"__[^_\s][^_\n]*__"#,                    // strong
        #"(?<![*\w])\*[^*\s][^*\n]*\*(?![*\w])"#, // emphasis
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    // MARK: Names

    /// `<title>.pdf`: no path or reserved characters, one space at a time, the
    /// title cut at 120 characters. "draft" when nothing is left.
    public static func fileName(forTitle title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = title.unicodeScalars.map { bad.contains($0) ? " " : Character($0) }
            .map(String.init).joined()
        var words = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        words = String(words.prefix(maxNameCharacters))
        words = words.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).trimmingCharacters(in: .whitespaces)
        return (words.isEmpty ? "draft" : words) + ".pdf"
    }

    // MARK: Blocks

    public struct Run: Equatable, Sendable {
        public var text: String
        public var bold = false, italic = false, code = false, strike = false
    }

    public struct Block: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case paragraph
            case heading(level: Int)
            case listItem(ordinal: Int?, depth: Int)   // ordinal nil = bullet
            case codeBlock
            case quote
            case rule
        }
        public var kind: Kind
        public var runs: [Run]
        public var text: String { runs.map(\.text).joined() }
    }

    /// The document as flat blocks, the marker line dropped.
    public static func blocks(from markdown: String) -> [Block] {
        var source = markdown
        if let first = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first,
           first.trimmingCharacters(in: .whitespaces).lowercased() == markerLine {
            source = String(source.dropFirst(first.count))
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [Block(kind: .paragraph, runs: [Run(text: source)])]
        }

        var blocks: [Block] = []
        var currentKey: Int?
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let key = components.first?.identity ?? 0
            let kind = blockKind(components)
            var piece = Run(text: text)
            if let inline = run.inlinePresentationIntent {
                piece.bold = inline.contains(.stronglyEmphasized)
                piece.italic = inline.contains(.emphasized)
                piece.code = inline.contains(.code)
                piece.strike = inline.contains(.strikethrough)
            }
            if key == currentKey, !blocks.isEmpty {
                blocks[blocks.count - 1].runs.append(piece)
            } else {
                blocks.append(Block(kind: kind, runs: [piece]))
                currentKey = key
            }
        }
        return blocks
    }

    private static func blockKind(_ components: [PresentationIntent.IntentType]) -> Block.Kind {
        var ordinal: Int?
        var ordered = false
        var depth = 0
        var heading: Int?
        var code = false, quote = false, rule = false
        for component in components {
            switch component.kind {
            case .header(let level): heading = heading ?? level
            case .listItem(let n): ordinal = ordinal ?? n
            case .orderedList: ordered = true; depth += 1
            case .unorderedList: depth += 1
            case .codeBlock: code = true
            case .blockQuote: quote = true
            case .thematicBreak: rule = true
            default: break
            }
        }
        if rule { return .rule }
        if let heading { return .heading(level: heading) }
        if code { return .codeBlock }
        if let ordinal { return .listItem(ordinal: ordered ? ordinal : nil, depth: max(depth, 1)) }
        if quote { return .quote }
        return .paragraph
    }

    // MARK: Plain text

    /// A plain-text draft as its paragraphs: split on blank lines, each
    /// paragraph keeping its own single line breaks, trailing spaces and
    /// empty paragraphs dropped. Nothing in it is read as markup, so a
    /// "2 * 3" or a "snake_case" survives as written.
    public static func plainParagraphs(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var paragraphs: [String] = []
        var current: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if trimmed.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        return paragraphs
    }

    // MARK: Attributed string

#if canImport(UIKit)
    typealias PlatformFont = UIFont
#elseif canImport(AppKit)
    typealias PlatformFont = NSFont
#endif

#if canImport(UIKit) || canImport(AppKit)
    static let bodySize: CGFloat = 11.5
    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 15
        default: return 13
        }
    }

    static func font(_ name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> PlatformFont {
        let base = PlatformFont(name: name, size: size) ?? PlatformFont.systemFont(ofSize: size)
#if canImport(UIKit)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: d, size: size)
#else
        var result = base
        if bold { result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) }
        if italic { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
        return result
#endif
    }

    /// Inter for text (Inter-Bold for headings), Space Mono for code. The
    /// caller registers the bundled fonts first; a missing font falls back to
    /// the system face rather than failing.
    public static func attributedString(from markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = blocks(from: markdown).filter { $0.kind == .rule || !$0.text.isEmpty }
        for (index, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 8
            var size = bodySize
            var forceBold = false
            var prefix = ""
            switch block.kind {
            case .heading(let level):
                size = headingSize(level); forceBold = true
                style.paragraphSpacingBefore = index == 0 ? 0 : 6
            case .listItem(let ordinal, let depth):
                let indent = CGFloat(depth) * 16
                style.firstLineHeadIndent = indent - 14
                style.headIndent = indent
                style.paragraphSpacing = 3
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                prefix = (ordinal.map { "\($0)." } ?? "\u{2022}") + "\t"
            case .quote:
                style.firstLineHeadIndent = 16; style.headIndent = 16
            case .codeBlock:
                style.firstLineHeadIndent = 10; style.headIndent = 10
            case .rule:
                prefix = "\u{2014}\u{2014}\u{2014}"
            case .paragraph:
                break
            }
            let piece = NSMutableAttributedString()
            func add(_ text: String, _ run: Run?) {
                let isCode = run?.code == true || block.kind == .codeBlock
                let f: PlatformFont = isCode
                    ? font(forceBold || run?.bold == true ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size - 1)
                    : font(forceBold || run?.bold == true ? "Inter-Bold" : "Inter-Regular", size: size,
                           italic: run?.italic == true || block.kind == .quote)
                var attrs: [NSAttributedString.Key: Any] = [.font: f, .paragraphStyle: style]
                if run?.strike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                piece.append(NSAttributedString(string: text, attributes: attrs))
            }
            if !prefix.isEmpty { add(prefix, nil) }
            for run in block.runs { add(run.text, run) }
            if index < blocks.count - 1 { add("\n", nil) }
            out.append(piece)
        }
        return out
    }

    /// A plain-text draft in the body face: one paragraph per blank-line
    /// block, single line breaks kept as line breaks inside it (U+2028, so
    /// the paragraph spacing falls only between paragraphs).
    public static func attributedString(fromPlainText text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 10
        let attrs: [NSAttributedString.Key: Any] = [.font: font("Inter-Regular", size: bodySize), .paragraphStyle: style]
        let joined = plainParagraphs(text)
            .map { $0.replacingOccurrences(of: "\n", with: "\u{2028}") }
            .joined(separator: "\n")
        return NSAttributedString(string: joined, attributes: attrs)
    }
#endif

    // MARK: PDF

    public static let pageSize = CGSize(width: 612, height: 792)   // US Letter, points
    public static let margin: CGFloat = 72                          // one inch

    /// True where `pdfData` can render (iOS).
    public static var canRender: Bool {
#if canImport(UIKit)
        return true
#else
        return false
#endif
    }

    /// The markdown as paginated US Letter pages, or nil when this platform
    /// cannot render or nothing printable is left.
    public static func pdfData(from markdown: String) -> Data? {
#if canImport(UIKit)
        return paginate(attributedString(from: markdown))
#else
        return nil
#endif
    }

    /// Plain text as pages, paragraphs preserved, nothing read as markup.
    public static func pdfData(fromPlainText text: String) -> Data? {
#if canImport(UIKit)
        return paginate(attributedString(fromPlainText: text))
#else
        return nil
#endif
    }

    /// Any text draft: markdown when it reads as markdown (or says so), plain
    /// text otherwise. The review sheet offers "send as pdf" for every text
    /// draft on an assignment that takes files, not only markdown ones.
    public static func pdfData(forDraftBody body: String, format: String? = nil) -> Data? {
        isMarkdown(body: body, format: format) ? pdfData(from: body) : pdfData(fromPlainText: body)
    }

#if canImport(UIKit)
    static func paginate(_ text: NSAttributedString) -> Data? {
        guard text.length > 0 else { return nil }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let page = CGRect(origin: .zero, size: pageSize)
        let box = page.insetBy(dx: margin, dy: margin)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        var failed = false
        let data = renderer.pdfData { context in
            var location = 0
            while location < text.length {
                context.beginPage()
                let cg = context.cgContext
                cg.saveGState()
                // Core Text draws y-up; the PDF context is y-down.
                cg.translateBy(x: 0, y: pageSize.height)
                cg.scaleBy(x: 1, y: -1)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0),
                                                     CGPath(rect: box, transform: nil), nil)
                CTFrameDraw(frame, cg)
                let visible = CTFrameGetVisibleStringRange(frame)
                cg.restoreGState()
                if visible.length == 0 { failed = true; break }
                location += visible.length
            }
        }
        return failed || data.isEmpty ? nil : data
    }
#endif
}
