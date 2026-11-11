import Foundation
import Testing
@testable import LowHangingFruitKit

/// The v11 test pass of 2026-11-11 (docs/V11_TEST_PHONE_2026-11-11.md, §7):
/// Marco's Problem Set 7 of 2026-11-10, rebuilt offline from fixtures, end to
/// end. Canvas's assignment (upload only, PDF) is pooled with its link lines;
/// the attachment planner picks the two linked PDFs; Claude's 7,000-character
/// markdown answer with ten headings is laid out; the plan for a text draft
/// on an upload-only assignment is "send as pdf"; the submitter sends
/// `online_upload` with that PDF, the record on disk before the first POST.
///
/// An extension of `V11SubmitRulesTests`, so it shares that suite's
/// serialized scripted Canvas.
extension V11SubmitRulesTests {
    static let ps7Course = CourseSummary(courseID: "1949400", code: "PHYS 0151", name: "Principles of Physics II",
                                         url: URL(string: "https://canvas.upenn.edu/courses/1949400"), section: nil)

    static let ps7Description = """
    <p>Problem Set 7 covers Gauss's law and capacitance. Submit one PDF.</p>
    <p><a href="/courses/1949400/files/14411001/download?wrap=1">Problem Set 7.pdf</a></p>
    <p>Formula sheet: <a href="https://canvas.upenn.edu/courses/1949400/files/14411002">formula sheet</a></p>
    <p>Last year's (not ours): <a href="https://canvas.upenn.edu/courses/1700000/files/999">old</a>,
       elsewhere: <a href="https://example.com/files/12345">mirror</a>,
       a folder: <a href="https://canvas.upenn.edu/courses/1949400/files/folder/sheets">folder</a></p>
    """

    static func ps7Assignment(now: Date) throws -> CourseContentAssignment {
        let iso = ISO8601DateFormatter()
        let object: [String: Any] = [
            "id": 7001, "name": "Problem Set 7", "description": ps7Description,
            "due_at": iso.string(from: now.addingTimeInterval(2 * 86_400)),
            "html_url": "https://canvas.upenn.edu/courses/1949400/assignments/7001",
            "points_possible": 20, "updated_at": iso.string(from: now),
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CourseContentAssignment.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Ten headings, about 7,000 characters: the shape of Claude's answer.
    static let ps7Markdown: String = {
        var parts: [String] = []
        for n in 1...10 {
            parts.append("## Problem \(n)")
            parts.append("By Gauss's law, **the flux** through the surface is $\\Phi = Q_{enc}/\\epsilon_0$. "
                         + String(repeating: "The field outside a uniformly charged sphere is that of a point charge. ", count: 8))
            parts.append("- Given: r = \(n) cm\n- Find: E\n\n1. Draw the surface.\n2. Apply symmetry.")
        }
        return parts.joined(separator: "\n\n")
    }()

    @Test("Problem Set 7, offline: pooled text, two PDFs planned, the answer laid out, sent as one PDF upload")
    func problemSet7EndToEnd() async throws {
        let now = Date(timeIntervalSince1970: 1_794_355_200) // 2026-11-10
        // 1. The pooled assignment text keeps its same-host file links as lines.
        let doc = CourseDocumentBuilder.assignment(from: try Self.ps7Assignment(now: now), course: Self.ps7Course, now: now)
        #expect(doc.text.contains("Problem Set 7.pdf: https://canvas.upenn.edu/courses/1949400/files/14411001/download?wrap=1"))
        #expect(doc.text.contains("formula sheet: https://canvas.upenn.edu/courses/1949400/files/14411002"))
        #expect(!doc.text.contains("example.com"), "another host's link is not a line")
        #expect(!doc.text.contains("Status:"), "the student's own state is never pooled")

        // 2. The planner picks exactly the two PDFs of this course.
        let plan = AssignmentAttachmentPlanner.plan(documents: [doc], now: now, attempts: [:])
        #expect(plan.map(\.fileID) == ["14411001", "14411002"])
        #expect(plan.allSatisfy { $0.courseID == "1949400" && $0.assignmentSourceID == "7001" })

        // 3. The answer reads as markdown and lays out with its ten headings.
        let body = Self.ps7Markdown
        #expect((6_000...8_500).contains(body.count), "\(body.count)")
        #expect(DraftDocumentRenderer.isMarkdown(body: body))
        let headings = DraftDocumentRenderer.blocks(from: body).filter {
            if case .heading = $0.kind { return true } else { return false }
        }
        #expect(headings.count == 10)
        let start = Date()
        let attributed = DraftDocumentRenderer.attributedString(from: body)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(attributed.string.contains("Problem 10") && attributed.string.contains("Q_{enc}"))
        #if canImport(UIKit)
        let pdfBytes = try #require(DraftDocumentRenderer.pdfData(forDraftBody: body))
        #expect(pdfBytes.starts(with: Data("%PDF".utf8)) && pdfBytes.count < 2_000_000)
        #else
        // macOS cannot paginate (the sheet offers no pdf there); a stand-in
        // carries the same path below.
        #expect(DraftDocumentRenderer.pdfData(forDraftBody: body) == nil)
        let pdfBytes = Data("%PDF-1.7 Problem Set 7 rendered on the phone".utf8)
        #endif

        // 4. A text draft on an upload-only, pdf-only assignment goes as a pdf.
        let rules = CanvasSubmissionRules(submissionTypes: ["online_upload"], allowedExtensions: [".PDF"])
        let acceptance = CanvasAcceptance.derive(rules)
        let item = AgentSnapshot.WorkItem(
            id: "event-assignment-7001", course: "PHYS 0151", title: "Problem Set 7", kind: .assignment,
            dueAt: now.addingTimeInterval(2 * 86_400), done: false, noSubmission: false,
            url: "https://canvas.upenn.edu/courses/1949400/assignments/7001", source: "canvas",
            canvasAssignmentID: "7001", canvasCourseID: "1949400")
        let draft = AgentDraft(id: "smd_ps7", assignmentID: item.id, kind: .text, body: body, clientName: "Claude")
        let submitPlan = DraftSubmitPlan.make(draft: draft, acceptance: acceptance, canRenderPDF: true)
        #expect(submitPlan.routes == [.pdf] && submitPlan.defaultRoute == .pdf && submitPlan.block == nil)
        // Sent as text, Canvas would refuse it before anything was recorded.
        #expect(!CanvasSubmissionClient.accepts(types: rules.submissionTypes, payload: .text(body), allowedExtensions: rules.allowedExtensions))

        // 5. The submitter sends online_upload with that PDF.
        let name = DraftDocumentRenderer.fileName(forTitle: item.title)
        #expect(name == "Problem Set 7.pdf")
        let s = Self.store(), probe = Probe()
        let preflight = #"{"submission_types":["online_upload"],"allowed_extensions":["pdf"],"locked_for_user":false,"submission":{"attempt":null}}"#
        Stub.reset(Self.canvas(store: s, draftID: draft.id, probe: probe, preflight: preflight))
        let c = Self.client()
        let reports = ReportLog()
        let result = await AgentDraftSubmitter.run(
            draft: draft, item: item, store: s, loadFile: { nil },
            submit: { course, assignment, payload, before in
                #expect(course == "1949400" && assignment == "7001")
                return await c.submit(courseID: course, assignmentID: assignment, payload: payload, beforeFirstPost: before)
            },
            report: { reports.add($0); return true },
            pdf: RenderedDraftPDF(name: name, data: pdfBytes), now: now)
        #expect(result == .submitted(verified: true))
        #expect(probe.recordAtFirstPost == true)
        #expect(reports.all == [.submitted(canvasSubmissionID: "357257138", attempt: 1)])

        let slot = try #require(Stub.canvasPosts.first { $0.url?.path.hasSuffix("/submissions/self/files") == true })
        let slotBody = try #require(JSONSerialization.jsonObject(with: slot.httpBody ?? Data()) as? [String: Any])
        #expect(slotBody["name"] as? String == "Problem Set 7.pdf")
        #expect(slotBody["content_type"] as? String == "application/pdf")
        #expect(slotBody["size"] as? Int == pdfBytes.count)

        let upload = try #require(Stub.posts.first { $0.url?.host == "files.example.net" })
        #expect(upload.value(forHTTPHeaderField: "Cookie") == nil && upload.value(forHTTPHeaderField: "X-CSRF-Token") == nil)
        #expect(upload.httpBody.map { $0.range(of: pdfBytes) != nil } == true, "the PDF's bytes are in the upload")

        let submission = try #require(Stub.canvasPosts.first { $0.url?.path.hasSuffix("/submissions") == true })
        let sent = try #require((JSONSerialization.jsonObject(with: submission.httpBody ?? Data()) as? [String: Any])?["submission"] as? [String: Any])
        #expect(sent["submission_type"] as? String == "online_upload")
        #expect(sent["file_ids"] as? [Int] == [555])
        #expect(sent["body"] == nil, "no text rides along with the file")
        #expect(s.record(for: draft.id)?.outcome == .submitted)
        #expect(s.record(for: draft.id)?.agentName == "Claude")
    }
}
