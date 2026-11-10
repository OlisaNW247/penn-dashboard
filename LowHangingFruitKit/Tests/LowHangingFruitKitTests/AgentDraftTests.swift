import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Agent drafts: wire, cache, notices")
struct AgentDraftTests {
    static let wire = #"""
    {"drafts":[
     {"id":"smd_a","assignment_id":"canvas:event-assignment-15044550","kind":"text","body":"Line one\n\nLine two\nLine three\nLine four","url":null,"file_name":null,"mime_type":null,"file_bytes":null,"note":"I used the lecture 9 method","client_name":"Claude","status":"proposed","created_at":"2026-11-10T12:00:01.123456+00:00"},
     {"id":"smd_b","assignment_id":"canvas:2","kind":"file","body":null,"url":null,"file_name":"ps7.pdf","mime_type":"application/pdf","file_bytes":48213,"note":null,"client_name":null,"status":"seen","created_at":"2026-11-10T12:00:00Z","file_url":"https://x.supabase.co/storage/v1/object/sign/agent-drafts/u/d/ps7.pdf?token=t"},
     {"id":"smd_c","assignment_id":"canvas:3","kind":"video","status":"later","created_at":"nonsense"}
    ]}
    """#

    struct Envelope: Decodable { let drafts: [AgentDraft] }

    @Test("decodes the server's snake_case shape, leniently")
    func decode() throws {
        let drafts = try BackendJSON.decoder().decode(Envelope.self, from: Data(Self.wire.utf8)).drafts
        #expect(drafts.count == 3)
        let a = drafts[0]
        #expect(a.assignmentID == "canvas:event-assignment-15044550")
        #expect(a.kind == .text && a.status == .proposed && a.status.isOpen)
        #expect(a.note == "I used the lecture 9 method")
        #expect(a.agentName == "Claude")
        let b = drafts[1]
        #expect(b.kind == .file && b.fileBytes == 48213 && b.fileURL?.hasPrefix("https://") == true)
        #expect(b.agentName == "Claude", "no client name falls back to Claude")
        let c = drafts[2]
        #expect(c.kind == .unknown && c.status == .unknown && !c.status.isOpen)
        #expect(c.createdDate == nil)
    }

    @Test("previews: the first lines, the link, the file and its size")
    func previews() {
        let text = AgentDraft(id: "1", assignmentID: "a", kind: .text, body: "  \nOne\n\nTwo\nThree\nFour")
        #expect(text.preview() == "One\nTwo\nThree")
        let long = AgentDraft(id: "1", assignmentID: "a", kind: .text, body: String(repeating: "x", count: 500))
        #expect(long.preview()?.count == 241)
        #expect(AgentDraft(id: "1", assignmentID: "a", kind: .url, url: "https://a.b/c").preview() == "https://a.b/c")
        let file = AgentDraft(id: "1", assignmentID: "a", kind: .file, fileName: "ps7.pdf", fileBytes: 2_000_000)
        #expect(file.preview()?.hasPrefix("ps7.pdf \u{00B7} ") == true)
        #expect(AgentDraft(id: "1", assignmentID: "a", kind: .text).preview() == nil)
    }

    @Test("the cache keeps no content and no signed URL")
    func cacheStrips() throws {
        let full = AgentDraft(id: "1", assignmentID: "a", kind: .file, body: "secret", url: "https://u",
                              fileName: "f.pdf", fileBytes: 3, note: "n", clientName: "Claude",
                              status: .seen, fileURL: "https://signed?token=t")
        let decided = AgentDraft(id: "2", assignmentID: "b", kind: .text, status: .declined)
        let data = try #require(AgentDraftCache.encode([full, decided]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret") && !text.contains("token") && !text.contains("\"n\""))
        let back = AgentDraftCache.decode(data)
        #expect(back.map(\.id) == ["1"], "only open drafts are cached")
        #expect(back[0].fileName == "f.pdf" && back[0].clientName == "Claude" && back[0].body == nil && back[0].fileURL == nil)
        #expect(AgentDraftCache.decode(nil).isEmpty)
        #expect(AgentDraftCache.decode(Data("junk".utf8)).isEmpty)
    }

    @Test("a notice once per draft, only for a card that exists, and the memory is bounded")
    func notices() {
        let drafts = [
            AgentDraft(id: "d1", assignmentID: "a1", kind: .text, clientName: "Claude"),
            AgentDraft(id: "d2", assignmentID: "missing", kind: .text),
            AgentDraft(id: "d3", assignmentID: "a1", kind: .text, status: .declined),
        ]
        let titles = ["a1": "Problem Set 7"]
        let first = AgentDraftNotices.plan(drafts: drafts, alreadyNotified: []) { titles[$0] }
        #expect(first.notices.map(\.title) == ["Claude drafted Problem Set 7"])
        #expect(first.remembered == ["d1", "d2"], "an unmatched draft is remembered so it never announces late")
        let second = AgentDraftNotices.plan(drafts: drafts, alreadyNotified: first.remembered) { titles[$0] }
        #expect(second.notices.isEmpty)

        let many = (0..<250).map { "old\($0)" }
        let bounded = AgentDraftNotices.plan(drafts: [drafts[0]], alreadyNotified: many) { titles[$0] }
        #expect(bounded.remembered.count == AgentDraftNotices.maxRemembered)
        #expect(bounded.remembered.last == "d1")
    }
}

@Suite("Agent submit attempt store")
struct AgentSubmitAttemptStoreTests {
    func store() -> (AgentSubmitAttemptStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttemptStoreTests-\(UUID().uuidString)/attempts.json")
        return (AgentSubmitAttemptStore(fileURL: url), url)
    }

    @Test("begin writes to disk at once; a second begin throws; a new instance sees it")
    func neverTwice() throws {
        let (s, url) = store()
        try s.begin(draftID: "d", assignmentID: "a", now: Date(timeIntervalSince1970: 100))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(throws: AgentSubmitAttemptStore.StoreError.alreadyAttempted) {
            try s.begin(draftID: "d", assignmentID: "a")
        }
        let reopened = AgentSubmitAttemptStore(fileURL: url)
        #expect(reopened.record(for: "d")?.startedAt == Date(timeIntervalSince1970: 100))
        #expect(throws: AgentSubmitAttemptStore.StoreError.alreadyAttempted) {
            try reopened.begin(draftID: "d", assignmentID: "a")
        }
    }

    @Test("finish and markReported update the record and never remove it")
    func finish() throws {
        let (s, _) = store()
        try s.begin(draftID: "d", assignmentID: "a")
        s.finish(draftID: "d", outcome: .submitted, canvasSubmissionID: "987", attempt: 2)
        #expect(s.record(for: "d")?.outcome == .submitted)
        #expect(s.record(for: "d")?.reported == false)
        s.markReported(draftID: "d")
        #expect(s.record(for: "d")?.reported == true)
        #expect(s.record(for: "d")?.canvasSubmissionID == "987")
        s.finish(draftID: "nobody", outcome: .failed)
        #expect(s.record(for: "nobody") == nil)
    }

    @Test("an unreadable file refuses every new attempt")
    func corrupt() throws {
        let (s, url) = store()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(throws: AgentSubmitAttemptStore.StoreError.writeFailed) {
            try s.begin(draftID: "d", assignmentID: "a")
        }
    }

    @Test("removeAll forgets everything")
    func removeAll() throws {
        let (s, _) = store()
        try s.begin(draftID: "d", assignmentID: "a")
        s.removeAll()
        #expect(s.record(for: "d") == nil)
        #expect(s.all().isEmpty)
    }
}

@Suite("Agent draft submitter")
struct AgentDraftSubmitterTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var submits = 0
        private var reports: [AgentDraftDecision] = []
        func submitted() { lock.lock(); submits += 1; lock.unlock() }
        func reported(_ d: AgentDraftDecision) { lock.lock(); reports.append(d); lock.unlock() }
        var submitCount: Int { lock.lock(); defer { lock.unlock() }; return submits }
        var reportList: [AgentDraftDecision] { lock.lock(); defer { lock.unlock() }; return reports }
    }

    static let item = AgentSnapshot.WorkItem(
        id: "canvas:x", course: "PHYS 0151", title: "Problem Set 7", kind: .assignment, dueAt: nil,
        done: false, noSubmission: false, url: nil, source: "canvas",
        canvasAssignmentID: "34", canvasCourseID: "12")
    static let draft = AgentDraft(id: "smd_1", assignmentID: "canvas:x", kind: .text, body: "answer")

    func store() -> AgentSubmitAttemptStore {
        AgentSubmitAttemptStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("SubmitterTests-\(UUID().uuidString)/a.json"))
    }

    func run(_ outcome: CanvasSubmissionClient.Outcome, draft: AgentDraft = draft,
             item: AgentSnapshot.WorkItem? = item, store: AgentSubmitAttemptStore, calls: Calls,
             reportOK: Bool = true, file: Data? = nil) async -> AgentSubmitResult {
        await AgentDraftSubmitter.run(
            draft: draft, item: item, store: store,
            loadFile: { file },
            submit: { course, assignment, _, before in
                #expect(course == "12" && assignment == "34")
                do { try before() } catch { return .refused(.attemptNotRecorded) }
                calls.submitted()
                return outcome
            },
            report: { decision in calls.reported(decision); return reportOK })
    }

    @Test("a second submit of the same draft never reaches Canvas, whatever happened the first time",
          arguments: [
            CanvasSubmissionClient.Outcome.submitted(submissionID: "9", attempt: 1, verified: true),
            .failed(errorClass: "rejected_422"), .indeterminate,
          ])
    func neverTwice(first: CanvasSubmissionClient.Outcome) async {
        let s = store(), calls = Calls()
        _ = await run(first, store: s, calls: calls)
        #expect(calls.submitCount == 1)
        let again = await run(.submitted(submissionID: "10", attempt: 2, verified: true), store: s, calls: calls)
        #expect(again == .checkCanvas)
        #expect(calls.submitCount == 1)
    }

    @Test("outcomes are recorded, then reported")
    func mapping() async {
        var s = store(); var calls = Calls()
        #expect(await run(.submitted(submissionID: "9", attempt: 1, verified: false), store: s, calls: calls) == .submitted(verified: false))
        #expect(calls.reportList == [.submitted(canvasSubmissionID: "9", attempt: 1)])
        #expect(s.record(for: "smd_1")?.reported == true)

        s = store(); calls = Calls()
        #expect(await run(.failed(errorClass: "rejected_422"), store: s, calls: calls) == .failed)
        #expect(calls.reportList == [.failed(errorClass: "rejected_422")])

        s = store(); calls = Calls()
        #expect(await run(.indeterminate, store: s, calls: calls) == .checkCanvas)
        #expect(calls.reportList.isEmpty, "only Canvas knows: nothing is reported")
        #expect(s.record(for: "smd_1")?.outcome == .indeterminate)

        s = store(); calls = Calls()
        #expect(await run(.refused(.locked), store: s, calls: calls) == .refused(.locked))
        #expect(calls.reportList.isEmpty)
    }

    @Test("a report the server did not take is kept for the drafts pass to resend")
    func pendingReport() async {
        let s = store(), calls = Calls()
        _ = await run(.submitted(submissionID: "9", attempt: 3, verified: true), store: s, calls: calls, reportOK: false)
        let record = s.record(for: "smd_1")!
        #expect(!record.reported)
        #expect(AgentDraftSubmitter.pendingReport(for: record) == .submitted(canvasSubmissionID: "9", attempt: 3))
        s.markReported(draftID: "smd_1")
        #expect(AgentDraftSubmitter.pendingReport(for: s.record(for: "smd_1")!) == nil)
    }

    @Test("refused up front: no ids, quizzes, nothing to submit, Gradescope, unknown kinds")
    func upFront() async {
        var noIDs = Self.item; noIDs.canvasCourseID = nil
        var quiz = Self.item; quiz.kind = .quiz
        var nothing = Self.item; nothing.noSubmission = true
        var gradescope = Self.item; gradescope.source = "gradescope"
        #expect(AgentDraftSubmitter.unsupportedReason(draft: Self.draft, item: nil) == .missingIDs)
        #expect(AgentDraftSubmitter.unsupportedReason(draft: Self.draft, item: noIDs) == .missingIDs)
        #expect(AgentDraftSubmitter.unsupportedReason(draft: Self.draft, item: quiz) == .unsupportedType)
        #expect(AgentDraftSubmitter.unsupportedReason(draft: Self.draft, item: nothing) == .unsupportedType)
        #expect(AgentDraftSubmitter.unsupportedReason(draft: Self.draft, item: gradescope) == .unsupportedType)
        let unknown = AgentDraft(id: "x", assignmentID: "canvas:x", kind: .unknown)
        #expect(AgentDraftSubmitter.unsupportedReason(draft: unknown, item: Self.item) == .unsupportedType)
        #expect(AgentDraftSubmitter.unsupportedReason(draft: Self.draft, item: Self.item) == nil)

        let calls = Calls()
        #expect(await run(.indeterminate, item: quiz, store: store(), calls: calls) == .refused(.unsupportedType))
        #expect(calls.submitCount == 0)
    }

    @Test("a file draft needs its bytes; without them nothing is attempted")
    func fileNeedsBytes() async {
        let fileDraft = AgentDraft(id: "f", assignmentID: "canvas:x", kind: .file, fileName: "a.pdf", mimeType: "application/pdf")
        let s = store(), calls = Calls()
        #expect(await run(.indeterminate, draft: fileDraft, store: s, calls: calls, file: nil) == .fileUnavailable)
        #expect(calls.submitCount == 0 && s.record(for: "f") == nil)
        #expect(await run(.submitted(submissionID: "1", attempt: 1, verified: true), draft: fileDraft,
                          store: s, calls: calls, file: Data("x".utf8)) == .submitted(verified: true))
    }

    @Test("payloads: an empty body or a non-https link is no payload")
    func payloads() {
        #expect(AgentDraftSubmitter.payload(for: AgentDraft(id: "1", assignmentID: "a", kind: .text, body: "  "), fileData: nil) == nil)
        #expect(AgentDraftSubmitter.payload(for: AgentDraft(id: "1", assignmentID: "a", kind: .url, url: "http://a.b"), fileData: nil) == nil)
        #expect(AgentDraftSubmitter.payload(for: AgentDraft(id: "1", assignmentID: "a", kind: .url, url: "https://a.b"), fileData: nil)
            == .url(URL(string: "https://a.b")!))
    }
}
