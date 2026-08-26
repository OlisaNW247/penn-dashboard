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
        #expect(gate(paneActive: true, inFlight: true, isTestRunner: true) == .notAttempted(reason: "test runner"))
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
}
