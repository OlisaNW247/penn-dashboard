import Foundation
import Testing
import WebKit
@testable import LowHangingFruitUI

@Suite("Submitted PennKey credential lifetime")
@MainActor
struct PennKeyLoginCaptureTests {
    private let login = URL(string: "https://weblogin.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO")!
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func acceptedSubmissionIsConsumedOnce() {
        let capture = PennKeyLoginCapture()
        capture.receive(username: " student ", password: " test password ", from: login, isMainFrame: true, now: now)
        let result = capture.take(now: now)
        #expect(result?.username == "student")
        #expect(result?.password == " test password ")
        #expect(capture.take(now: now) == nil)
    }

    @Test(arguments: [
        "http://weblogin.pennkey.upenn.edu/idp/login",
        "https://weblogin.pennkey.upenn.edu.evil.example/idp/login",
        "https://evil.weblogin.pennkey.upenn.edu/idp/login",
        "https://weblogin.pennkey.upenn.edu:8443/idp/login",
        "https://weblogin.pennkey.upenn.edu/unrelated",
        "https://canvas.upenn.edu/idp/login",
        "https://api.duosecurity.com/idp/login"
    ])
    func refusesOtherOrigins(address: String) {
        let capture = PennKeyLoginCapture()
        capture.receive(username: "student", password: "test", from: URL(string: address), isMainFrame: true, now: now)
        #expect(capture.take(now: now) == nil)
    }

    @Test func refusesSubframes() {
        let capture = PennKeyLoginCapture()
        capture.receive(username: "student", password: "test", from: login, isMainFrame: false, now: now)
        #expect(capture.take(now: now) == nil)
    }

    @Test func expiresWhileWaitingForDuo() {
        let capture = PennKeyLoginCapture()
        capture.receive(username: "student", password: "test", from: login, isMainFrame: true, now: now)
        #expect(capture.take(now: now.addingTimeInterval(600)) == nil)
    }

    @Test func cancellationDropsCredentialsAndIgnoresLateMessages() {
        let capture = PennKeyLoginCapture()
        capture.receive(username: "student", password: "test", from: login, isMainFrame: true, now: now)
        capture.finish()
        capture.receive(username: "student", password: "late", from: login, isMainFrame: true, now: now)
        #expect(capture.take(now: now) == nil)
    }

    @Test func correctedPasswordReplacesFailedAttempt() {
        let capture = PennKeyLoginCapture()
        capture.receive(username: "student", password: "wrong", from: login, isMainFrame: true, now: now)
        capture.receive(username: "student", password: "corrected", from: login, isMainFrame: true, now: now)
        #expect(capture.take(now: now)?.password == "corrected")
    }

    @Test func emptySubmissionInvalidatesPreviousAttempt() {
        let capture = PennKeyLoginCapture()
        capture.receive(username: "student", password: "old", from: login, isMainFrame: true, now: now)
        capture.receive(username: "student", password: "", from: login, isMainFrame: true, now: now)
        #expect(capture.take(now: now) == nil)
    }

    @Test func explicitFailureDiscardsSubmission() {
        let capture = PennKeyLoginCapture()
        capture.receive(username: "student", password: "test", from: login, isMainFrame: true, now: now)
        capture.clear()
        #expect(capture.take(now: now) == nil)
    }
    @Test func webKitSubmissionCapturesValuesWithoutResubmitting() async throws {
        let capture = PennKeyLoginCapture()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        capture.install(in: config.userContentController)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.loadHTMLString("""
            <form action="/idp/login" method="post">
              <input name="j_username" value="fixture-student">
              <input name="j_password" type="password" value="fixture-password">
              <button type="submit">Sign in</button>
            </form>
            """, baseURL: login)
        for _ in 0..<100 {
            if let ready = try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('form')"),
               ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Synthetic DOM submission exercises the real isolated-world bridge.
        // Dispatching alone must not navigate or re-submit the form.
        _ = try await webView.evaluateJavaScript("document.querySelector('form').dispatchEvent(new Event('submit', {bubbles:true, cancelable:true}))")
        try await Task.sleep(for: .milliseconds(200))
        let result = capture.take()
        #expect(result?.username == "fixture-student")
        #expect(result?.password == "fixture-password")
        #expect(webView.url?.host == login.host)
        capture.finish()
    }

}
