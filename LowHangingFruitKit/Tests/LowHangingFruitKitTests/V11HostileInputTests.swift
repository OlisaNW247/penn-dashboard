import Foundation
import Testing
@testable import LowHangingFruitKit

/// The v11 test pass of 2026-11-11 (docs/V11_TEST_PHONE_2026-11-11.md, §2):
/// what an agent, a link or a server can hand the phone, at its worst.
///
/// The PDF itself is drawn only on iOS (`DraftDocumentRenderer.paginate` is
/// behind `canImport(UIKit)`), so `swift test` on the Mac exercises
/// everything up to the attributed string the paginator is given: detection,
/// the markdown parse, the plain-text paragraphs and the file name. The
/// timing budgets are for that work; the paginator's own cases are at the
/// bottom, compiled only where it exists.
@Suite("v11 test pass: hostile inputs")
struct V11HostileInputTests {
    static func seconds(_ body: () -> Void) -> Double {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    /// The bodies the brief lists, by name, so a failure names its case.
    static let bodies: [(String, String)] = [
        ("100,000 characters", String(repeating: "All work and no play. ", count: 4_546)),
        ("only emoji", String(repeating: "😀🧪🔥👩🏽‍🔬🇺🇸", count: 2_000)),
        ("right to left", String(repeating: "שלום עולם. مرحبا بالعالم.\n\n", count: 500)),
        ("5,000-line list", (1...5_000).map { "- item \($0) with **bold** text" }.joined(separator: "\n")),
        ("nested code fences", "````\n```swift\nlet a = 1\n```\n````\n\n~~~\n```\nunclosed"),
        ("markdown table", "| a | b |\n|---|---|\n" + (1...500).map { "| \($0) | \($0 * 2) |" }.joined(separator: "\n")),
        ("math", "The field is $E = \\frac{kq}{r^2}$ and $$\\int_0^\\infty e^{-x} dx = 1$$ so $a_1 * b_2$."),
        ("HTML tags", "<script>alert(1)</script><img src=x onerror=alert(2)><b>bold</b>&amp;&lt;"),
        ("NUL and controls", String((0..<2_000).map { Character(UnicodeScalar(UInt8($0 % 32))) })),
        ("empty", ""),
        ("whitespace only", "   \n\n\t\t\n  "),
        ("deep nesting", String(repeating: "> ", count: 200) + "quote" + "\n" + (0..<60).map { String(repeating: "  ", count: $0) + "- deep" }.joined(separator: "\n")),
        ("emphasis soup", String(repeating: "*_*_**__", count: 5_000)),
        ("one 100,000-character word", String(repeating: "x", count: 100_000)),
    ]

    @Test("every hostile body is classified, parsed and laid out without crashing, in a few seconds",
          arguments: bodies.map(\.0))
    func hostileBodies(name: String) {
        let body = Self.bodies.first { $0.0 == name }!.1
        var isMarkdown = false
        let elapsed = Self.seconds {
            isMarkdown = DraftDocumentRenderer.isMarkdown(body: body)
            let blocks = DraftDocumentRenderer.blocks(from: body)
            _ = blocks.count
            let paragraphs = DraftDocumentRenderer.plainParagraphs(body)
            _ = paragraphs.count
            #if canImport(UIKit) || canImport(AppKit)
            let a = isMarkdown ? DraftDocumentRenderer.attributedString(from: body)
                               : DraftDocumentRenderer.attributedString(fromPlainText: body)
            // The text is all there (or the markup's text is): never more
            // than a small multiple of the input.
            #expect(a.length <= max(body.utf16.count * 2, 64))
            #endif
        }
        #expect(elapsed < 5, "\(name) took \(elapsed) s")
        // On this platform the PDF answers nil and the sheet offers no pdf.
        #if !canImport(UIKit)
        #expect(DraftDocumentRenderer.pdfData(forDraftBody: body) == nil)
        #endif
    }

    @Test("an empty or blank body has no paragraphs to print")
    func blankBodies() {
        #expect(DraftDocumentRenderer.plainParagraphs("").isEmpty)
        #expect(DraftDocumentRenderer.plainParagraphs(" \n\n\t\n").isEmpty)
        #expect(!DraftDocumentRenderer.isMarkdown(body: ""))
    }

    @Test("HTML in a draft is never markup: it stays text in the pdf, and is escaped for Canvas")
    func htmlStaysText() {
        let body = "<script>alert(1)</script>"
        #expect(DraftDocumentRenderer.plainParagraphs(body) == [body])
        #expect(CanvasSubmissionClient.htmlBody(body) == "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>")
    }

    @Test("math in $...$ survives as text")
    func mathIsText() {
        let blocks = DraftDocumentRenderer.blocks(from: "# Q1\n\nThe answer is $x^2 + y^2$.")
        #expect(blocks.map(\.text).joined().contains("x^2 + y^2"))
    }

    // MARK: Titles and file names

    @Test("a 500-character title with slashes and dots is one safe, bounded file name")
    func hostileTitle() {
        let title = String(repeating: "../etc/passwd/", count: 36) + ".." // 506 characters
        let name = DraftDocumentRenderer.fileName(forTitle: title)
        #expect(name.hasSuffix(".pdf"))
        let stem = String(name.dropLast(4))
        #expect(!stem.contains("/") && !stem.contains("\\"))
        #expect(!stem.hasPrefix(".") && !stem.hasSuffix("."))
        #expect(stem.count <= DraftDocumentRenderer.maxNameCharacters)
        // ".." can survive inside the stem ("passwd .. etc"), but with no
        // separator left it is a name, not a path segment.
        #expect(name.components(separatedBy: "/").count == 1)
    }

    @Test("titles that clean to nothing become draft.pdf", arguments: ["", "////", "...", " . / . ", "\u{0}\u{1}\n\t"])
    func emptyTitles(title: String) {
        #expect(DraftDocumentRenderer.fileName(forTitle: title) == "draft.pdf")
    }

    @Test("the file name Canvas gets passes its own extension check")
    func nameIsAPDF() {
        let name = DraftDocumentRenderer.fileName(forTitle: "Problem Set 7: Gauss's law / part (a)")
        #expect(CanvasSubmissionClient.accepts(types: ["online_upload"],
                                               payload: .file(name: name, mimeType: "application/pdf", data: Data([1])),
                                               allowedExtensions: ["pdf"]))
        #expect(name == "Problem Set 7 Gauss's law part (a).pdf")
    }

    // MARK: Link codes

    @Test("malformed smooth://link URLs are refused", arguments: [
        "", "smooth://", "smooth://link", "smooth://link?", "smooth://link?c=", "smooth://link?c",
        "smooth://link?c=abc&c=def", "smooth://link?c=abc&d=1", "smooth://link?C=abcdefgh12345678",
        "smooth://link/extra?c=abcdefgh12345678", "smooth://link?c=abcdefgh12345678#frag",
        "smooth://user@link?c=abcdefgh12345678", "smooth://link:80?c=abcdefgh12345678",
        "https://link?c=abcdefgh12345678", "smooth://pair?c=abcdefgh12345678",
        "smooth://link?c=" + String(repeating: "a", count: 5_000),
        "smooth://link?c=%00%00%00%00%00%00%00%00", "smooth://link?c=../../etc",
        "smooth://link?c=<script>", "smooth://link?c=abc def",
    ])
    func badLinks(text: String) {
        #expect(AgentLinkRequest(text: text) == nil, "\(text.prefix(60))")
    }

    @Test("typed codes: case, spaces and dashes are ignored, everything else refused")
    func typedCodes() {
        #expect(AgentUserCode.normalize("bcdf-ghjk") == "BCDFGHJK")
        #expect(AgentUserCode.normalize(" B C D F G H J K ") == "BCDFGHJK")
        for bad in ["", "BCDFGHJ", "BCDFGHJKL", "ABCDFGHJ", "BCDFGHJ1", "BCDFGHJ0", "BCDFGHJÉ",
                    "BCDF\u{0}GHJK", "BCDF_GHJK", String(repeating: "B", count: 10_000),
                    "ＢＣＤＦＧＨＪＫ", "BCDFGHJK\n", "bcdfghjk;drop"] {
            #expect(AgentUserCode.normalize(bad) == nil, "\(bad.prefix(20))")
        }
    }

    // MARK: Drafts off the wire

    static func decode(_ json: String) throws -> AgentDraft {
        try JSONDecoder().decode(AgentDraft.self, from: Data(json.utf8))
    }

    @Test("wrongly typed fields decode to nil, unknown kinds and statuses to unknown")
    func wrongTypes() throws {
        let d = try Self.decode(#"""
        {"id":"smd_1","assignment_id":"a","kind":7,"body":["x"],"url":{"a":1},"file_name":12,
         "mime_type":null,"file_bytes":"big","note":false,"client_name":3,"status":"pwned",
         "created_at":99,"file_url":[],"format":{"x":1},"extra":"ignored","grade":"A"}
        """#)
        #expect(d.kind == .unknown && d.status == .unknown)
        #expect(d.body == nil && d.url == nil && d.fileName == nil && d.fileBytes == nil && d.note == nil)
        #expect(d.clientName == nil && d.createdAt == nil && d.fileURL == nil && d.format == nil)
        #expect(!d.status.isOpen, "a status this build does not know is never shown")
        #expect(AgentDraftSubmitter.payload(for: d, fileData: Data([1])) == nil)
        #expect(DraftSubmitPlan.make(draft: d, acceptance: nil, canRenderPDF: true).block == .unknownKind)
    }

    @Test("missing id or assignment fails that draft")
    func missingRequired() {
        #expect(throws: (any Error).self) { try Self.decode(#"{"assignment_id":"a","kind":"text"}"#) }
        #expect(throws: (any Error).self) { try Self.decode(#"{"id":"x","kind":"text"}"#) }
        #expect(throws: (any Error).self) { try Self.decode(#"{"id":5,"assignment_id":"a","kind":"text"}"#) }
    }

    @Test("absurd values: a 10 MB body, negative and huge sizes, a long agent name")
    func absurdValues() throws {
        let tenMB = String(repeating: "a\n", count: 5_000_000)
        let json = #"{"id":"smd_1","assignment_id":"a","kind":"text","status":"proposed","client_name":""#
            + String(repeating: "C", count: 10_000) + #"","body":""# + tenMB.replacingOccurrences(of: "\n", with: "\\n") + #""}"#
        var d: AgentDraft!
        let decodeTime = Self.seconds { d = try? Self.decode(json) }
        #expect(d != nil)
        #expect(decodeTime < 5)
        #expect(d.agentName.count == 40)
        var preview: String?
        let previewTime = Self.seconds { preview = d.preview(maxLines: 2, maxCharacters: 160) }
        #expect((preview?.count ?? 0) <= 161)
        #expect(previewTime < 0.5, "the card's preview on a 10 MB body took \(previewTime) s")
        // The cache keeps none of it.
        let cached = try #require(AgentDraftCache.encode([d]))
        #expect(cached.count < 2_000)

        let negative = try Self.decode(#"{"id":"f","assignment_id":"a","kind":"file","file_name":"x.pdf","file_bytes":-1}"#)
        #expect(negative.preview() != nil)
        let huge = try Self.decode(#"{"id":"f","assignment_id":"a","kind":"file","file_name":"x.pdf","file_bytes":9223372036854775807}"#)
        #expect(huge.preview() != nil)
        let overflow = try Self.decode(#"{"id":"f","assignment_id":"a","kind":"file","file_name":"x.pdf","file_bytes":1e300}"#)
        #expect(overflow.fileBytes == nil)
    }

    @Test("a non-https link or a javascript: link is never a payload", arguments: [
        "http://example.com", "javascript:alert(1)", "file:///etc/passwd", "ftp://x", "", "https//nope",
        "data:text/html,<b>x</b>",
    ])
    func badDraftLinks(url: String) {
        let d = AgentDraft(id: "u", assignmentID: "a", kind: .url, url: url)
        #expect(AgentDraftSubmitter.payload(for: d, fileData: nil) == nil)
    }

    @Test("one malformed draft in the server's list does not hide the others")
    func lossyList() throws {
        let json = #"""
        {"drafts":[
          {"id":"good_1","assignment_id":"a","kind":"text","body":"x","status":"proposed"},
          {"assignment_id":"a","kind":"text"},
          {"id":42,"assignment_id":"a","kind":"text"},
          "not an object",
          {"id":"good_2","assignment_id":"b","kind":"url","url":"https://x.edu","status":"seen"}
        ]}
        """#
        let list = try JSONDecoder().decode(AgentDraftList.self, from: Data(json.utf8))
        #expect(list.drafts.map(\.id) == ["good_1", "good_2"])
        let empty = try JSONDecoder().decode(AgentDraftList.self, from: Data(#"{"drafts":[]}"#.utf8))
        #expect(empty.drafts.isEmpty)
    }

    // MARK: The attachment planner at scale

    @Test("10,000 assignment documents are planned in well under a second or two")
    func plannerAtScale() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let docs: [CourseDocument] = (0..<10_000).map { i in
            CourseDocument(
                courseID: "1949400", course: "PHYS 0151", kind: .assignment,
                sourceID: "\(100_000 + i)", title: "HW \(i)",
                url: URL(string: "https://canvas.upenn.edu/courses/1949400/assignments/\(100_000 + i)"),
                text: "Read the sheet: https://canvas.upenn.edu/courses/1949400/files/\(500_000 + i)/download\n"
                    + "and https://canvas.upenn.edu/files/\(900_000 + i)",
                updatedAt: now, fetchedAt: now,
                dueAt: now.addingTimeInterval(Double(i % 30) * 86_400))
        }
        var plan: [AssignmentAttachmentFetch] = []
        let elapsed = Self.seconds { plan = AssignmentAttachmentPlanner.plan(documents: docs, now: now, attempts: [:]) }
        #expect(plan.count == AssignmentAttachmentPlanner.maxPerRun)
        #expect(Set(plan.map(\.fileID)).count == plan.count)
        #expect(elapsed < 3, "planning 10,000 documents took \(elapsed) s")
    }

#if canImport(UIKit)
    // MARK: The PDF itself (iOS only)

    @Test("every hostile body renders a bounded PDF or answers nil, in a few seconds", arguments: bodies.map(\.0))
    func hostilePDF(name: String) {
        let body = Self.bodies.first { $0.0 == name }!.1
        var data: Data?
        let elapsed = Self.seconds { data = DraftDocumentRenderer.pdfData(forDraftBody: body) }
        #expect(elapsed < 10, "\(name) took \(elapsed) s")
        if let data { #expect(data.count < 8_000_000, "\(name): \(data.count) bytes") }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { #expect(data == nil) }
    }
#endif
}
