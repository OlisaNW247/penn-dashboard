import Foundation
import Testing
import WebKit
@testable import LowHangingFruitUI

/// The hidden renewer shares the pane's app-link guard (2026-11-22: Canvas
/// Student took the SAML return hop of a silent renewal).
@Suite("Renewal app-link guard")
struct RenewalAppLinkGuardTests {
    private static func source(_ name: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        return try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    @Test("the shared decision is the pane's decision")
    func sameDecision() {
        for type in [WKNavigationType.formSubmitted, .other, .linkActivated, .backForward] {
            for current in [nil, "canvas.upenn.edu", "weblogin.pennkey.upenn.edu"] as [String?] {
                #expect(
                    AppLinkGuard.needsAppLinkGuard(destinationHost: "canvas.upenn.edu", currentHost: current,
                                                   guardHost: "canvas.upenn.edu", navigationType: type, hasReissueMarker: false)
                    == LoginNavigationObserver.needsAppLinkGuard(destinationHost: "canvas.upenn.edu", currentHost: current,
                                                   guardHost: "canvas.upenn.edu", navigationType: type, hasReissueMarker: false))
            }
        }
    }

    @Test("the SAML return POST from the IdP is guarded for the renewer's host")
    func samlReturn() {
        #expect(AppLinkGuard.needsAppLinkGuard(destinationHost: "canvas.upenn.edu", currentHost: "weblogin.pennkey.upenn.edu",
                                               guardHost: "canvas.upenn.edu", navigationType: .formSubmitted, hasReissueMarker: false))
        #expect(!AppLinkGuard.needsAppLinkGuard(destinationHost: "canvas.upenn.edu", currentHost: "weblogin.pennkey.upenn.edu",
                                                guardHost: "canvas.upenn.edu", navigationType: .formSubmitted, hasReissueMarker: true))
    }

    @Test("the cap stops reissues at maxAppLinkReissues")
    func cap() {
        #expect(AppLinkGuard.reissueAllowed(count: 0))
        #expect(AppLinkGuard.reissueAllowed(count: AppLinkGuard.maxAppLinkReissues - 1))
        #expect(!AppLinkGuard.reissueAllowed(count: AppLinkGuard.maxAppLinkReissues))
    }

    @Test("the renewer's delegate consults the shared guard before allowing, and is built per attempt with the host")
    func delegateWiring() throws {
        let s = try Self.source("CanvasSessionRenewer.swift")
        let delegate = try #require(s.range(of: "private final class RenewalNavigationDelegate"))
        let tail = String(s[delegate.lowerBound...])
        let guardAt = try #require(tail.range(of: "AppLinkGuard.needsAppLinkGuard"))
        let reissueAt = try #require(tail.range(of: "AppLinkGuard.reissuedRequest"))
        #expect(guardAt.lowerBound < reissueAt.lowerBound)
        #expect(tail.contains("AppLinkGuard.reissueAllowed(count: appLinkReissueCount)"))
        #expect(tail.contains("private var appLinkReissueCount = 0"))
        #expect(s.contains("appLinkGuardHost: installation.host"))
        for line in ["reissued POST", "reissued GET", "form not found, allowed", "cap reached, allowed"] {
            #expect(tail.contains(line))
        }
    }

    @Test("the pane still routes through the shared guard")
    func paneRoutes() throws {
        let s = try Self.source("LoginNavigationObserver.swift")
        #expect(s.contains("AppLinkGuard.needsAppLinkGuard"))
        #expect(s.contains("AppLinkGuard.reissuedRequest"))
        #expect(s.contains("AppLinkGuard.formSerializerScript"))
        #expect(s.contains("AppLinkGuard.maxAppLinkReissues"))
    }
}
