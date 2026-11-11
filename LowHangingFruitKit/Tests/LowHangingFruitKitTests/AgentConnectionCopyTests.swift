import Foundation
import Testing
@testable import LowHangingFruitUI
import LowHangingFruitKit

@Suite("Agent connection copy")
struct AgentConnectionCopyTests {
    private var strings: [String] {
        let c = AgentConnectionCopy.self
        return [
            c.heading("Claude"), c.reads, c.drafts, c.scopeLine(drafts: true), c.scopeLine(drafts: false),
            c.pick, c.notNow, c.connected, c.done, c.connectedBanner("Claude"),
            c.draftedBy("Claude"), c.reviewAndSubmit, c.checkCanvas, c.noteFrom("Claude"), c.note, c.integrity,
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
            c.mismatch, c.failure, c.switchLabel, c.shares, c.privacyPolicy, c.none,
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

    @Test("exact wording: the approve sheet (trimmed 2026-11-11)")
    func approveSheet() {
        let c = AgentConnectionCopy.self
        #expect(c.heading("Claude") == "connect claude?")
        #expect(c.reads == "reads your classes and work")
        #expect(c.scopeLine(drafts: true) == "reads your classes and work, proposes drafts")
        #expect(c.scopeLine(drafts: false) == "reads your classes and work")
        #expect(c.pick == "pick the number the page shows")
        #expect(c.notNow == "not now")
        #expect(c.connected == "connected")
        #expect(c.done == "done")
        #expect(c.mismatch == "didn't match")
        #expect(c.failure == "couldn't connect")
        #expect(c.connectedBanner("Claude") == "connected to claude")
    }

    @Test("exact wording: profile → accounts (2026-11-11)")
    func profileRows() {
        let c = AgentConnectionCopy.self
        #expect(c.switchLabel == "connected agent")
        #expect(c.shares == "shares your classes and work list with the agent's provider")
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
        #expect(String(ProfileAgentRows.sharesLine.characters) == "shares your classes and work list with the agent's provider \u{00B7} privacy policy")
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
        #expect(c.integrity == "goes in under your name")
        #expect(c.note == "note")
        #expect(c.noteLineLimit == 80)
        #expect(c.submit == "submit to canvas")
        #expect(c.decline == "decline")
        #expect(c.sendAsText == "send as text" && c.sendAsPDF == "send as pdf")
        #expect(c.confirmSend("Problem Set 7", as: .pdf) == "send problem set 7 as a pdf?")
        #expect(c.confirmSend("Problem Set 7", as: .text) == "send problem set 7 as text?")
        #expect(c.confirmSend("Essay", as: .url) == "send essay as a link?")
        #expect(c.confirmSend("Essay", as: .file, fileName: "Essay.DOCX") == "send essay.docx for essay?")
        #expect(c.canvasTakes(.online(text: false, url: false, file: true, extensions: ["pdf", "docx"])) == "canvas takes a pdf or docx here")
        #expect(c.canvasTakes(.online(text: true, url: false, file: false, extensions: [])) == "canvas takes text here")
        #expect(c.canvasTakes(.online(text: false, url: false, file: true, extensions: [])) == "canvas takes a file here")
        #expect(c.canvasTakes(.online(text: true, url: true, file: true, extensions: [])) == "canvas takes text, a link or a file here")
        #expect(c.canvasTakes(.notOnline) == "this one can't be submitted online")
        #expect(c.canvasTakes(.locked) == "canvas has this one locked")
        #expect(c.locked + " \u{00B7} " + c.openInCanvas == "canvas has this one locked \u{00B7} open in canvas")
        #expect(c.fileTypeRefused("zip", allowed: ["pdf"]) == "canvas doesn't take .zip here \u{00B7} ask for a pdf file")
        #expect(c.fileTypeRefused("zip", allowed: ["pdf", "docx"]) == "canvas doesn't take .zip here \u{00B7} ask for a pdf or docx file")
        #expect(c.kindRefused(.url) == "canvas doesn't take a link here")
        #expect(c.offline == "no connection \u{00B7} try again")
        #expect(c.signInFirst == "sign in to canvas in profile, then try again")
        #expect(c.mayHaveGoneIn == "it may have gone in \u{00B7} check canvas")
        #expect(c.submitted == "submitted to canvas")
        #expect(c.submittedUnverified == "submitted \u{00B7} check canvas to be sure")
        #expect(c.submittedByYou("Claude") == "submitted by you \u{00B7} drafted by claude")
    }

    @Test("a short note is a line, a long one goes behind \"note\"")
    func noteRule() {
        let sheet = AgentDraftReviewSheet.self
        #expect(sheet.noteFitsOnALine("used your lecture 9 notes"))
        #expect(sheet.noteFitsOnALine(String(repeating: "a", count: 79)))
        #expect(!sheet.noteFitsOnALine(String(repeating: "a", count: 80)))
        #expect(!sheet.noteFitsOnALine("two\nlines"))
    }

    @Test("every refusal says what happened and the next step")
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
