import Foundation
import Testing
#if canImport(PDFKit)
import PDFKit
#endif
@testable import LowHangingFruitKit

/// The review sheet's shape (2026-11-11): what Canvas takes, derived from the
/// preflight's four fields, and the choice that follows for each kind of
/// draft.
@Suite("What Canvas takes, and the sheet's choice")
struct DraftSubmitPlanTests {
    // MARK: Rules

    @Test("the preflight's fields are read leniently; extensions are normalised")
    func rulesFromJSON() {
        let rules = CanvasSubmissionRules(assignmentJSON: [
            "submission_types": ["online_upload"], "allowed_extensions": [".PDF", "docx", "pdf", " "],
            "locked_for_user": true, "can_submit": false,
        ])
        #expect(rules.submissionTypes == ["online_upload"])
        #expect(rules.allowedExtensions == ["pdf", "docx"])
        #expect(rules.lockedForUser && rules.canSubmit == false)
        let bare = CanvasSubmissionRules(assignmentJSON: ["submission_types": "nope", "locked_for_user": "yes"])
        #expect(bare.submissionTypes.isEmpty && bare.allowedExtensions.isEmpty && !bare.lockedForUser && bare.canSubmit == nil)
    }

    // MARK: The derivation table

    static let online = ["online_text_entry", "online_url", "online_upload"]
    static let offline = [[], ["on_paper"], ["none"], ["external_tool"], ["online_quiz"], ["discussion_topic"],
                          ["media_recording"], ["not_graded"], ["student_annotation"], ["on_paper", "external_tool"]]

    /// Every subset of the three online types, each beside a non-online type
    /// too (Canvas mixes them: "online_upload, media_recording").
    static var onlineCombos: [[String]] {
        var out: [[String]] = []
        for mask in 1..<8 {
            let picked = online.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            out.append(picked)
            out.append(picked + ["media_recording"])
        }
        return out
    }

    @Test("every online combination says which of text, link and file", arguments: onlineCombos)
    func onlineTable(_ types: [String]) {
        let a = CanvasAcceptance.derive(CanvasSubmissionRules(submissionTypes: types, allowedExtensions: ["PDF"]))
        let file = types.contains("online_upload")
        #expect(a == .online(text: types.contains("online_text_entry"), url: types.contains("online_url"),
                             file: file, extensions: file ? ["pdf"] : []))
    }

    @Test("nothing online: on paper, none, an external tool, a quiz, a discussion, media", arguments: offline)
    func notOnlineTable(_ types: [String]) {
        #expect(CanvasAcceptance.derive(CanvasSubmissionRules(submissionTypes: types)) == .notOnline)
        // Nothing online wins over locked: the phone could never send it.
        #expect(CanvasAcceptance.derive(CanvasSubmissionRules(submissionTypes: types, lockedForUser: true)) == .notOnline)
    }

    @Test("locked for the student, or can_submit false, is locked; can_submit true or absent is not")
    func lockedTable() {
        let types = ["online_upload"]
        #expect(CanvasAcceptance.derive(.init(submissionTypes: types, lockedForUser: true)) == .locked)
        #expect(CanvasAcceptance.derive(.init(submissionTypes: types, canSubmit: false)) == .locked)
        #expect(CanvasAcceptance.derive(.init(submissionTypes: types, lockedForUser: true, canSubmit: true)) == .locked)
        #expect(CanvasAcceptance.derive(.init(submissionTypes: types, canSubmit: true))
                == .online(text: false, url: false, file: true, extensions: []))
        #expect(CanvasAcceptance.derive(.init(submissionTypes: types))
                == .online(text: false, url: false, file: true, extensions: []))
    }

    @Test("file names against the extension list")
    func fileNames() {
        let pdfOnly = CanvasAcceptance.online(text: false, url: false, file: true, extensions: ["pdf"])
        #expect(pdfOnly.acceptsFile(named: "PS7.PDF"))
        #expect(!pdfOnly.acceptsFile(named: "ps7.zip"))
        #expect(!pdfOnly.acceptsFile(named: "ps7"))
        #expect(CanvasAcceptance.online(text: false, url: false, file: true, extensions: []).acceptsFile(named: "x.zip"))
        #expect(!CanvasAcceptance.online(text: true, url: false, file: false, extensions: []).acceptsFile(named: "x.pdf"))
        #expect(!CanvasAcceptance.locked.acceptsFile(named: "x.pdf"))
    }

    // MARK: The choice per (draft kind × what Canvas takes)

    static func draft(_ kind: AgentDraft.Kind, body: String? = "Plain answer.", file: String? = nil) -> AgentDraft {
        AgentDraft(id: "d", assignmentID: "a", kind: kind, body: kind == .text ? body : nil,
                   url: kind == .url ? "https://example.com/x" : nil, fileName: file)
    }
    static let textOnly = CanvasAcceptance.online(text: true, url: false, file: false, extensions: [])
    static let fileOnly = CanvasAcceptance.online(text: false, url: false, file: true, extensions: [])
    static let pdfDocx = CanvasAcceptance.online(text: false, url: false, file: true, extensions: ["pdf", "docx"])
    static let docxOnly = CanvasAcceptance.online(text: false, url: false, file: true, extensions: ["docx"])
    static let textAndFile = CanvasAcceptance.online(text: true, url: false, file: true, extensions: [])
    static let urlOnly = CanvasAcceptance.online(text: false, url: true, file: false, extensions: [])

    @Test("a text draft on a file-only assignment goes as a pdf, plain text or not")
    func textOnFileOnly() {
        for body in ["Plain answer.", "# Heading\n\n- a"] {
            let plan = DraftSubmitPlan.make(draft: Self.draft(.text, body: body), acceptance: Self.fileOnly, canRenderPDF: true)
            #expect(plan == DraftSubmitPlan(routes: [.pdf], defaultRoute: .pdf, block: nil))
        }
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text), acceptance: Self.pdfDocx, canRenderPDF: true).defaultRoute == .pdf)
    }

    @Test("text and files both go: plain text defaults to text, markdown to the pdf")
    func textOnTextTaking() {
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text), acceptance: Self.textOnly, canRenderPDF: true)
                == DraftSubmitPlan(routes: [.text], defaultRoute: .text, block: nil))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text, body: "# md"), acceptance: Self.textOnly, canRenderPDF: true)
                == DraftSubmitPlan(routes: [.text], defaultRoute: .text, block: nil))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text), acceptance: Self.textAndFile, canRenderPDF: true)
                == DraftSubmitPlan(routes: [.text, .pdf], defaultRoute: .text, block: nil))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text, body: "# md"), acceptance: Self.textAndFile, canRenderPDF: true)
                == DraftSubmitPlan(routes: [.text, .pdf], defaultRoute: .pdf, block: nil))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text, body: "# md"), acceptance: Self.textAndFile, canRenderPDF: false)
                == DraftSubmitPlan(routes: [.text], defaultRoute: .text, block: nil))
    }

    @Test("refusals for text: pdf not among the extensions, a link-only assignment, no renderer")
    func textBlocked() {
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text), acceptance: Self.docxOnly, canRenderPDF: true).block
                == .fileType(ext: "pdf", allowed: ["docx"]))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text), acceptance: Self.urlOnly, canRenderPDF: true).block == .kind(.text))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text), acceptance: Self.fileOnly, canRenderPDF: false).block == .kind(.text))
    }

    @Test("links and files: what Canvas takes, or exactly why not")
    func urlAndFile() {
        #expect(DraftSubmitPlan.make(draft: Self.draft(.url), acceptance: Self.urlOnly, canRenderPDF: true).defaultRoute == .url)
        #expect(DraftSubmitPlan.make(draft: Self.draft(.url), acceptance: Self.fileOnly, canRenderPDF: true).block == .kind(.url))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.file, file: "a.PDF"), acceptance: Self.pdfDocx, canRenderPDF: true)
                == DraftSubmitPlan(routes: [.file], defaultRoute: .file, block: nil))
        let zip = DraftSubmitPlan.make(draft: Self.draft(.file, file: "a.zip"), acceptance: Self.pdfDocx, canRenderPDF: true)
        #expect(zip == DraftSubmitPlan(routes: [], defaultRoute: nil, block: .fileType(ext: "zip", allowed: ["pdf", "docx"])))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.file, file: "a.pdf"), acceptance: Self.textOnly, canRenderPDF: true).block == .kind(.file))
    }

    @Test("not online and locked block every kind; an unknown kind is never sent", arguments: [
        AgentDraft.Kind.text, .url, .file,
    ])
    func blockedEverywhere(_ kind: AgentDraft.Kind) {
        #expect(DraftSubmitPlan.make(draft: Self.draft(kind, file: "a.pdf"), acceptance: .notOnline, canRenderPDF: true).block == .notOnline)
        #expect(DraftSubmitPlan.make(draft: Self.draft(kind, file: "a.pdf"), acceptance: .locked, canRenderPDF: true).block == .locked)
        #expect(DraftSubmitPlan.make(draft: Self.draft(.unknown), acceptance: Self.textAndFile, canRenderPDF: true).block == .unknownKind)
    }

    @Test("not known yet: the draft's own kind, text beside pdf, markdown leaning pdf")
    func unknownAcceptance() {
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text), acceptance: nil, canRenderPDF: true)
                == DraftSubmitPlan(routes: [.text, .pdf], defaultRoute: .text, block: nil))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text, body: "# md"), acceptance: nil, canRenderPDF: true).defaultRoute == .pdf)
        #expect(DraftSubmitPlan.make(draft: Self.draft(.text, body: "# md"), acceptance: nil, canRenderPDF: false)
                == DraftSubmitPlan(routes: [.text], defaultRoute: .text, block: nil))
        #expect(DraftSubmitPlan.make(draft: Self.draft(.file, file: "a.zip"), acceptance: nil, canRenderPDF: true).defaultRoute == .file)
        #expect(DraftSubmitPlan.make(draft: Self.draft(.unknown), acceptance: nil, canRenderPDF: true).block == .unknownKind)
    }

    // MARK: The structured sources already know

    @Test("the assignments list's submission fields are kept for the sheet")
    func structuredRules() throws {
        let json = #"""
        {"id": 34, "name": "Problem Set 7", "submission_types": ["online_upload"],
         "allowed_extensions": ["pdf"], "locked_for_user": false}
        """#
        let a = try JSONDecoder().decode(CanvasOverrideAssignment.self, from: Data(json.utf8))
        #expect(a.submissionRules == CanvasSubmissionRules(submissionTypes: ["online_upload"], allowedExtensions: ["pdf"]))
        let none = try JSONDecoder().decode(CanvasOverrideAssignment.self, from: Data(#"{"id": 1}"#.utf8))
        #expect(none.submissionRules == nil, "no types is not known, not nothing online")
        #expect(!none.lockedForUser && none.allowedExtensions.isEmpty)
    }
}

@Suite("Plain text as a pdf")
struct PlainTextPDFTests {
    @Test("paragraphs split on blank lines; single breaks stay inside a paragraph; nothing is markup")
    func paragraphs() {
        let text = "Dear professor,\r\n\r\nQ1: 2 * 3 = 6   \nQ2: snake_case\n\n\n\n  \nThanks."
        #expect(DraftDocumentRenderer.plainParagraphs(text) == ["Dear professor,", "Q1: 2 * 3 = 6\nQ2: snake_case", "Thanks."])
        #expect(DraftDocumentRenderer.plainParagraphs("  \n\n ").isEmpty)
    }

#if canImport(UIKit) || canImport(AppKit)
    @Test("the attributed string keeps each paragraph and its line breaks, in the body face")
    func attributed() {
        let text = DraftDocumentRenderer.attributedString(fromPlainText: "One *two*\nthree\n\nFour")
        #expect(text.string == "One *two*\u{2028}three\nFour")
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.paragraphSpacing ?? 0) > 0)
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? DraftDocumentRenderer.PlatformFont
        #expect(font?.pointSize == DraftDocumentRenderer.bodySize)
    }
#endif

    static let longFixture: String = {
        let paragraph = String(repeating: "The force on the block is the sum of gravity and the normal force. ", count: 30)
        return (1...14).map { "Part \($0). " + paragraph }.joined(separator: "\n\n")
    }()

#if canImport(UIKit)
    @Test("a long plain draft paginates; every paragraph is in the pages")
    func paginates() throws {
        let data = try #require(DraftDocumentRenderer.pdfData(fromPlainText: Self.longFixture))
        #expect(data.prefix(4) == Data("%PDF".utf8))
        let doc = try #require(PDFDocument(data: data))
        #expect(doc.pageCount >= 3)
        let all = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined(separator: " ")
        #expect(all.contains("Part 1.") && all.contains("Part 14."))
        #expect(DraftDocumentRenderer.pdfData(forDraftBody: "Just one line.") != nil)
    }
#else
    @Test("macOS answers the fallback: no pdf, and the sheet offers none")
    func fallback() {
        #expect(DraftDocumentRenderer.pdfData(fromPlainText: Self.longFixture) == nil)
        #expect(DraftDocumentRenderer.pdfData(forDraftBody: "Just one line.") == nil)
        #expect(!DraftDocumentRenderer.canRender)
        let plan = DraftSubmitPlan.make(
            draft: AgentDraft(id: "d", assignmentID: "a", kind: .text, body: "x"),
            acceptance: .online(text: false, url: false, file: true, extensions: []),
            canRenderPDF: DraftDocumentRenderer.canRender)
        #expect(plan.routes.isEmpty)
    }
#endif
}
