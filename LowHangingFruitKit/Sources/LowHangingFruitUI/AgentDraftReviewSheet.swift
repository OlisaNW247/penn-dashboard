import SwiftUI
import QuickLook
import LowHangingFruitKit

/// Which draft's review sheet is up; `Identifiable` for `.sheet(item:)`.
struct AgentDraftReview: Identifiable, Equatable {
    let draftID: String
    var id: String { draftID }
}

/// "drafted by claude": everything that will be sent, then Submit or Decline
/// (docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md, "The card"). The sheet shows
/// the content itself, not a summary of it, because the student is the one
/// putting their name on it: the whole text, the exact link, or the file with
/// a preview. One line says so in plain words. Submit asks once more.
///
/// The sheet reads the live draft from `AppState.agentDrafts` by id, so a
/// refetch (a cached draft with no content yet, or a file link past its two
/// minutes) redraws it in place. After a submit the draft leaves the list and
/// the sheet keeps its last copy to show the result.
struct AgentDraftReviewSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let draftID: String

    @State private var shown: AgentDraft?
    @State private var isWorking = false
    @State private var confirming = false
    @State private var outcome: Outcome?
    @State private var previewURL: URL?
    @State private var isLoadingPreview = false
    @State private var previewFailed = false
    /// The snapshot's item (its Canvas ids and link), worked out once when
    /// the sheet opens: building the snapshot reads the whole work list, which
    /// must not run on every render (CLAUDE.md, the freeze trap).
    @State private var snapshotItem: AgentSnapshot.WorkItem?
    @State private var resolved = false

    private enum Outcome: Equatable {
        case result(AgentSubmitResult)
        case declineFailed
    }

    private var draft: AgentDraft? {
        state.agentDrafts.first { $0.id == draftID } ?? shown
    }

    private var item: Assignment? {
        guard let draft else { return nil }
        return (state.assignments + state.laterAssignments + state.assessments).first { $0.id == draft.assignmentID }
    }

    private var unsupported: CanvasSubmissionClient.Refusal? {
        guard let draft else { return .missingIDs }
        return AgentDraftSubmitter.unsupportedReason(draft: draft, item: snapshotItem)
    }

    private var isFinished: Bool {
        switch outcome {
        case .result(.submitted)?, .result(.failed)?, .result(.checkCanvas)?: return true
        default: return state.agentSubmitAttempts.record(for: draftID) != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SmoothFormHeader(title: AgentConnectionCopy.draftedBy(draft?.agentName ?? "Claude"),
                                     accent: .smoothGrape, spark: .smoothTeal)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)

                if let item {
                    Section {
                        Text(item.title).font(.lhfSecondary(17, weight: .semibold))
                        Text(item.course.uppercased())
                            .font(.lhfMono(10, weight: .semibold))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    .smoothSectionBackground(.smoothGrape)
                }

                if let draft, let note = draft.note, !note.isEmpty {
                    Section {
                        Text(note).foregroundStyle(Color.smoothMuted)
                    } header: {
                        SmoothSectionHeader(AgentConnectionCopy.noteFrom(draft.agentName), accent: .smoothCobalt)
                    }
                    .smoothSectionBackground(.smoothGrape)
                }

                Section { content } .smoothSectionBackground(.smoothGrape)

                Section { actions } .smoothSectionBackground(.smoothGrape)
            }
            .formStyle(.grouped)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothGrape)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .quickLookPreview($previewURL)
            .confirmationDialog(AgentConnectionCopy.confirmSubmitTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(AgentConnectionCopy.submit) { submit() }
                Button(AgentConnectionCopy.cancel, role: .cancel) {}
            }
        }
        .lhfSheetTheme()
        .interactiveDismissDisabled(isWorking)
        .task {
            shown = draft
            if let d = draft { snapshotItem = state.agentSnapshotItem(for: d.assignmentID) }
            resolved = true
            // A draft from the cache has no content yet: ask for it now
            // rather than show an empty sheet.
            if let d = draft, d.preview() == nil || (d.kind == .file && d.fileURL == nil) {
                if let fresh = await state.refetchAgentDraft(d.id) { shown = fresh }
            }
        }
        .onChange(of: state.agentDrafts) { _, drafts in
            if let fresh = drafts.first(where: { $0.id == draftID }) { shown = fresh }
        }
        .onDisappear { removePreviewFile() }
#if os(macOS)
        .frame(minWidth: 380, minHeight: 520)
#endif
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch draft?.kind {
        case .text?:
            if let body = draft?.body {
                Text(body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(AgentConnectionCopy.loading).foregroundStyle(Color.smoothMuted)
            }
        case .url?:
            if let raw = draft?.url, let url = URL(string: raw) {
                Link(destination: url) {
                    Text(raw).underline().multilineTextAlignment(.leading)
                }
            } else {
                Text(AgentConnectionCopy.loading).foregroundStyle(Color.smoothMuted)
            }
        case .file?:
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft?.fileName ?? "")
                    if let bytes = draft?.fileBytes {
                        Text(AgentDraft.byteText(bytes))
                            .font(.lhfSecondary(12)).foregroundStyle(Color.smoothMuted)
                    }
                }
                Spacer()
                Button { openPreview() } label: {
                    HStack(spacing: 6) {
                        if isLoadingPreview { ProgressView().controlSize(.small) }
                        Text(AgentConnectionCopy.previewFile)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingPreview)
            }
            if previewFailed {
                Text(AgentConnectionCopy.fileUnavailable)
                    .font(.lhfSecondary(12)).foregroundStyle(Color.smoothTomatoInk)
            }
        case .unknown?, nil:
            Text(AgentConnectionCopy.unsupported).foregroundStyle(Color.smoothMuted)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        Text(AgentConnectionCopy.integrity)
            .font(.lhfSecondary(13, weight: .semibold))

        if let line = outcomeLine {
            Text(line.text)
                .font(.lhfSecondary(13))
                .foregroundStyle(line.isError ? Color.smoothTomatoInk : Color.smoothInk)
        }

        if !resolved {
            ProgressView()
        } else if isFinished {
            if let url = canvasURL {
                Link(AgentConnectionCopy.openInCanvas, destination: url)
                    .environment(\.openURL, CanvasAppLink.action)
            }
            Button(AgentConnectionCopy.done) { dismiss() }
        } else if unsupported == .unsupportedType || unsupported == .missingIDs {
            Text(AgentConnectionCopy.unsupported).foregroundStyle(Color.smoothMuted)
            if let url = canvasURL {
                Link(AgentConnectionCopy.openInCanvas, destination: url)
                    .environment(\.openURL, CanvasAppLink.action)
            }
            declineButton
        } else {
            Button { confirming = true } label: {
                HStack(spacing: 10) {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(isWorking ? AgentConnectionCopy.sending : AgentConnectionCopy.submit)
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.smoothGrape)
            .disabled(isWorking || draft == nil)
            declineButton
        }
    }

    private var declineButton: some View {
        Button(AgentConnectionCopy.decline, role: .destructive) { decline() }
            .disabled(isWorking)
    }

    private var canvasURL: URL? {
        if let raw = snapshotItem?.url, let url = URL(string: raw) {
            return url
        }
        return item?.url
    }

    private var outcomeLine: (text: String, isError: Bool)? {
        switch outcome {
        case .result(.submitted(let verified))?:
            return (verified ? AgentConnectionCopy.submitted : AgentConnectionCopy.submittedUnverified, false)
        case .result(.failed)?: return (AgentConnectionCopy.failed, true)
        case .result(.checkCanvas)?: return (AgentConnectionCopy.mayHaveGoneIn, true)
        case .result(.fileUnavailable)?: return (AgentConnectionCopy.fileUnavailable, true)
        case .result(.refused(let reason))?: return (Self.refusalText(reason), true)
        case .declineFailed?: return (AgentConnectionCopy.declineFailure, true)
        case nil:
            return state.agentSubmitAttempts.record(for: draftID) != nil ? (AgentConnectionCopy.mayHaveGoneIn, true) : nil
        }
    }

    static func refusalText(_ reason: CanvasSubmissionClient.Refusal) -> String {
        switch reason {
        case .unsupportedType, .missingIDs, .locked: return AgentConnectionCopy.unsupported
        case .sessionDead, .noCSRF: return AgentConnectionCopy.signInFirst
        case .offline: return AgentConnectionCopy.offline
        case .preflightFailed, .attemptNotRecorded: return AgentConnectionCopy.couldntSend
        }
    }

    private func submit() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let result = await state.submitAgentDraft(draftID)
            isWorking = false
            outcome = .result(result)
            lhfHapticLight()
        }
    }

    private func decline() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let ok = await state.declineAgentDraft(draftID)
            isWorking = false
            if ok { dismiss() } else { outcome = .declineFailed }
        }
    }

    // MARK: File preview

    private func openPreview() {
        guard let draft, !isLoadingPreview else { return }
        isLoadingPreview = true
        previewFailed = false
        Task {
            let data = await state.loadAgentDraftFile(draft)
            isLoadingPreview = false
            guard let data, let url = writePreviewFile(data, name: draft.fileName ?? "draft") else {
                previewFailed = true
                return
            }
            previewURL = url
        }
    }

    private var previewDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("smooth-draft-preview-\(draftID)", isDirectory: true)
    }

    /// The temporary copy QuickLook opens. Removed when the sheet goes away;
    /// the name keeps only its last path component, so a draft's file name
    /// can never point outside the folder.
    private func writePreviewFile(_ data: Data, name: String) -> URL? {
        let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let dir = previewDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(safe.isEmpty ? "draft" : safe)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func removePreviewFile() {
        try? FileManager.default.removeItem(at: previewDirectory)
    }
}
