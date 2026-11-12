#if DEBUG
import Foundation
import LowHangingFruitKit

/// The agent connection's screenshot seam (2026-11-11), DEBUG only and
/// compiled out of Release. Marco asked for "photos of the new UI of all the
/// different screens for the agent connection", and the demo data
/// (`-LHFDemoData`) has no agent state: no connection, no draft, no Canvas to
/// ask what an assignment takes. This fills exactly that, in memory.
///
/// It touches no server and no persistence: while `debugAgentDemo` is set,
/// `agentAPI` is nil (so no seen, decline or refetch call can leave the
/// phone), the opt-in switch flips memory only, and every answer that would
/// come from the backend or Canvas comes from here. Nothing is written to
/// `UserDefaults.lhf`, the draft cache or the attempt store.
///
/// Launch arguments, with `-LHFDemoData`:
/// - `-LHFDemoAgentState`: one connected agent, "claude", last used 2h ago;
///   a text draft on "PSet 6: hashing", a file draft on "Lab report 4"; prev's
///   "Recitation worksheet" reads "submitted by you · drafted by claude".
/// - `-LHFDemoAgentOff`: the same, with the "connected agent" switch off.
/// - `-LHFDraftReviewHarness <state>`: the review sheet opened directly on
///   one draft in one state (`AgentDemoState.Harness`).
/// - `-LHFShowCodeSheet`, `-LHFShowApproveSheet`: those two sheets.
struct AgentDemoState {
    enum Harness: String, CaseIterable {
        case text, textFileOnly, file, link, locked, offline, signIn, submitted, unconfirmed, failed
    }

    var harness: Harness?
    var connections: [AgentConnectionSummary]
    var lookup: AgentPendingLookup
    /// For the result states: the outcome the sheet opens on, and what a tap
    /// on submit returns.
    var initialOutcome: AgentSubmitResult?

    /// What Canvas "takes" for a draft: chosen by the harness state, else by
    /// the draft's kind.
    func lookup(for draft: AgentDraft) -> AgentAcceptanceLookup {
        switch harness {
        case .text?: return .known(.online(text: true, url: false, file: false, extensions: []))
        case .textFileOnly?: return .known(.online(text: false, url: false, file: true, extensions: ["pdf"]))
        case .locked?: return .known(.locked)
        case .link?: return .known(.online(text: false, url: true, file: false, extensions: []))
        case .file?: return .known(.online(text: false, url: false, file: true, extensions: ["pdf", "docx"]))
        default:
            switch draft.kind {
            case .file: return .known(.online(text: false, url: false, file: true, extensions: ["pdf", "docx"]))
            case .url: return .known(.online(text: false, url: true, file: false, extensions: []))
            default: return .known(.online(text: true, url: false, file: true, extensions: []))
            }
        }
    }

    static let textBody = """
    1. Inserting 12, 44, 13, 88, 23, 94, 11 into a table of size 11 with h(k) = k mod 11: 12 goes to slot 1, 44 to 0, 13 to 2, 88 to 0 (collides, probes to 3), 23 to 1 (probes to 4), 94 to 6, 11 to 0 (probes to 5).

    2. The expected number of probes for an unsuccessful search with load factor 7/11 is 1 / (1 - 7/11) = 2.75.

    3. Doubling the table at a load factor of 3/4 keeps every insert amortised O(1): each element is moved at most a constant number of times across all resizes.
    """
}

extension AppState {
    /// The dashboard sample's item ids for the drafts. Read off
    /// `SampleData.items()` by title so the ids are the ones the cards carry.
    static func demoItemID(titled title: String) -> String {
        SampleData.items().first { $0.assignment.title == title }?.id ?? title
    }

    /// Installs the demo and returns what the dashboard model needs to draw
    /// it: the card chips by item id and prev's "submitted by you" names.
    func installAgentDemo(arguments args: [String]) -> (drafts: [String: AgentDraftDisplay], submittedBy: [String: String]) {
        let harnessArg = args.firstIndex(of: "-LHFDraftReviewHarness").flatMap { i in
            i + 1 < args.count ? AgentDemoState.Harness(rawValue: args[i + 1]) : nil
        }
        let now = Date()
        let connection = AgentConnectionSummary(
            id: "demo-c1", clientName: "Claude", clientHost: "claude.ai", scopes: ["read", "draft"],
            createdAt: now.addingTimeInterval(-86_400), lastUsedAt: now.addingTimeInterval(-7200))
        let lookup = AgentPendingLookup(
            id: "demo-p1", clientName: "Claude", clientHost: "claude.ai", scopes: ["read", "draft"],
            choices: [48, 12, 7], expiresAt: now.addingTimeInterval(300))
        var outcome: AgentSubmitResult?
        switch harnessArg {
        case .offline?: outcome = .refused(.offline)
        case .signIn?: outcome = .refused(.sessionDead)
        case .submitted?: outcome = .submitted(verified: true)
        case .unconfirmed?: outcome = .submitted(verified: false)
        case .failed?: outcome = .failed
        default: outcome = nil
        }
        debugAgentDemo = AgentDemoState(harness: harnessArg, connections: [connection],
                                        lookup: lookup, initialOutcome: outcome)
        agentConnectionEnabled = !args.contains("-LHFDemoAgentOff")
        hasAgentConnections = true

        let textItem = Self.demoItemID(titled: "PSet 6: hashing")
        let fileItem = Self.demoItemID(titled: "Lab report 4")
        let linkItem = Self.demoItemID(titled: "Group case writeup")
        let note = "used your lecture 9 notes on open addressing"
        var drafts = [
            AgentDraft(id: "demo-text", assignmentID: textItem, kind: .text, body: AgentDemoState.textBody,
                       note: note, clientName: "Claude"),
            AgentDraft(id: "demo-file", assignmentID: fileItem, kind: .file, fileName: "Lab report 4.pdf",
                       mimeType: "application/pdf", fileBytes: 248_000, clientName: "Claude"),
            AgentDraft(id: "demo-link", assignmentID: linkItem, kind: .url,
                       url: "https://docs.google.com/document/d/case-writeup", clientName: "Claude"),
        ]
        // The harness's draft goes first, so `agentDrafts.first` is the one.
        switch harnessArg {
        case .file?: drafts.swapAt(0, 1)
        case .link?: drafts.swapAt(0, 2)
        default: break
        }
        agentDrafts = drafts

        var chips: [String: AgentDraftDisplay] = [:]
        for draft in drafts where draft.kind != .url {
            chips[draft.assignmentID] = AgentDraftDisplay(
                draftID: draft.id, agentName: "claude",
                preview: draft.preview(maxLines: 2, maxCharacters: 160),
                checkCanvas: false, isUnseen: false)
        }
        return (chips, [Self.demoItemID(titled: "Recitation worksheet"): "claude"])
    }
}
#endif
