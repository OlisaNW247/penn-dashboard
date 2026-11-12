import SwiftUI
import QuickLook
import LowHangingFruitKit

/// Which draft's review sheet is up; `Identifiable` for `.sheet(item:)`.
struct AgentDraftReview: Identifiable, Equatable {
    let draftID: String
    var id: String { draftID }
}

/// "drafted by claude": the draft, what Canvas takes for this assignment, the
/// one choice there is, then submit or decline.
///
/// Redesigned 2026-11-11 after Marco's phone: a plain-text draft on PHYS 0151
/// "Problem Set 7" (Canvas takes `online_upload` only) opened, Submit ran the
/// preflight, the preflight refused the text, and the sheet printed "submit
/// this one in canvas", which read as "review and submit didn't work". Now the
/// sheet asks Canvas what it takes when it opens (`agentDraftAcceptance`, the
/// same GET the submit makes first, once per draft), says it in one line, and
/// shapes the choice to it (`DraftSubmitPlan`): any text draft on a file-only
/// assignment goes as a pdf rendered on the phone, shown inline page by page,
/// so a refusal for the kind of draft is no longer reachable for text.
///
/// Top to bottom (trimmed 2026-11-11, Marco: "a lot of needless text in the
/// submission"): the class in its accent and the assignment title; "drafted
/// by claude"; the agent's note behind a collapsed "note" disclosure
/// (always, since 2026-11-11); the draft itself, full width (the text in the
/// body face, or the rendered pages; a link as a tappable row; a file as a
/// row with its name, size and a QuickLook preview); ONE status line
/// (`DraftReviewStatus`: a spinner while Canvas is asked, then what Canvas
/// takes, or the refusal or outcome in its place, never two); the text / pdf
/// picker only when both go; then, pinned at the bottom, "submit to canvas"
/// (a confirmation that names the kind, "send problem set 7 as a pdf?", and
/// says nothing else) and "decline". When the phone
/// cannot send it, "open in canvas" takes the submit's place.
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
    /// What Canvas takes; nil while the early read is out.
    @State private var lookup: AgentAcceptanceLookup?
    /// The route the student picked; nil until they pick, so the plan's
    /// default holds until a tap.
    @State private var pickedRoute: DraftSubmitRoute?
    @State private var pdf: RenderedDraftPDF?
    @State private var pdfFailed = false
    @State private var renderedBody: String?

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

    private var acceptance: CanvasAcceptance? {
        if case .known(let a)? = lookup { return a }
        return nil
    }

    /// The plan, with the pdf route taken out if the render failed.
    private var plan: DraftSubmitPlan? {
        guard let draft, lookup != nil else { return nil }
        var plan = DraftSubmitPlan.make(draft: draft, acceptance: acceptance, canRenderPDF: DraftDocumentRenderer.canRender)
        if pdfFailed {
            plan.routes.removeAll { $0 == .pdf }
            if plan.defaultRoute == .pdf { plan.defaultRoute = plan.routes.first }
        }
        return plan
    }

    private var route: DraftSubmitRoute? {
        guard let plan else { return nil }
        if let pickedRoute, plan.routes.contains(pickedRoute) { return pickedRoute }
        return plan.defaultRoute
    }

    private var isFinished: Bool {
        switch outcome {
        case .result(.submitted)?, .result(.failed)?, .result(.checkCanvas)?: return true
        default: return state.agentSubmitAttempts.record(for: draftID) != nil
        }
    }

    private var title: String { item?.title ?? snapshotItem?.title ?? "" }
    private var course: String { item?.course ?? snapshotItem?.course ?? "" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                        .padding(.top, 22)
                    statusLine
                        .padding(.top, 18)
                    picker
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) { actions }
            .background(Color.smoothPaper.ignoresSafeArea())
            .foregroundStyle(Color.smoothInk)
            .tint(Color.smoothGrapeInk)
            .overlay {
                if case .result(.submitted(verified: true))? = outcome { submittedState }
            }
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .quickLookPreview($previewURL)
            // The question alone: it names the assignment and the kind,
            // which is all there is to confirm.
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(AgentConnectionCopy.send) { submit() }
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
            if let d = draft { lookup = await state.agentDraftAcceptance(for: d, item: snapshotItem) }
            await prepareDocument()
            #if DEBUG
            // The screenshot harness's result states (AppState+AgentDemo.swift).
            if let demoOutcome = state.debugAgentDemo?.initialOutcome { outcome = .result(demoOutcome) }
            #endif
        }
        .onChange(of: state.agentDrafts) { _, drafts in
            if let fresh = drafts.first(where: { $0.id == draftID }) { shown = fresh }
        }
        .onChange(of: draft?.body) { _, _ in
            Task { await prepareDocument() }
        }
        .onDisappear { removePreviewFile() }
#if os(macOS)
        .frame(minWidth: 380, minHeight: 560)
#endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !course.isEmpty {
                Text(course.uppercased())
                    .font(.lhfMono(10.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(courseAccentInk(for: course))
            }
            Text(title)
                .font(.lhfAssignmentTitle(24))
                .fixedSize(horizontal: false, vertical: true)
            Text(AgentConnectionCopy.draftedBy(draft?.agentName ?? "Claude"))
                .font(.lhfSecondary(13, weight: .semibold))
                .foregroundStyle(Color.smoothGrapeInk)
            if let note = draft?.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                let noteText = Text(note)
                    .font(.lhfSecondary(14))
                    .foregroundStyle(Color.smoothMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(AgentConnectionCopy.noteFrom(draft?.agentName ?? "Claude")): \(note)")
                // Always folded (2026-11-11): the note is the agent's own
                // explanation, the kind of text Marco wants off the screen
                // until asked for, so even a short one is a tap away.
                DisclosureGroup {
                    noteText.padding(.top, 4)
                } label: {
                    Text(AgentConnectionCopy.note)
                        .font(.lhfSecondary(13, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                }
                .tint(Color.smoothMuted)
            }
        }
    }

    // MARK: The draft

    @ViewBuilder
    private var content: some View {
        switch draft?.kind {
        case .text?:
            if let body = draft?.body {
                if route == .pdf, let pdf {
                    VStack(alignment: .leading, spacing: 0) {
                        DraftPDFView(data: pdf.data)
                            .frame(height: 480)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.smoothRule, lineWidth: 1.25)
                            }
                    }
                } else if route == .pdf, !pdfFailed {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Text(body)
                        .font(.lhfSecondary(16))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                loadingLine
            }
        case .url?:
            if let raw = draft?.url, let url = URL(string: raw) {
                Link(destination: url) {
                    row(icon: "link", title: raw, detail: nil, trailing: "arrow.up.right")
                }
                .buttonStyle(.plain)
            } else {
                loadingLine
            }
        case .file?:
            Button { openPreview() } label: {
                row(icon: "doc", title: draft?.fileName ?? "",
                    detail: draft?.fileBytes.map(AgentDraft.byteText),
                    trailing: nil, trailingText: AgentConnectionCopy.previewFile, busy: isLoadingPreview)
            }
            .buttonStyle(.plain)
            .disabled(isLoadingPreview)
        case .unknown?, nil:
            Text(AgentConnectionCopy.unknownKind).foregroundStyle(Color.smoothMuted)
        }
    }

    private var loadingLine: some View {
        Text(AgentConnectionCopy.loading)
            .font(.lhfSecondary(14))
            .foregroundStyle(Color.smoothMuted)
    }

    /// A link or a file: one 56pt row in a ruled squircle.
    private func row(icon: String, title: String, detail: String?, trailing: String?,
                     trailingText: String? = nil, busy: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.smoothGrapeInk)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.lhfSecondary(15, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail).font(.lhfMono(10)).foregroundStyle(Color.smoothMuted)
                }
            }
            Spacer(minLength: 8)
            if busy { ProgressView().controlSize(.small) }
            if let trailingText {
                Text(trailingText).font(.lhfSecondary(13, weight: .semibold)).foregroundStyle(Color.smoothGrapeInk)
            }
            if let trailing {
                Image(systemName: trailing)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.smoothMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.smoothRule, lineWidth: 1.25)
        }
        .contentShape(Rectangle())
    }

    // MARK: The one status line

    private var status: DraftReviewStatus {
        DraftReviewStatus.resolve(
            outcome: outcomeText,
            outcomeTone: outcome == .result(.submitted(verified: false)) ? .plain : .problem,
            isFinished: isFinished,
            lookup: lookup,
            block: plan?.block,
            noRouteLeft: plan?.routes.isEmpty == true && pdfFailed
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .none:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
                .accessibilityLabel(Text(AgentConnectionCopy.loading))
        case let .line(text, tone):
            Text(text)
                .font(.lhfSecondary(14, weight: tone == .plain ? .semibold : .regular))
                .foregroundStyle(tone == .problem ? Color.smoothTomatoInk
                                 : tone == .muted ? Color.smoothMuted : Color.smoothInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The second line, for a block the "canvas takes" line does not
    /// already say (not online and locked are that line).
    static func blockText(_ block: DraftSubmitPlan.Block) -> String? {
        switch block {
        case .notOnline, .locked: return nil
        case let .fileType(ext, allowed): return AgentConnectionCopy.fileTypeRefused(ext, allowed: allowed)
        case .kind(let kind): return AgentConnectionCopy.kindRefused(kind)
        case .unknownKind: return AgentConnectionCopy.unknownKind
        }
    }

    // MARK: The choice

    private enum SendAs: String, CaseIterable, Identifiable {
        case text, pdf
        var id: String { rawValue }
        var route: DraftSubmitRoute { self == .text ? .text : .pdf }
    }

    @ViewBuilder
    private var picker: some View {
        if !isFinished, let plan, plan.routes.contains(.text), plan.routes.contains(.pdf) {
            SmoothSegmentPicker(
                selection: Binding(
                    get: { route == .pdf ? SendAs.pdf : SendAs.text },
                    set: { pickedRoute = $0.route }
                ),
                label: { $0 == .text ? AgentConnectionCopy.sendAsText : AgentConnectionCopy.sendAsPDF }
            )
            .disabled(isWorking)
            .padding(.top, 14)
        }
    }

    // MARK: Rendering

    /// Renders the body to a pdf once per distinct body, whenever the plan
    /// offers the pdf route (any text draft, markdown or not). A failure
    /// drops the pdf route and says so in one line.
    private func prepareDocument() async {
        guard let d = draft, d.kind == .text, let body = d.body, body != renderedBody,
              DraftDocumentRenderer.canRender else { return }
        renderedBody = body
        pdf = nil
        pdfFailed = false
        SmoothFonts.ensureRegistered()
        let name = DraftDocumentRenderer.fileName(forTitle: title.isEmpty ? "draft" : title)
        let format = d.format
        let data = await Task.detached { DraftDocumentRenderer.pdfData(forDraftBody: body, format: format) }.value
        if let data {
            pdf = RenderedDraftPDF(name: name, data: data)
        } else {
            pdfFailed = true
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            if !resolved {
                ProgressView()
            } else if isFinished {
                if let url = canvasURL, outcome != .result(.submitted(verified: true)) {
                    openInCanvasLink(url)
                }
                Button { dismiss() } label: { plainLabel(AgentConnectionCopy.done) }
                    .buttonStyle(.plain)
            } else {
                if canSubmit {
                    Button { confirming = true } label: {
                        HStack(spacing: 10) {
                            if isWorking { ProgressView().controlSize(.small).tint(Self.onGrape) }
                            Text(isWorking ? AgentConnectionCopy.sending : AgentConnectionCopy.submit)
                        }
                        .font(.lhfSans(16, weight: .semibold))
                        .foregroundStyle(Self.onGrape)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Self.squircle.fill(Color.smoothGrape))
                        .contentShape(Self.squircle)
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                } else if let url = canvasURL, lookup != nil {
                    openInCanvasLink(url)
                }
                Button { decline() } label: { plainLabel(AgentConnectionCopy.decline) }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.smoothPaper.ignoresSafeArea())
        .overlay(alignment: .top) { Rectangle().fill(Color.smoothRule.opacity(0.65)).frame(height: 0.5) }
    }

    /// Ink that reads on the grape fill in both modes.
    private static let onGrape = Color(hex: 0x1B1714)
    private static let squircle = RoundedRectangle(cornerRadius: 48 * 0.32, style: .continuous)

    private func plainLabel(_ text: String) -> some View {
        Text(text)
            .font(.lhfSans(15, weight: .medium))
            .foregroundStyle(Color.smoothInk)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
    }

    private func openInCanvasLink(_ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 5) {
                Text(AgentConnectionCopy.openInCanvas)
                    .font(.lhfSecondary(14, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.smoothGrapeInk)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.openURL, CanvasAppLink.action)
    }

    /// Submit shows only once Canvas's answer is in (or could not be had)
    /// and the plan has a route with its content ready.
    private var canSubmit: Bool {
        guard draft != nil, let plan, plan.block == nil, let route else { return false }
        if route == .pdf { return pdf != nil }
        return true
    }

    private var confirmTitle: String {
        AgentConnectionCopy.confirmSend(title.isEmpty ? "this" : title, as: route ?? .text, fileName: draft?.fileName)
    }

    private var canvasURL: URL? {
        #if DEBUG
        if state.debugAgentDemo != nil { return URL(string: "https://canvas.upenn.edu/courses/900001/assignments/1") }
        #endif
        if let raw = snapshotItem?.url, let url = URL(string: raw) {
            return url
        }
        return item?.url
    }

    private var outcomeText: String? {
        switch outcome {
        case .result(.submitted(verified: true))?: return nil
        case .result(.submitted(verified: false))?: return AgentConnectionCopy.submittedUnverified
        case .result(.failed)?: return AgentConnectionCopy.failed
        case .result(.checkCanvas)?: return AgentConnectionCopy.mayHaveGoneIn
        case .result(.fileUnavailable)?: return AgentConnectionCopy.fileUnavailable
        case .result(.refused(let reason))?: return Self.refusalText(reason)
        case .declineFailed?: return AgentConnectionCopy.declineFailure
        case nil:
            if state.agentSubmitAttempts.record(for: draftID) != nil { return AgentConnectionCopy.mayHaveGoneIn }
            return previewFailed ? AgentConnectionCopy.fileUnavailable : nil
        }
    }

    /// What happened and what to do next, in one line.
    static func refusalText(_ reason: CanvasSubmissionClient.Refusal) -> String {
        switch reason {
        case .offline: return AgentConnectionCopy.offline
        case .sessionDead, .noCSRF: return AgentConnectionCopy.signInFirst
        case .locked: return AgentConnectionCopy.locked
        case .unsupportedType, .missingIDs: return AgentConnectionCopy.notOnline
        case .preflightFailed: return AgentConnectionCopy.couldntReach
        case .attemptNotRecorded: return AgentConnectionCopy.couldntReach
        }
    }

    // MARK: Submitted

    /// Canvas took it and the read-back confirmed it. An unconfirmed submit
    /// stays on the sheet with "submitted · check canvas to be sure" in the
    /// status line, open in canvas and done.
    private var submittedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Color.smoothTeal)
                .accessibilityHidden(true)
            Text(AgentConnectionCopy.submitted)
                .font(.lhfSecondary(22, weight: .semibold))
            Button { dismiss() } label: {
                Text(AgentConnectionCopy.done)
                    .font(.lhfSans(16, weight: .semibold))
                    .foregroundStyle(Self.onGrape)
                    .frame(width: 160, height: 48)
                    .background(Self.squircle.fill(Color.smoothTeal))
                    .contentShape(Self.squircle)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .foregroundStyle(Color.smoothInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.smoothPaper.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        guard !isWorking, let route else { return }
        isWorking = true
        let chosen = route == .pdf ? pdf : nil
        Task {
            let result = await state.submitAgentDraft(draftID, pdf: chosen)
            isWorking = false
            // A refusal about what Canvas takes reshapes the sheet instead of
            // printing a second line: the "canvas takes" line then says it.
            var reshaped = false
            switch result {
            case .refused(.locked):
                lookup = .known(.locked); reshaped = true
            case .refused(.missingIDs):
                lookup = .known(.notOnline); reshaped = true
            case .refused(.unsupportedType):
                // The answer the sheet was shaped by was out of date: ask
                // Canvas again, live, and reshape the sheet to what it says.
                if let d = draft {
                    let fresh = await state.agentDraftAcceptance(for: d, item: snapshotItem, forceLive: true)
                    if case .known = fresh { lookup = fresh; reshaped = true }
                }
            default:
                break
            }
            outcome = reshaped ? nil : .result(result)
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

/// The review sheet's one status line (2026-11-11): what Canvas takes, or in
/// its place the refusal or the outcome, never two lines at once. Pure, so
/// the rule is tested without a view.
enum DraftReviewStatus: Equatable {
    enum Tone: Equatable { case plain, muted, problem }

    /// Nothing to say (submitted: the full-sheet state says it).
    case none
    /// Canvas is being asked what it takes: a small spinner, no words.
    case checking
    case line(String, Tone)

    /// - Parameters:
    ///   - outcome: the line for what the last tap did (a submit's result, a
    ///     failed decline or preview, an attempt already on record), if any.
    ///     It wins: the "canvas takes" line steps aside for it.
    ///   - isFinished: a submit went out (or the result is final).
    ///   - lookup: Canvas's early answer; nil while it is out.
    ///   - block: the plan's block, if the phone cannot send this draft.
    ///   - noRouteLeft: the pdf failed to render and no other route is left.
    static func resolve(outcome: String?, outcomeTone: Tone = .problem, isFinished: Bool,
                        lookup: AgentAcceptanceLookup?,
                        block: DraftSubmitPlan.Block?, noRouteLeft: Bool) -> DraftReviewStatus {
        if let outcome { return .line(outcome, outcomeTone) }
        if isFinished { return .none }
        switch lookup {
        case nil:
            return .checking
        case .refused(let refusal)?:
            return .line(AgentDraftReviewSheet.refusalText(refusal), .muted)
        case .known(let acceptance)?:
            if let block, let text = AgentDraftReviewSheet.blockText(block) { return .line(text, .problem) }
            if noRouteLeft { return .line(AgentConnectionCopy.pdfFailed, .problem) }
            return .line(AgentConnectionCopy.canvasTakes(acceptance), .plain)
        }
    }
}
