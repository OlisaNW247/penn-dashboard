import Foundation

/// The decision the phone writes back to `agent-snapshot`'s `draft` action.
public enum AgentDraftDecision: Equatable, Sendable {
    case seen
    case declined
    case submitted(canvasSubmissionID: String, attempt: Int?)
    case failed(errorClass: String)

    public var status: String {
        switch self {
        case .seen: return "seen"
        case .declined: return "declined"
        case .submitted: return "submitted"
        case .failed: return "failed"
        }
    }
}

/// What the review sheet shows after Submit.
public enum AgentSubmitResult: Equatable, Sendable {
    case submitted(verified: Bool)
    /// Canvas made nothing; the draft is marked failed.
    case failed
    /// Nothing was sent; the draft stays open. The reason is the client's.
    case refused(CanvasSubmissionClient.Refusal)
    /// The file could not be fetched from the signed URL (after one refetch).
    case fileUnavailable
    /// A POST went out with no answer, or this draft was already tried:
    /// check Canvas. Never retried.
    case checkCanvas
}

/// Draft in, one Canvas submission at most out. Pure orchestration over
/// injected pieces, so the never-twice rule and the outcome mapping are
/// tested without a network or an `AppState`.
///
/// The order is the design: (1) an existing attempt record ends it at once,
/// whatever the draft's server status; (2) the snapshot item must name both
/// Canvas ids and be a kind that takes a submission; (3) the content is
/// assembled, the file fetched; (4) the client runs, writing the record in
/// `beforeFirstPost`; (5) the outcome is recorded locally, then reported.
/// A failed report changes nothing the student sees: the record says what
/// happened, and the drafts pass re-sends the report later.
public enum AgentDraftSubmitter {
    public typealias Submit = @Sendable (
        _ courseID: String, _ assignmentID: String, _ payload: CanvasSubmissionClient.Payload,
        _ beforeFirstPost: () throws -> Void
    ) async -> CanvasSubmissionClient.Outcome

    /// Why a draft cannot be sent from the phone at all, judged from the
    /// snapshot item before the sheet offers Submit. Nil when it can.
    public static func unsupportedReason(draft: AgentDraft, item: AgentSnapshot.WorkItem?) -> CanvasSubmissionClient.Refusal? {
        guard let item else { return .missingIDs }
        guard item.canvasCourseID != nil, item.canvasAssignmentID != nil else { return .missingIDs }
        guard item.source == Assignment.Source.canvas.rawValue
                || item.source == Assignment.Source.canvasModules.rawValue else { return .unsupportedType }
        guard item.kind == .assignment || item.kind == .other, !item.noSubmission else { return .unsupportedType }
        guard draft.kind != .unknown else { return .unsupportedType }
        return nil
    }

    public static func payload(for draft: AgentDraft, fileData: Data?) -> CanvasSubmissionClient.Payload? {
        switch draft.kind {
        case .text:
            guard let body = draft.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .text(body)
        case .url:
            guard let raw = draft.url, let url = URL(string: raw), url.scheme == "https" else { return nil }
            return .url(url)
        case .file:
            guard let fileData, !fileData.isEmpty, let name = draft.fileName, !name.isEmpty else { return nil }
            return .file(name: name, mimeType: draft.mimeType ?? "application/octet-stream", data: fileData)
        case .unknown:
            return nil
        }
    }

    public static func run(
        draft: AgentDraft,
        item: AgentSnapshot.WorkItem?,
        store: AgentSubmitAttemptStore,
        loadFile: @Sendable () async -> Data?,
        submit: Submit,
        report: @Sendable (AgentDraftDecision) async -> Bool,
        pdf: RenderedDraftPDF? = nil,
        now: Date = Date()
    ) async -> AgentSubmitResult {
        if store.record(for: draft.id) != nil { return .checkCanvas }
        if let reason = unsupportedReason(draft: draft, item: item) { return .refused(reason) }
        guard let item, let courseID = item.canvasCourseID, let assignmentID = item.canvasAssignmentID else {
            return .refused(.missingIDs)
        }

        var fileData: Data?
        if draft.kind == .file {
            fileData = await loadFile()
            if fileData == nil { return .fileUnavailable }
        }
        // A text draft the student chose to send as a PDF goes through the
        // same file path, attempt record and never-twice rule as any file.
        let built: CanvasSubmissionClient.Payload?
        if draft.kind == .text, let pdf {
            built = pdf.data.isEmpty ? nil : .file(name: pdf.name, mimeType: DraftDocumentRenderer.pdfMimeType, data: pdf.data)
        } else {
            built = payload(for: draft, fileData: fileData)
        }
        guard let payload = built else { return .refused(.unsupportedType) }

        let outcome = await submit(courseID, assignmentID, payload) {
            try store.begin(draftID: draft.id, assignmentID: draft.assignmentID, agentName: draft.agentName, now: now)
        }

        switch outcome {
        case let .submitted(submissionID, attempt, verified):
            store.finish(draftID: draft.id, outcome: .submitted, canvasSubmissionID: submissionID, attempt: attempt)
            if await report(.submitted(canvasSubmissionID: submissionID, attempt: attempt)) {
                store.markReported(draftID: draft.id)
            }
            return .submitted(verified: verified)
        case let .failed(errorClass):
            let short = String(errorClass.prefix(64))
            store.finish(draftID: draft.id, outcome: .failed, errorClass: short)
            if await report(.failed(errorClass: short)) { store.markReported(draftID: draft.id) }
            return .failed
        case .refused(let refusal):
            // `beforeFirstPost` never ran, or threw: no record was written
            // (or the one it found is the never-twice rule speaking).
            if refusal == .attemptNotRecorded, store.record(for: draft.id) != nil { return .checkCanvas }
            return .refused(refusal)
        case .indeterminate:
            store.finish(draftID: draft.id, outcome: .indeterminate)
            return .checkCanvas
        }
    }

    /// The report the drafts pass re-sends for a record whose outcome the
    /// server never acknowledged. Indeterminate records have none: only the
    /// student, looking at Canvas, knows.
    public static func pendingReport(for record: AgentSubmitAttemptStore.Record) -> AgentDraftDecision? {
        guard !record.reported, let outcome = record.outcome else { return nil }
        switch outcome {
        case .submitted:
            guard let id = record.canvasSubmissionID else { return nil }
            return .submitted(canvasSubmissionID: id, attempt: record.attempt)
        case .failed:
            return .failed(errorClass: record.errorClass ?? "failed")
        case .indeterminate:
            return nil
        }
    }
}
