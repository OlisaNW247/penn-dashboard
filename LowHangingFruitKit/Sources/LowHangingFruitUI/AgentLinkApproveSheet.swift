import SwiftUI
import LowHangingFruitKit

/// Every word the agent connection screens print, in one place so a test can
/// pin them (copy rule: lowercase, short, no raw errors).
enum AgentConnectionCopy {
    // Approve sheet (trimmed 2026-11-11: no "did you just start this?", no
    // "go back to claude"; the numbers' prompt says it)
    static func heading(_ name: String) -> String { "connect \(name.lowercased())?" }
    static let reads = "reads your classes and work"
    static let drafts = ", proposes drafts"
    /// The one line under the heading: what the agent asked to do.
    static func scopeLine(drafts withDrafts: Bool) -> String { reads + (withDrafts ? drafts : "") }
    static let pick = "pick the number the page shows"
    static let notNow = "not now"
    static let connected = "connected"
    static let done = "done"
    static let mismatch = "didn't match"
    static let failure = "couldn't connect"

    // Profile -> agent (2026-11-11: the rows are their own section after
    // accounts;
    // the full disclosure is docs/PRIVACY.md -> "Connecting an AI assistant")
    static let switchLabel = "connected agent"
    /// Names the recipient (App Review, 5.1.2(i)); the policy says the rest.
    static let shares = "shares your classes and work list with the agent's provider"
    static let privacyPolicy = "privacy policy"
    static let privacyURL = "https://github.com/OlisaNW247/penn-dashboard/blob/v10/docs/PRIVACY.md"
    static let none = "none yet"
    static let neverUsed = "never used"
    static func lastUsed(_ relative: String) -> String { "last used \(relative)" }
    /// "just now", "5m ago", "2h ago", "3d ago": short enough for a row.
    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86_400 { return "\(s / 3600)h ago" }
        return "\(s / 86_400)d ago"
    }
    static let disconnect = "disconnect"
    /// Turning "connected agent" off asks once; the title is the whole of it.
    static let offTitle = "disconnect every agent?"
    static func disconnectTitle(_ name: String) -> String { "disconnect \(name.lowercased())?" }
    static let cancel = "cancel"
    static let disconnectFailure = "couldn't disconnect"
    static let codeHeader = "have a code?"
    static let codePlaceholder = "XXXX-XXXX"
    static let connect = "connect"
    static let codeNotFound = "code not found"

    // Dashboard line, once a new connection shows up while the app is open
    static func connectedBanner(_ name: String) -> String { "connected to \(name.lowercased())" }

    // Drafts: the card
    static func draftedBy(_ name: String) -> String { "drafted by \(name.lowercased())" }
    /// prev, once the student sent an agent's draft from the phone.
    static func submittedByYou(_ name: String) -> String { "submitted by you \u{00B7} \(draftedBy(name))" }
    static let reviewAndSubmit = "review and submit"
    static let checkCanvas = "check canvas"

    // Drafts: the review sheet (2026-11-11 redesign: what canvas takes, then
    // the one choice there is, then submit or decline)
    static func noteFrom(_ name: String) -> String { "\(name.lowercased())'s note" }
    /// The agent's note behind this, when it is too long for one line.
    static let note = "note"
    /// The note shows as a line only under this many characters.
    static let noteLineLimit = 80
    /// The confirmation's message, not a line on the sheet.
    static let integrity = "goes in under your name"
    static let submit = "submit to canvas"
    static let send = "send"
    static let sendAsText = "send as text"
    static let sendAsPDF = "send as pdf"
    static let pdfFailed = "couldn't make a pdf"
    static let decline = "decline"
    static let sending = "sending to canvas"

    /// "send problem set 7 as a pdf?": the confirmation names the kind.
    static func confirmSend(_ title: String, as route: DraftSubmitRoute, fileName: String? = nil) -> String {
        let t = title.lowercased()
        switch route {
        case .text: return "send \(t) as text?"
        case .pdf: return "send \(t) as a pdf?"
        case .url: return "send \(t) as a link?"
        case .file: return "send \(fileName.map { $0.lowercased() } ?? "the file") for \(t)?"
        }
    }

    /// The one line that says what Canvas takes for this assignment.
    static func canvasTakes(_ acceptance: CanvasAcceptance) -> String {
        switch acceptance {
        case .notOnline: return notOnline
        case .locked: return locked
        case let .online(text, url, file, extensions):
            var things: [String] = []
            if text { things.append("text") }
            if url { things.append("a link") }
            if file { things.append(extensions.isEmpty ? "a file" : "a " + orList(extensions)) }
            return "canvas takes \(orList(things)) here"
        }
    }

    /// "pdf", "pdf or docx", "pdf, docx or txt".
    static func orList(_ words: [String]) -> String {
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " or " + (words.last ?? "")
    }

    static let notOnline = "this one can't be submitted online"
    static let locked = "canvas has this one locked"
    static func kindRefused(_ kind: AgentDraft.Kind) -> String {
        switch kind {
        case .text: return "canvas doesn't take text here"
        case .url: return "canvas doesn't take a link here"
        case .file, .unknown: return "canvas doesn't take a file here"
        }
    }
    static func fileTypeRefused(_ ext: String, allowed: [String]) -> String {
        let shown = ext.isEmpty ? "this file" : ".\(ext.lowercased())"
        guard !allowed.isEmpty else { return "canvas doesn't take \(shown) here" }
        return "canvas doesn't take \(shown) here \u{00B7} ask for a \(orList(allowed.map { $0.lowercased() })) file"
    }
    static let unknownKind = "this build can't send this draft"

    // Results
    static let submitted = "submitted to canvas"
    /// Canvas answered the submit with an id, but the read-back did not.
    static let submittedUnverified = "submitted \u{00B7} check canvas to be sure"
    static let failed = "canvas didn't take it \u{00B7} ask for a new draft"
    static let mayHaveGoneIn = "it may have gone in \u{00B7} check canvas"
    static let signInFirst = "sign in to canvas in profile, then try again"
    static let offline = "no connection \u{00B7} try again"
    static let couldntReach = "couldn't reach canvas \u{00B7} try again"
    static let fileUnavailable = "couldn't load the file \u{00B7} try again"
    static let declineFailure = "couldn't decline \u{00B7} try again"
    static let openInCanvas = "open in canvas"
    static let previewFile = "preview"
    static let loading = "loading"
}

/// "connect <agent>?": shown for `smooth://link?c=...` or a typed code. The
/// student confirms by picking the number the agent's page shows; a wrong
/// number denies the request on the server, so the sheet then stays dead and
/// the student starts again from the agent.
struct AgentLinkApproveSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let lookup: AgentPendingLookup
    @State private var isWorking = false
    @State private var result: Result?

    private enum Result { case connected, mismatch, failed }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SmoothFormHeader(title: AgentConnectionCopy.heading(lookup.clientName),
                                     accent: .smoothTeal, spark: .smoothGrape)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)

                Section {
                    if !lookup.clientHost.isEmpty {
                        Text(lookup.clientHost)
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    Text(AgentConnectionCopy.scopeLine(drafts: lookup.scopes.contains("draft")))
                    Text(AgentConnectionCopy.pick)
                        .foregroundStyle(Color.smoothMuted)
                    HStack(spacing: 12) {
                        ForEach(lookup.choices, id: \.self) { number in
                            Button { pick(number) } label: {
                                Text("\(number)")
                                    .font(.lhfSecondary(24, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 56)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.smoothTeal)
                            .disabled(isWorking || result != nil)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    Button(AgentConnectionCopy.notNow) { notNow() }
                        .disabled(isWorking || result == .connected)

                    switch result {
                    case .connected:
                        EmptyView()
                    case .mismatch:
                        Text(AgentConnectionCopy.mismatch)
                            .font(.lhfSecondary(12)).foregroundStyle(Color.smoothTomatoInk)
                    case .failed:
                        Text(AgentConnectionCopy.failure)
                            .font(.lhfSecondary(12)).foregroundStyle(Color.smoothTomatoInk)
                    case nil:
                        EmptyView()
                    }
                }
                .smoothSectionBackground(.smoothTeal)
            }
            .formStyle(.grouped)
            // Marco, 2026-11-09: "there should be some UI that makes it clear
            // when you're connected since it is not that clear." The sheet
            // used to print one small line and close itself a second later;
            // now the whole sheet becomes the confirmation and stays until
            // the student taps done.
            .overlay {
                if result == .connected { connectedState }
            }
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothTeal)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .lhfSheetTheme()
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isWorking)
#if os(macOS)
        .frame(minWidth: 320, minHeight: 360)
#endif
    }

    private var connectedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Color.smoothTeal)
                .accessibilityHidden(true)
            Text(AgentConnectionCopy.connected)
                .font(.lhfSecondary(22, weight: .semibold))
            Button(AgentConnectionCopy.done) { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Color.smoothTeal)
                .padding(.top, 6)
        }
        .foregroundStyle(Color.smoothInk)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.smoothPaper)
        .accessibilityElement(children: .combine)
    }

    private func pick(_ number: Int) {
        guard !isWorking, result == nil else { return }
        isWorking = true
        Task {
            let ok = await state.approveAgentLink(id: lookup.id, picked: number)
            isWorking = false
            if ok {
                result = .connected
                lhfHapticLight()
            } else {
                // A wrong number is denied by the server; a failed call is
                // indistinguishable here, and either way the student restarts
                // from the agent.
                result = .mismatch
            }
        }
    }

    private func notNow() {
        Task {
            await state.denyAgentLink(id: lookup.id)
            dismiss()
        }
    }
}
