import Foundation
import Testing
@testable import LowHangingFruitUI
import LowHangingFruitKit

@Suite("Agent connection copy")
struct AgentConnectionCopyTests {
    private var strings: [String] {
        let c = AgentConnectionCopy.self
        return [
            c.heading("claude"), c.reads, c.drafts, c.question, c.pick, c.notNow,
            c.connectedHeading("Claude"), c.connectedNext("Claude"), c.done, c.connectedBanner("Claude"),
            c.draftedBy("Claude"), c.reviewAndSubmit, c.checkCanvas, c.noteFrom("Claude"), c.integrity,
            c.submit, c.decline, c.sending, c.submitted, c.submittedUnverified,
            c.failed, c.mayHaveGoneIn, c.signInFirst, c.offline, c.fileUnavailable,
            c.couldntReach, c.declineFailure, c.openInCanvas, c.previewFile, c.loading,
            c.submittedByYou("Claude"), c.send, c.sendAsText, c.sendAsPDF, c.pdfFailed, c.checking,
            c.pages(1), c.pages(3), c.notOnline, c.locked, c.unknownKind, c.submittedAt("9:41 PM"),
            c.confirmSend("Problem Set 7", as: .text), c.confirmSend("Problem Set 7", as: .pdf),
            c.confirmSend("Problem Set 7", as: .url), c.confirmSend("Problem Set 7", as: .file, fileName: "PS7.pdf"),
            c.canvasTakes(.online(text: true, url: true, file: true, extensions: ["pdf", "docx"])),
            c.canvasTakes(.notOnline), c.canvasTakes(.locked),
            c.kindRefused(.text), c.kindRefused(.url), c.kindRefused(.file),
            c.fileTypeRefused("ZIP", allowed: ["PDF"]), c.fileTypeRefused("zip", allowed: []),
            c.mismatch, c.failure, c.rowLabel, c.on, c.off, c.switchLabel, c.disclosureIntro,
            c.never, c.recipients, c.offEffect, c.privacyPolicy, c.connectedHeader, c.none,
            c.neverUsed, c.lastUsed("2 days ago"), c.disconnect, c.disconnectTitle("claude"),
            c.cancel, c.disconnectFailure, c.codeHeader, c.connect, c.codeNotFound,
        ] + c.disclosureItems
    }

    @Test("every string is lowercase with no exclamation mark")
    func lowercaseNoBang() {
        for s in strings {
            #expect(s == s.lowercased(), "\(s)")
            #expect(!s.contains("!"), "\(s)")
        }
    }

    @Test("exact wording")
    func exact() {
        let c = AgentConnectionCopy.self
        #expect(c.heading("claude") == "connect claude?")
        #expect(c.reads == "reads your classes and work")
        #expect(c.question == "did you just start this?")
        #expect(c.pick == "pick the number the page shows")
        #expect(c.connectedHeading("Claude") == "connected to claude")
        #expect(c.connectedNext("Claude") == "go back to claude to finish")
        #expect(c.connectedBanner("Claude") == "connected to claude")
        #expect(c.draftedBy("Claude") == "drafted by claude")
        #expect(c.reviewAndSubmit == "review and submit")
        #expect(c.integrity == "this goes in under your name; read it")
        #expect(c.mismatch == "didn't match")
        #expect(c.failure == "couldn't connect")
        #expect(c.rowLabel == "connect an agent")
        #expect(c.none == "none yet")
        #expect(c.codeNotFound == "code not found")
        #expect(c.codePlaceholder == "XXXX-XXXX")
        #expect(c.disclosureItems.count == 4)
        #expect(c.privacyURL == "https://github.com/OlisaNW247/penn-dashboard/blob/v10/docs/PRIVACY.md")
    }

    @Test("the disclosure names what is never shared and who receives it")
    func disclosure() {
        let c = AgentConnectionCopy.self
        #expect(c.never.contains("grades") && c.never.contains("your name"))
        #expect(c.never.contains("passwords") && c.never.contains("sessions"))
        #expect(c.recipients.contains("anthropic") && c.recipients.contains("openai"))
        #expect(c.recipients.contains("smooth's server"))
        #expect(c.offEffect.contains("deletes the list"))
    }

    @Test("the review sheet's words, pinned (2026-11-11)")
    func reviewSheet() {
        let c = AgentConnectionCopy.self
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
        #expect(c.submittedAt("9:41 PM") == "in at 9:41 pm")
        #expect(c.submittedByYou("Claude") == "submitted by you \u{00B7} drafted by claude")
        #expect(c.pages(1) == "1 page" && c.pages(2) == "2 pages")
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
