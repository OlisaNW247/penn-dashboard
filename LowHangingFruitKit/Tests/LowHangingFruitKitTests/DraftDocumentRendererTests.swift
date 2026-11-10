import Foundation
import Testing
import PDFKit
@testable import LowHangingFruitKit

@Suite("Draft document renderer")
struct DraftDocumentRendererTests {
    @Test("markdown is detected by shape", arguments: [
        "# Title\nbody", "intro\n\n- one\n- two", "1. first\n2. second", "```\ncode\n```",
        "this is **strong** text", "this is *slanted* text", "<!-- format: markdown -->\nplain words",
    ])
    func detectsMarkdown(_ body: String) {
        #expect(DraftDocumentRenderer.looksLikeMarkdown(body))
    }

    @Test("plain prose is not markdown", arguments: [
        "Dear professor, here is my answer.", "2 * 3 = 6 and 4 * 5 = 20", "snake_case_name is a name", "",
        "Line one\nLine two - with a dash",
    ])
    func plainIsNotMarkdown(_ body: String) {
        #expect(!DraftDocumentRenderer.looksLikeMarkdown(body))
    }

    @Test("a format field wins, leniently")
    func formatField() {
        #expect(DraftDocumentRenderer.isMarkdown(body: "plain", format: " Markdown "))
        #expect(!DraftDocumentRenderer.isMarkdown(body: "# Heading", format: "TEXT"))
        #expect(DraftDocumentRenderer.isMarkdown(body: "# Heading", format: "something-new"))
        let json = #"{"id":"d","assignment_id":"a","kind":"text","body":"x","format":7}"#
        let draft = try? JSONDecoder().decode(AgentDraft.self, from: Data(json.utf8))
        #expect(draft?.format == nil)
        #expect(draft?.body == "x")
    }

    @Test("file names are sanitised and capped at 120 characters")
    func names() {
        #expect(DraftDocumentRenderer.fileName(forTitle: "Problem Set 7") == "Problem Set 7.pdf")
        #expect(DraftDocumentRenderer.fileName(forTitle: "a/b:c*d?\n e") == "a b c d e.pdf")
        #expect(DraftDocumentRenderer.fileName(forTitle: "  ..  ") == "draft.pdf")
        #expect(DraftDocumentRenderer.fileName(forTitle: String(repeating: "x", count: 300)) == String(repeating: "x", count: 120) + ".pdf")
    }

    @Test("a heading and a list become blocks")
    func blocks() {
        let blocks = DraftDocumentRenderer.blocks(from: "<!-- format: markdown -->\n# Essay\n\nSome **bold** words.\n\n- one\n- two\n\n1. first\n")
        #expect(blocks.first?.kind == .heading(level: 1))
        #expect(blocks.first?.text == "Essay")
        let para = blocks.first { $0.kind == .paragraph }
        #expect(para?.runs.contains { $0.bold && $0.text == "bold" } == true)
        let bullets = blocks.filter { if case .listItem(nil, _) = $0.kind { return true } else { return false } }
        #expect(bullets.map(\.text) == ["one", "two"])
        #expect(blocks.contains { $0.kind == .listItem(ordinal: 1, depth: 1) && $0.text == "first" })
    }

#if canImport(UIKit) || canImport(AppKit)
    @Test("the attributed string has a larger heading and a bullet")
    func attributed() {
        let text = DraftDocumentRenderer.attributedString(from: "# Title\n\nbody\n\n- item")
        #expect(text.string.hasPrefix("Title\n"))
        #expect(text.string.contains("\u{2022}\titem"))
        let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? DraftDocumentRenderer.PlatformFont
        let bodyIndex = (text.string as NSString).range(of: "body").location
        let body = text.attribute(.font, at: bodyIndex, effectiveRange: nil) as? DraftDocumentRenderer.PlatformFont
        #expect((heading?.pointSize ?? 0) > (body?.pointSize ?? 99))
    }
#endif

    @Test("the PDF seam: pages on iOS, the fallback elsewhere")
    func pdf() {
        let paragraph = String(repeating: "A sentence that fills the line and then some more words. ", count: 40)
        let long = "# Long\n\n" + (0..<12).map { _ in paragraph }.joined(separator: "\n\n")
        let data = DraftDocumentRenderer.pdfData(from: long)
#if canImport(UIKit)
        #expect(data.map { $0.prefix(4) == Data("%PDF".utf8) } == true)
        #expect((data.flatMap { PDFDocument(data: $0)?.pageCount } ?? 0) >= 3)
#else
        #expect(data == nil)
        #expect(!DraftDocumentRenderer.canRender)
#endif
    }

    @Test("default choice: pdf for markdown text drafts, text otherwise")
    func defaultChoice() {
        func d(_ kind: AgentDraft.Kind, _ body: String?, format: String? = nil) -> AgentDraft {
            AgentDraft(id: "x", assignmentID: "a", kind: kind, body: body, format: format)
        }
        #expect(AgentDraftSubmitChoice.defaultChoice(for: d(.text, "# Hi")) == .pdf)
        #expect(AgentDraftSubmitChoice.defaultChoice(for: d(.text, "just words")) == .text)
        #expect(AgentDraftSubmitChoice.defaultChoice(for: d(.text, "just words", format: "markdown")) == .pdf)
        #expect(AgentDraftSubmitChoice.defaultChoice(for: d(.url, "# Hi")) == .text)
    }
}

@Suite("Submitting a text draft as text or pdf")
struct DraftChoiceSubmitTests {
    final class Seen: @unchecked Sendable { var payload: CanvasSubmissionClient.Payload?; var loads = 0 }

    func send(_ pdf: RenderedDraftPDF?) async -> (AgentSubmitResult, Seen, AgentSubmitAttemptStore) {
        let seen = Seen()
        let store = AgentSubmitAttemptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ChoiceTests-\(UUID().uuidString)/a.json"))
        let item = AgentSnapshot.WorkItem(
            id: "canvas:x", course: "C", title: "T", kind: .assignment, dueAt: nil, done: false,
            noSubmission: false, url: nil, source: "canvas", canvasAssignmentID: "34", canvasCourseID: "12")
        let draft = AgentDraft(id: "smd_1", assignmentID: "canvas:x", kind: .text, body: "# Hi\n\n- a")
        let result = await AgentDraftSubmitter.run(
            draft: draft, item: item, store: store,
            loadFile: { seen.loads += 1; return nil },
            submit: { _, _, payload, before in
                try? before()
                seen.payload = payload
                return .submitted(submissionID: "9", attempt: 1, verified: true)
            },
            report: { _ in true }, pdf: pdf)
        return (result, seen, store)
    }

    @Test("the text choice sends online_text_entry")
    func textChoice() async {
        let (result, seen, _) = await send(nil)
        #expect(result == .submitted(verified: true))
        #expect(seen.payload == .text("# Hi\n\n- a"))
    }

    @Test("the pdf choice sends a file with the pdf mime, once")
    func pdfChoice() async {
        let pdf = RenderedDraftPDF(name: "T.pdf", data: Data("%PDF-1.4".utf8))
        let (result, seen, store) = await send(pdf)
        #expect(result == .submitted(verified: true))
        #expect(seen.payload == .file(name: "T.pdf", mimeType: "application/pdf", data: pdf.data))
        #expect(seen.loads == 0)
        #expect(store.record(for: "smd_1")?.outcome == .submitted)
    }

    @Test("an empty pdf is refused, nothing sent")
    func emptyPDF() async {
        let (result, seen, _) = await send(RenderedDraftPDF(name: "T.pdf", data: Data()))
        #expect(result == .refused(.unsupportedType))
        #expect(seen.payload == nil)
    }
}
