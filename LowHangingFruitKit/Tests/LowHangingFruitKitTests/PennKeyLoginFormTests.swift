import Foundation
import Testing
@testable import LowHangingFruitKit

/// Pure coverage for `PennKeyLoginForm` — host/path recognition and the
/// generated fill-and-submit script, all network-free (same shape as
/// `CanvasAccessTokenTests`' script-generation tests next to this one).
@Suite("PennKey login form")
struct PennKeyLoginFormTests {

    // MARK: - isLoginForm

    @Test("weblogin.pennkey.upenn.edu under /idp/ is the login form")
    func isLoginFormWeblogin() {
        let url = URL(string: "https://weblogin.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO?execution=e1s1")
        #expect(PennKeyLoginForm.isLoginForm(url))
    }

    @Test("idp.pennkey.upenn.edu under /idp/ is also the login form")
    func isLoginFormIdpHost() {
        let url = URL(string: "https://idp.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO?execution=e2s1&eventTag=password")
        #expect(PennKeyLoginForm.isLoginForm(url))
    }

    @Test("canvas.upenn.edu/login/saml is not the login form")
    func isLoginFormCanvasIsNot() {
        let url = URL(string: "https://canvas.upenn.edu/login/saml")
        #expect(!PennKeyLoginForm.isLoginForm(url))
    }

    @Test("a pennkey host outside /idp/ is not the login form")
    func isLoginFormWrongPath() {
        let url = URL(string: "https://weblogin.pennkey.upenn.edu/some/other/page")
        #expect(!PennKeyLoginForm.isLoginForm(url))
    }

    @Test("host match is case-insensitive")
    func isLoginFormCaseInsensitive() {
        let url = URL(string: "https://WEBLOGIN.PENNKEY.UPENN.EDU/idp/profile/SAML2/Redirect/SSO?execution=e1s1")
        #expect(PennKeyLoginForm.isLoginForm(url))
    }

    @Test("nil URL is never the login form")
    func isLoginFormNil() {
        #expect(!PennKeyLoginForm.isLoginForm(nil))
    }

    // MARK: - isDuo

    @Test("a duosecurity frame host is Duo")
    func isDuoTrue() {
        let url = URL(string: "https://api-xxxx.duosecurity.com/frame/web/v1/auth")
        #expect(PennKeyLoginForm.isDuo(url))
    }

    @Test("canvas.upenn.edu is not Duo")
    func isDuoFalseForCanvas() {
        let url = URL(string: "https://canvas.upenn.edu/")
        #expect(!PennKeyLoginForm.isDuo(url))
    }

    // MARK: - isCanvas

    @Test("canvas.upenn.edu is Canvas")
    func isCanvasTrue() {
        let url = URL(string: "https://canvas.upenn.edu/login/saml")
        #expect(PennKeyLoginForm.isCanvas(url))
    }

    @Test("the IdP host is not Canvas")
    func isCanvasFalseForIdP() {
        let url = URL(string: "https://weblogin.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO")
        #expect(!PennKeyLoginForm.isCanvas(url))
    }

    // MARK: - fillAndSubmitScript

    @Test("the script contains every field name and the sentinel")
    func scriptContainsFieldNames() {
        let script = PennKeyLoginForm.fillAndSubmitScript(username: "student", password: "hunter2")
        #expect(script.contains("j_username"))
        #expect(script.contains("j_password"))
        #expect(script.contains("_eventId_proceed"))
        #expect(script.contains("__lhfAutoLogin"))
    }

    @Test("a password with a quote, a backslash, a newline and </script> is JSON-escaped with no raw newline")
    func scriptEscapesDangerousPassword() throws {
        let dangerous = "p\"w\\d\n</script>"
        let script = PennKeyLoginForm.fillAndSubmitScript(username: "student", password: dangerous)

        // The script's own template lines contain real newlines (Swift
        // multi-line string literal) — the thing under test is that the
        // ESCAPED PASSWORD LITERAL itself carries no raw newline, not that
        // the whole script is single-line.
        let expectedLiteral = try #require(
            String(data: try JSONEncoder().encode(dangerous), encoding: .utf8)
        )
        #expect(!expectedLiteral.contains("\n"))
        #expect(script.contains(expectedLiteral))
    }

    // MARK: - outcome(from:)

    @Test("\"submitted\" maps to .submitted")
    func outcomeSubmitted() {
        #expect(PennKeyLoginForm.outcome(from: "submitted") == .submitted)
    }

    @Test("\"already\" maps to .already")
    func outcomeAlready() {
        #expect(PennKeyLoginForm.outcome(from: "already") == .already)
    }

    @Test("\"no-form\" maps to .noForm")
    func outcomeNoForm() {
        #expect(PennKeyLoginForm.outcome(from: "no-form") == .noForm)
    }

    @Test("nil maps to .unknown")
    func outcomeNil() {
        #expect(PennKeyLoginForm.outcome(from: nil) == .unknown)
    }

    @Test("garbage maps to .unknown")
    func outcomeGarbage() {
        #expect(PennKeyLoginForm.outcome(from: "something else") == .unknown)
    }
}
