import Foundation
import Testing
@testable import LowHangingFruitUI

@Suite("Agent connection copy")
struct AgentConnectionCopyTests {
    private var strings: [String] {
        let c = AgentConnectionCopy.self
        return [
            c.heading("claude"), c.reads, c.drafts, c.question, c.pick, c.notNow,
            c.connectedHeading("Claude"), c.connectedNext("Claude"), c.done, c.connectedBanner("Claude"),
            c.draftedBy("Claude"), c.reviewAndSubmit, c.checkCanvas, c.noteFrom("Claude"), c.integrity,
            c.submit, c.decline, c.confirmSubmitTitle, c.sending, c.submitted, c.submittedUnverified,
            c.failed, c.mayHaveGoneIn, c.unsupported, c.signInFirst, c.offline, c.fileUnavailable,
            c.couldntSend, c.declineFailure, c.openInCanvas, c.previewFile, c.loading,
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
        #expect(c.confirmSubmitTitle == "submit to canvas?")
        #expect(c.unsupported == "submit this one in canvas")
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
}
