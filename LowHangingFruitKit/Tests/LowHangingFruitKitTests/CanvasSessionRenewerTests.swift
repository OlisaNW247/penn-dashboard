import Foundation
import Testing
@testable import LowHangingFruitUI

/// Session-longevity Layer 2 (`CanvasSessionRenewer.swift`): a silent,
/// background Canvas re-login attempt riding the still-live PennKey/Duo IdP
/// session in `LoginDataStores.canvas`. The actual WKWebView orchestration
/// can't be meaningfully driven under `swift test` (no window server, no
/// real network path to Penn's IdP) — this suite exercises everything that
/// was pulled out into pure, static functions specifically so the decision
/// logic is testable without a live WebView. The WebView plumbing itself
/// (the timeout race, the cookie harvest, the actual navigation) is
/// device-only verification — see the report for this task.
@MainActor
@Suite("Canvas session renewer")
struct CanvasSessionRenewerTests {
    // MARK: - gate(...)

    private func gate(
        now: Date = Date(),
        lastAttempt: Date? = nil,
        inFlight: Bool = false,
        paneActive: Bool = false,
        isTestRunner: Bool = false
    ) -> CanvasSessionRenewer.Outcome? {
        CanvasSessionRenewer.gate(
            now: now,
            lastAttempt: lastAttempt,
            inFlight: inFlight,
            paneActive: paneActive,
            isTestRunner: isTestRunner
        )
    }

    @Test("proceeds (nil) when every guard is clear")
    func proceedsWhenClear() {
        #expect(gate() == nil)
    }

    @Test("test runner always wins, even if every other guard would also proceed")
    func testRunnerWins() {
        #expect(gate(isTestRunner: true) == .notAttempted(reason: "test runner"))
        #expect(gate(inFlight: true, paneActive: true, isTestRunner: true) == .notAttempted(reason: "test runner"))
    }

    @Test("login pane active blocks even with no other guard tripped")
    func paneActiveBlocks() {
        #expect(gate(paneActive: true) == .notAttempted(reason: "Canvas login pane is active"))
    }

    @Test("an in-flight attempt blocks a second one")
    func inFlightBlocks() {
        #expect(gate(inFlight: true) == .notAttempted(reason: "an attempt is already in flight"))
    }

    @Test("within the 1h cooldown blocks a new attempt")
    func withinCooldownBlocks() {
        let now = Date()
        let last = now.addingTimeInterval(-60) // one minute ago
        #expect(gate(now: now, lastAttempt: last) == .notAttempted(reason: "within the 1h cooldown"))
    }

    @Test("exactly at the cooldown boundary proceeds")
    func atCooldownBoundaryProceeds() {
        let now = Date()
        let last = now.addingTimeInterval(-CanvasSessionRenewer.cooldown)
        #expect(gate(now: now, lastAttempt: last) == nil)
    }

    @Test("past the cooldown window proceeds")
    func pastCooldownProceeds() {
        let now = Date()
        let last = now.addingTimeInterval(-CanvasSessionRenewer.cooldown - 1)
        #expect(gate(now: now, lastAttempt: last) == nil)
    }

    @Test("no prior attempt at all proceeds")
    func neverAttemptedProceeds() {
        #expect(gate(lastAttempt: nil) == nil)
    }

    @Test("guard order: pane-active is checked before in-flight/cooldown")
    func guardOrderPaneBeforeInFlight() {
        let now = Date()
        let last = now.addingTimeInterval(-60)
        let outcome = gate(now: now, lastAttempt: last, inFlight: true, paneActive: true)
        #expect(outcome == .notAttempted(reason: "Canvas login pane is active"))
    }

    @Test("guard order: in-flight is checked before cooldown")
    func guardOrderInFlightBeforeCooldown() {
        let now = Date()
        let last = now.addingTimeInterval(-60)
        let outcome = gate(now: now, lastAttempt: last, inFlight: true)
        #expect(outcome == .notAttempted(reason: "an attempt is already in flight"))
    }

    // MARK: - classifyFinalHost(_:)

    @Test("canvas.upenn.edu classifies as canvas")
    func classifiesCanvasHost() {
        #expect(CanvasSessionRenewer.classifyFinalHost("canvas.upenn.edu") == .canvas)
    }

    @Test("canvas.upenn.edu classification is case-insensitive")
    func classifiesCanvasHostCaseInsensitive() {
        #expect(CanvasSessionRenewer.classifyFinalHost("CANVAS.UPENN.EDU") == .canvas)
    }

    @Test("a selected non-Penn Canvas host classifies as canvas")
    func classifiesSelectedCanvasHost() {
        #expect(CanvasSessionRenewer.classifyFinalHost(
            "canvas.harvard.edu",
            canvasHost: "canvas.harvard.edu"
        ) == .canvas)
    }

    @Test("idp.pennkey.upenn.edu classifies as a login page")
    func classifiesPennKeyIdPHost() {
        #expect(CanvasSessionRenewer.classifyFinalHost("idp.pennkey.upenn.edu") == .loginPage)
    }

    @Test("weblogin variants classify as a login page")
    func classifiesWebloginHost() {
        #expect(CanvasSessionRenewer.classifyFinalHost("weblogin.upenn.edu") == .loginPage)
        #expect(CanvasSessionRenewer.classifyFinalHost("SSO.weblogin.example.edu") == .loginPage)
    }

    @Test("duosecurity classifies as a login page")
    func classifiesDuoHost() {
        #expect(CanvasSessionRenewer.classifyFinalHost("api-abc123.duosecurity.com") == .loginPage)
    }

    @Test("nil host classifies as other")
    func classifiesNilHost() {
        #expect(CanvasSessionRenewer.classifyFinalHost(nil) == .other)
    }

    @Test("an unrelated host classifies as other")
    func classifiesUnrelatedHost() {
        #expect(CanvasSessionRenewer.classifyFinalHost("example.com") == .other)
    }

    // MARK: - isCanvasSessionCookie(_:)

    private func cookie(name: String, domain: String, value: String = "x") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ])!
    }

    @Test("a canvas_session cookie on a canvas domain is recognized")
    func recognizesCanvasSessionCookie() {
        let c = cookie(name: "canvas_session", domain: "canvas.upenn.edu")
        #expect(CanvasSessionRenewer.isCanvasSessionCookie(c))
    }

    @Test("a _normandy_session cookie on a canvas domain is recognized")
    func recognizesNormandySessionCookie() {
        let c = cookie(name: "_normandy_session", domain: "canvas.upenn.edu")
        #expect(CanvasSessionRenewer.isCanvasSessionCookie(c))
    }

    @Test("cookie name matching is case-insensitive")
    func recognizesSessionCookieCaseInsensitive() {
        let c = cookie(name: "CANVAS_SESSION", domain: "canvas.upenn.edu")
        #expect(CanvasSessionRenewer.isCanvasSessionCookie(c))
    }

    @Test("an unrelated cookie name on a canvas domain is not a session cookie")
    func rejectsUnrelatedCookieName() {
        let c = cookie(name: "_ga", domain: "canvas.upenn.edu")
        #expect(!CanvasSessionRenewer.isCanvasSessionCookie(c))
    }

    @Test("a canvas_session-named cookie on a non-canvas domain is rejected")
    func rejectsNonCanvasDomain() {
        let c = cookie(name: "canvas_session", domain: "example.com")
        #expect(!CanvasSessionRenewer.isCanvasSessionCookie(c))
    }

    // MARK: - credentialSubmissionAllowed(lastSubmissionAt:now:) — "stay signed in"

    @Test("no prior submission always allows one")
    func credentialSubmissionAllowedWithNoPriorSubmission() {
        #expect(CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: nil, now: Date()))
    }

    @Test("a submission inside the cooldown window is not allowed")
    func credentialSubmissionBlockedInsideCooldown() {
        let now = Date()
        let last = now.addingTimeInterval(-60) // one minute ago, well inside 6h
        #expect(!CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: last, now: now))
    }

    @Test("a submission exactly at the cooldown boundary is allowed")
    func credentialSubmissionAllowedAtBoundary() {
        let now = Date()
        let last = now.addingTimeInterval(-CanvasSessionRenewer.autoLoginCooldown)
        #expect(CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: last, now: now))
    }

    @Test("a submission just past the cooldown window is allowed")
    func credentialSubmissionAllowedAfterCooldown() {
        let now = Date()
        let last = now.addingTimeInterval(-CanvasSessionRenewer.autoLoginCooldown - 1)
        #expect(CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: last, now: now))
    }

    // MARK: - timeoutOutcome(finalURL:) — round 3, 2026-09-21: Duo no longer settles early

    @Test("a timeout parked on Duo's host classifies as needsDuo")
    func timeoutOutcomeOnDuo() {
        let url = URL(string: "https://api-abc123.duosecurity.com/frame/web/v1/auth")
        #expect(CanvasSessionRenewer.timeoutOutcome(finalURL: url) == .needsDuo)
    }

    @Test("a timeout parked on the IdP login form host classifies as landedOnLoginPage, never passwordRejected")
    func timeoutOutcomeOnLoginForm() {
        let url = URL(string: "https://weblogin.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO?execution=e1s1")
        #expect(CanvasSessionRenewer.timeoutOutcome(finalURL: url) == .landedOnLoginPage)
    }

    @Test("a timeout on any other host (or nil) classifies as timedOut")
    func timeoutOutcomeElseIsTimedOut() {
        #expect(CanvasSessionRenewer.timeoutOutcome(finalURL: URL(string: "https://example.com")) == .timedOut)
        #expect(CanvasSessionRenewer.timeoutOutcome(finalURL: nil) == .timedOut)
    }

    @Test("a background timeout is .timedOut on any host; the foreground one keeps its host classification")
    func timedOutOutcomeByContext() {
        let login = URL(string: "https://weblogin.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO?execution=e1s1")
        let duo = URL(string: "https://api-abc123.duosecurity.com/frame/web/v1/auth")
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: login, isBackground: true) == .timedOut)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: duo, isBackground: true) == .timedOut)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: nil, isBackground: true) == .timedOut)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: login, isBackground: false) == .landedOnLoginPage)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: duo, isBackground: false) == .needsDuo)
    }

    // MARK: - 2026-11-02: foreground spacing, Duo auto-tap

    @Test("foreground constants: 90 s spacing, 60 s cap, 120 s with a push, 10 min credential spacing")
    func foregroundConstants() {
        #expect(CanvasSessionRenewer.foregroundSpacing == 90)
        #expect(CanvasSessionRenewer.timeout == 60)
        #expect(CanvasSessionRenewer.duoPushTimeout == 120)
        #expect(CanvasSessionRenewer.backgroundTimeout == 20)
        #expect(CanvasSessionRenewer.foregroundCredentialSpacing == 600)
        #expect(CanvasSessionRenewer.cooldown == 3600)
        #expect(CanvasSessionRenewer.autoLoginCooldown == 6 * 3600)
    }

    @Test("credential spacing: foreground 10 minutes, background still six hours")
    func credentialSpacingByContext() {
        let now = Date()
        let tenMinutesAgo = now.addingTimeInterval(-600)
        let nineMinutesAgo = now.addingTimeInterval(-540)
        #expect(CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: tenMinutesAgo, now: now, isBackground: false))
        #expect(!CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: nineMinutesAgo, now: now, isBackground: false))
        #expect(!CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: tenMinutesAgo, now: now, isBackground: true))
        #expect(!CanvasSessionRenewer.credentialSubmissionAllowed(lastSubmissionAt: tenMinutesAgo, now: now))
    }

    @Test("a foreground timeout after a Duo push is needsDuo wherever the page is; the background never is")
    func timeoutAfterPush() {
        let other = URL(string: "https://example.com/x")
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: other, isBackground: false, duoPushSent: true) == .needsDuo)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: nil, isBackground: false, duoPushSent: true) == .needsDuo)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: other, isBackground: true, duoPushSent: true) == .timedOut)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: other, isBackground: false) == .timedOut)
    }

    @Test("Duo auto-tap script is host-guarded, posts only two words, and never reads or writes a value")
    func duoScriptShape() {
        let script = DuoPromptAutoTap.script
        #expect(script.contains("duosecurity"))
        #expect(script.contains("lhfDuo"))
        #expect(script.contains("say(\"push\")"))
        #expect(script.contains("say(\"trusted\")"))
        #expect(script.contains("MutationObserver"))
        #expect(!script.contains(".value ="))
        #expect(!script.contains("passcode"))
        #expect(!script.contains("password"))
        #expect(DuoPromptAutoTap.Event(rawValue: "push") == .push)
        #expect(DuoPromptAutoTap.Event(rawValue: "trusted") == .trusted)
        #expect(DuoPromptAutoTap.Event(rawValue: "anything else") == nil)
    }

    @Test("newest session capture ignores analytics cookies and unparseable dates")
    func newestSessionCapture() {
        let iso = ISO8601DateFormatter()
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        let new = old.addingTimeInterval(3600)
        let entries: [[String: String]] = [
            ["name": "canvas_session", "capturedAt": iso.string(from: old)],
            ["name": "_normandy_session", "capturedAt": iso.string(from: new)],
            ["name": "_ga", "capturedAt": iso.string(from: new.addingTimeInterval(9999))],
            ["name": "canvas_session", "capturedAt": "garbage"],
            ["name": "canvas_session"],
        ]
        #expect(SessionCookieStore.newestSessionCapture(entries: entries) == iso.date(from: iso.string(from: new)))
        #expect(SessionCookieStore.newestSessionCapture(entries: [["name": "_ga", "capturedAt": iso.string(from: new)]]) == nil)
        #expect(SessionCookieStore.newestSessionCapture(entries: []) == nil)
    }

    @Test("after a failed foreground submission the next one waits 60 minutes; the background rule is unchanged")
    func failedSubmissionWait() {
        let now = Date()
        let failed = now.addingTimeInterval(-30 * 60)
        let longAgo = now.addingTimeInterval(-3 * 3600)
        #expect(CanvasSessionRenewer.failedSubmissionSpacing == 3600)
        // Plenty past the 10-minute spacing, still inside the 60-minute wait.
        #expect(!CanvasSessionRenewer.credentialSubmissionAllowed(
            lastSubmissionAt: longAgo, now: now, isBackground: false, lastFailedSubmissionAt: failed))
        #expect(CanvasSessionRenewer.credentialSubmissionAllowed(
            lastSubmissionAt: longAgo, now: now, isBackground: false,
            lastFailedSubmissionAt: now.addingTimeInterval(-3600)))
        #expect(CanvasSessionRenewer.credentialSubmissionAllowed(
            lastSubmissionAt: longAgo, now: now, isBackground: false, lastFailedSubmissionAt: nil))
        // The background has its own six hours and ignores this clock.
        #expect(CanvasSessionRenewer.credentialSubmissionAllowed(
            lastSubmissionAt: now.addingTimeInterval(-7 * 3600), now: now, isBackground: true,
            lastFailedSubmissionAt: failed))
    }

    @Test("the failed-submission clock is seeded and never rewinds")
    func failedClockSeeding() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let renewer = CanvasSessionRenewer(isLoginPaneActive: { false }, lastFailedCredentialSubmissionAt: t)
        #expect(renewer.lastFailedCredentialSubmissionAt == t)
        renewer.refreshFailedSubmissionClock(t.addingTimeInterval(-100))
        #expect(renewer.lastFailedCredentialSubmissionAt == t)
        renewer.refreshFailedSubmissionClock(t.addingTimeInterval(100))
        #expect(renewer.lastFailedCredentialSubmissionAt == t.addingTimeInterval(100))
    }

    @Test("a timeout after a push on Canvas itself is an ordinary timeout, not needsDuo")
    func timeoutOnCanvasAfterPush() {
        let canvas = URL(string: "https://canvas.upenn.edu/login/saml")
        let duo = URL(string: "https://api-123.duosecurity.com/frame")
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: canvas, isBackground: false, duoPushSent: true) == .timedOut)
        #expect(CanvasSessionRenewer.timedOutOutcome(finalURL: duo, isBackground: false, duoPushSent: true) == .needsDuo)
    }

    @Test("Duo cookie domains match exactly or by subdomain, never by substring")
    func duoCookieDomain() {
        #expect(AppState.isDuoCookieDomain("duosecurity.com"))
        #expect(AppState.isDuoCookieDomain(".duosecurity.com"))
        #expect(AppState.isDuoCookieDomain("api-123.duosecurity.com"))
        #expect(!AppState.isDuoCookieDomain("notduosecurity.com"))
        #expect(!AppState.isDuoCookieDomain("duosecurity.com.evil.example"))
        #expect(!AppState.isDuoCookieDomain("canvas.upenn.edu"))
    }
}
