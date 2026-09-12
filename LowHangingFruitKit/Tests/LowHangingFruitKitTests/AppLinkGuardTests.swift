import Foundation
import Testing
import WebKit
@testable import LowHangingFruitUI

/// Pins down `LoginNavigationObserver`'s app-link guard (added 2026-09-12,
/// see docs/CANVAS_LOGIN_DIAGNOSIS.md's dated section): with Canvas Student
/// installed, iOS was routing the SAML return hop on `canvas.upenn.edu` to
/// the installed app instead of letting the login `WKWebView` render it,
/// because that hop is a main-frame navigation that both traces back to a
/// user gesture (the Duo tap) and crosses hosts (the IdP back to Canvas) —
/// exactly what WebKit treats as a universal-link candidate. These tests
/// cover the pure, `WKWebView`-free pieces: the predicate that decides
/// whether a hop needs guarding, and the two static builders (`reissuedRequest`,
/// `formSerializerScript`) the guard uses to replay the hop programmatically.
/// The `evaluateJavaScript`-driven POST path itself needs a live `WKWebView`
/// and is not covered here — see the decision record in
/// `CanvasLoginHardeningTests` for what's left to manual/on-device
/// verification.
@Suite("App-link guard")
struct AppLinkGuardTests {

    // MARK: - needsAppLinkGuard

    @Test("true for the Canvas return hop: canvas destination, IdP current host, formSubmitted")
    func trueForFormSubmittedReturnHop() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "canvas.upenn.edu",
            currentHost: "idp.pennkey.upenn.edu",
            guardHost: "canvas.upenn.edu",
            navigationType: .formSubmitted,
            hasReissueMarker: false
        )
        #expect(result)
    }

    @Test("true for .other — a redirect hop, not a form submission")
    func trueForOtherNavigationType() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "canvas.upenn.edu",
            currentHost: "idp.pennkey.upenn.edu",
            guardHost: "canvas.upenn.edu",
            navigationType: .other,
            hasReissueMarker: false
        )
        #expect(result)
    }

    @Test("false when the current host equals the destination host — never a cross-host hop")
    func falseWhenHostsEqual() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "canvas.upenn.edu",
            currentHost: "canvas.upenn.edu",
            guardHost: "canvas.upenn.edu",
            navigationType: .other,
            hasReissueMarker: false
        )
        #expect(!result)
    }

    @Test("false when the current host is nil — the very first programmatic load")
    func falseWhenCurrentHostNil() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "canvas.upenn.edu",
            currentHost: nil,
            guardHost: "canvas.upenn.edu",
            navigationType: .other,
            hasReissueMarker: false
        )
        #expect(!result)
    }

    @Test("false when the pane never configured a guard host (Gradescope's pane)")
    func falseWhenGuardHostNil() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "canvas.upenn.edu",
            currentHost: "idp.pennkey.upenn.edu",
            guardHost: nil,
            navigationType: .other,
            hasReissueMarker: false
        )
        #expect(!result)
    }

    @Test("false for .backForward — browser-history navigation is never an app-link candidate")
    func falseForBackForward() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "canvas.upenn.edu",
            currentHost: "idp.pennkey.upenn.edu",
            guardHost: "canvas.upenn.edu",
            navigationType: .backForward,
            hasReissueMarker: false
        )
        #expect(!result)
    }

    @Test("false when the reissue marker is already present — our own re-issued load")
    func falseWhenMarkerPresent() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "canvas.upenn.edu",
            currentHost: "idp.pennkey.upenn.edu",
            guardHost: "canvas.upenn.edu",
            navigationType: .other,
            hasReissueMarker: true
        )
        #expect(!result)
    }

    @Test("host comparison against guardHost is case-insensitive")
    func hostComparisonIsCaseInsensitive() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "Canvas.Upenn.Edu",
            currentHost: "idp.pennkey.upenn.edu",
            guardHost: "canvas.upenn.edu",
            navigationType: .other,
            hasReissueMarker: false
        )
        #expect(result)
    }

    @Test("false for a different destination host (duosecurity.com) — not the guarded host")
    func falseForDifferentDestinationHost() {
        let result = LoginNavigationObserver.needsAppLinkGuard(
            destinationHost: "duosecurity.com",
            currentHost: "idp.pennkey.upenn.edu",
            guardHost: "canvas.upenn.edu",
            navigationType: .other,
            hasReissueMarker: false
        )
        #expect(!result)
    }

    // MARK: - reissuedRequest

    @Test("a reissued GET carries the marker header and no body")
    func reissuedGETHasMarkerAndNoBody() throws {
        let url = try #require(URL(string: "https://canvas.upenn.edu/login/saml"))
        let request = LoginNavigationObserver.reissuedRequest(url: url, method: "GET", body: nil)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: LoginNavigationObserver.reissueMarkerHeader) == "1")
        #expect(request.httpBody == nil)
    }

    @Test("a reissued POST carries the content type, the marker, and the body bytes")
    func reissuedPOSTHasContentTypeMarkerAndBody() throws {
        let url = try #require(URL(string: "https://canvas.upenn.edu/login/saml"))
        let body = "SAMLResponse=abc123&RelayState=xyz"
        let request = LoginNavigationObserver.reissuedRequest(url: url, method: "POST", body: body)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: LoginNavigationObserver.reissueMarkerHeader) == "1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
        #expect(request.httpBody == body.data(using: .utf8))
    }

    // MARK: - formSerializerScript

    @Test("formSerializerScript embeds the target with its fragment stripped")
    func formSerializerScriptStripsFragment() throws {
        let url = try #require(URL(string: "https://canvas.upenn.edu/calendar?month=9#assignment_1"))
        let script = LoginNavigationObserver.formSerializerScript(targetURL: url)
        #expect(script.contains("https://canvas.upenn.edu/calendar?month=9"))
        #expect(!script.contains("#assignment_1"))
    }

    @Test("the JSON string literal the script embeds escapes backslashes and double quotes")
    func jsonStringLiteralEscapes() {
        // Tested on the escaper directly rather than through a `URL`: whether
        // `URL(string:)` accepts a raw double quote, rejects it, or
        // percent-encodes it differs across Foundation versions, and none
        // of those outcomes is what this test is about. The script builder
        // routes every target through this function, so a correct escaper
        // means a quote can never close the embedded literal early.
        let literal = LoginNavigationObserver.jsonStringLiteral(for: "quote\"here\\slash")
        #expect(literal == "\"quote\\\"here\\\\slash\"")
        #expect(literal.hasPrefix("\"") && literal.hasSuffix("\""))
    }

    // MARK: - stripFragment

    @Test("stripFragment drops #assignment_1")
    func stripFragmentDropsFragment() throws {
        let url = try #require(URL(string: "https://canvas.upenn.edu/calendar?month=9#assignment_1"))
        #expect(LoginNavigationObserver.stripFragment(url) == "https://canvas.upenn.edu/calendar?month=9")
    }
}
