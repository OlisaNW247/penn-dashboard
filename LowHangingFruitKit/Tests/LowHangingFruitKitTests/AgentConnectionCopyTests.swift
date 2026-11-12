import Foundation
import Testing
@testable import LowHangingFruitUI
import LowHangingFruitKit

@Suite("Agent connection copy")
struct AgentConnectionCopyTests {
    private func uiSource(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LowHangingFruitUI/\(name)")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private var strings: [String] {
        let c = AgentConnectionCopy.self
        return [
            c.heading("Claude"),
            c.pick, c.notNow, c.connected, c.done, c.connectedBanner("Claude"),
            c.draftedBy("Claude"), c.reviewAndSubmit, c.checkCanvas, c.noteFrom("Claude"), c.note,
            c.submit, c.decline, c.sending, c.submitted, c.submittedUnverified, c.offTitle,
            c.failed, c.mayHaveGoneIn, c.signInFirst, c.offline, c.fileUnavailable,
            c.couldntReach, c.declineFailure, c.openInCanvas, c.previewFile, c.loading,
            c.submittedByYou("Claude"), c.send, c.sendAsText, c.sendAsPDF, c.pdfFailed,
            c.notOnline, c.locked, c.unknownKind,
            c.confirmSend("Problem Set 7", as: .text), c.confirmSend("Problem Set 7", as: .pdf),
            c.confirmSend("Problem Set 7", as: .url), c.confirmSend("Problem Set 7", as: .file, fileName: "PS7.pdf"),
            c.canvasTakes(.online(text: true, url: true, file: true, extensions: ["pdf", "docx"])),
            c.canvasTakes(.notOnline), c.canvasTakes(.locked),
            c.kindRefused(.text), c.kindRefused(.url), c.kindRefused(.file),
            c.fileTypeRefused("ZIP", allowed: ["PDF"]), c.fileTypeRefused("zip", allowed: []),
            c.mismatch, c.failure, c.switchLabel, c.privacyPolicy, c.none,
            c.neverUsed, c.lastUsed(c.ago(7200)), c.disconnect, c.disconnectTitle("Claude"),
            c.cancel, c.disconnectFailure, c.codeHeader, c.connect, c.codeNotFound,
        ]
    }

    @Test("every string is lowercase with no exclamation mark")
    func lowercaseNoBang() {
        for s in strings {
            #expect(s == s.lowercased(), "\(s)")
            #expect(!s.contains("!"), "\(s)")
        }
    }

    @Test("exact wording: the approve sheet (the question, the prompt, the buttons; 2026-11-11)")
    func approveSheet() throws {
        let c = AgentConnectionCopy.self
        #expect(c.heading("Claude") == "connect claude?")
        #expect(c.pick == "pick the matching number")
        #expect(c.notNow == "not now")
        #expect(c.connected == "connected")
        #expect(c.done == "done")
        #expect(c.mismatch == "didn't match")
        #expect(c.failure == "couldn't connect")
        #expect(c.connectedBanner("Claude") == "connected to claude")
        // No host line and no scope line under the question any more.
        let src = try uiSource("AgentLinkApproveSheet.swift")
        if !src.isEmpty {
            #expect(!src.contains("lookup.clientHost") && !src.contains("scopeLine"))
        }
    }

    @Test("exact wording: profile → agent (2026-11-11)")
    func profileRows() {
        let c = AgentConnectionCopy.self
        #expect(c.switchLabel == "connected agent")
        #expect(c.offTitle == "disconnect every agent?")
        #expect(c.privacyPolicy == "privacy policy")
        #expect(c.privacyURL == "https://github.com/OlisaNW247/penn-dashboard/blob/v10/docs/PRIVACY.md")
        #expect(c.none == "none yet")
        #expect(c.neverUsed == "never used")
        #expect(c.lastUsed("2h ago") == "last used 2h ago")
        #expect(c.disconnect == "disconnect")
        #expect(c.disconnectTitle("Claude") == "disconnect claude?")
        #expect(c.disconnectFailure == "couldn't disconnect")
        #expect(c.codeHeader == "have a code?")
        #expect(c.codePlaceholder == "XXXX-XXXX")
        #expect(c.connect == "connect")
        #expect(c.codeNotFound == "code not found")
    }

    @Test("last used reads short: just now, minutes, hours, days")
    func lastUsedShort() {
        let c = AgentConnectionCopy.self
        #expect(c.ago(-5) == "just now" && c.ago(59) == "just now")
        #expect(c.ago(60) == "1m ago" && c.ago(3599) == "59m ago")
        #expect(c.ago(7200) == "2h ago" && c.ago(86_399) == "23h ago")
        #expect(c.ago(86_400 * 3) == "3d ago")
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ProfileAgentRows.usedText(nil, now: now) == "never used")
        #expect(ProfileAgentRows.usedText(now.addingTimeInterval(-7200), now: now) == "last used 2h ago")
    }

    @Test("the review sheet's words, pinned (2026-11-11)")
    func reviewSheet() {
        let c = AgentConnectionCopy.self
        #expect(c.draftedBy("Claude") == "drafted by claude")
        #expect(c.reviewAndSubmit == "review and submit")
        #expect(c.note == "note")
        #expect(c.submit == "submit to canvas")
        #expect(c.decline == "decline")
        #expect(c.sendAsText == "send as text" && c.sendAsPDF == "send as pdf")
        #expect(c.confirmSend("Problem Set 7", as: .pdf) == "send problem set 7 as a pdf?")
        #expect(c.confirmSend("Problem Set 7", as: .text) == "send problem set 7 as text?")
        #expect(c.confirmSend("Essay", as: .url) == "send essay as a link?")
        #expect(c.confirmSend("Essay", as: .file, fileName: "Essay.DOCX") == "send essay.docx for essay?")
        #expect(c.canvasTakes(.online(text: false, url: false, file: true, extensions: ["pdf", "docx"])) == "canvas takes a pdf or docx")
        #expect(c.canvasTakes(.online(text: true, url: false, file: false, extensions: [])) == "canvas takes text")
        #expect(c.canvasTakes(.online(text: false, url: false, file: true, extensions: [])) == "canvas takes a file")
        #expect(c.canvasTakes(.online(text: true, url: true, file: true, extensions: [])) == "canvas takes text, a link or a file")
        #expect(c.canvasTakes(.notOnline) == "can't be submitted online")
        #expect(c.canvasTakes(.locked) == "locked in canvas")
        #expect(c.fileTypeRefused("zip", allowed: ["pdf"]) == "canvas won't take .zip \u{00B7} pdf only")
        #expect(c.fileTypeRefused("zip", allowed: ["pdf", "docx"]) == "canvas won't take .zip \u{00B7} pdf or docx only")
        #expect(c.fileTypeRefused("zip", allowed: []) == "canvas won't take .zip")
        #expect(c.kindRefused(.url) == "canvas won't take a link")
        #expect(c.kindRefused(.text) == "canvas won't take text")
        #expect(c.unknownKind == "can't send this draft")
        #expect(c.offline == "no connection")
        #expect(c.couldntReach == "couldn't reach canvas")
        #expect(c.fileUnavailable == "couldn't load the file")
        #expect(c.declineFailure == "couldn't decline")
        #expect(c.failed == "canvas refused it")
        #expect(c.signInFirst == "sign in to canvas first")
        #expect(c.mayHaveGoneIn == "may have gone in \u{00B7} check canvas")
        #expect(c.submitted == "submitted to canvas")
        #expect(c.submittedUnverified == "submitted \u{00B7} not confirmed")
        #expect(c.submittedByYou("Claude") == "submitted by you \u{00B7} drafted by claude")
    }

    @Test("the agent's note is always behind \"note\", never a line on the sheet")
    func noteRule() throws {
        let src = try uiSource("AgentDraftReviewSheet.swift")
        guard !src.isEmpty else { return }
        #expect(!src.contains("noteFitsOnALine"))
        let header = try #require(src.range(of: "if let note = draft?.note"))
        let tail = String(src[header.upperBound...].prefix(900))
        #expect(tail.contains("DisclosureGroup {"))
    }

    @Test("every refusal maps to its one short line")
    func refusals() {
        let c = AgentConnectionCopy.self
        typealias R = CanvasSubmissionClient.Refusal
        let sheet = AgentDraftReviewSheet.self
        #expect(sheet.refusalText(R.offline) == c.offline)
        #expect(sheet.refusalText(R.sessionDead) == c.signInFirst)
        #expect(sheet.refusalText(R.noCSRF) == c.signInFirst)
        #expect(sheet.refusalText(R.locked) == c.locked)
        #expect(sheet.refusalText(R.unsupportedType) == c.notOnline)
        #expect(sheet.refusalText(R.missingIDs) == c.notOnline)
        #expect(sheet.refusalText(R.preflightFailed) == c.couldntReach)
        #expect(sheet.refusalText(R.attemptNotRecorded) == c.couldntReach)
        #expect(sheet.blockText(.notOnline) == nil && sheet.blockText(.locked) == nil)
        #expect(sheet.blockText(.fileType(ext: "zip", allowed: ["pdf"])) == c.fileTypeRefused("zip", allowed: ["pdf"]))
        #expect(sheet.blockText(.kind(.url)) == c.kindRefused(.url))
    }
}
