import Foundation
import Testing
@testable import LowHangingFruitUI

/// Pins down the specific fixes in docs/CANVAS_LOGIN_HARDENING.md that are
/// cheap to test without a live WebView/network (which the rest of that
/// document's fixes need — see the decision record for what's covered by
/// manual verification instead).
@Suite("Canvas login hardening")
struct CanvasLoginHardeningTests {

    // MARK: - Group 1b: purge needles actually match real WKWebsiteDataRecord displayNames

    @MainActor @Test("canvasLoginDomainHints matches the eTLD+1 displayName WebKit reports for the whole SP/IdP/Duo chain")
    func canvasLoginDomainHintsMatchRealDisplayNames() {
        // WKWebsiteDataRecord.displayName is the eTLD+1 (registrable domain),
        // not the full host — e.g. a cookie on `canvas.upenn.edu` or
        // `idp.pennkey.upenn.edu` both report `"upenn.edu"`.
        let realDisplayNames = ["upenn.edu", "duosecurity.com", "instructure.com"]
        for displayName in realDisplayNames {
            let matches = AppState.canvasLoginDomainHints.contains {
                displayName.localizedCaseInsensitiveContains($0)
            }
            #expect(matches, "expected some needle to match displayName \(displayName)")
        }
    }

    @Test("the old dead needles ('canvas', 'pennkey') would never have matched the real eTLD+1 displayName")
    func oldDeadNeedlesDontMatchRealDisplayNames() {
        // Documents WHY they were removed: this is what "silently dead" meant.
        let deadNeedles = ["canvas", "pennkey"]
        let realDisplayNames = ["upenn.edu", "duosecurity.com", "instructure.com"]
        for needle in deadNeedles {
            let matchesAnything = realDisplayNames.contains { $0.localizedCaseInsensitiveContains(needle) }
            #expect(!matchesAnything, "needle \(needle) unexpectedly matched a real displayName")
        }
    }

    // MARK: - Group 3b: webcal:// rewriting

    @MainActor @Test("webcal:// is rewritten to https://")
    func webcalIsRewrittenToHTTPS() {
        let rewritten = AppState.rewritingWebcalScheme("webcal://canvas.upenn.edu/feeds/calendars/user_abc123.ics")
        #expect(rewritten == "https://canvas.upenn.edu/feeds/calendars/user_abc123.ics")
    }

    @MainActor @Test("webcal:// is rewritten case-insensitively")
    func webcalRewriteIsCaseInsensitive() {
        let rewritten = AppState.rewritingWebcalScheme("WebCal://canvas.upenn.edu/feeds/calendars/user_abc123.ics")
        #expect(rewritten == "https://canvas.upenn.edu/feeds/calendars/user_abc123.ics")
    }

    @MainActor @Test("an already-https:// URL is left untouched")
    func httpsURLIsUntouched() {
        let url = "https://canvas.upenn.edu/feeds/calendars/user_abc123.ics"
        #expect(AppState.rewritingWebcalScheme(url) == url)
    }

    @MainActor @Test("an unrelated string with no webcal:// prefix is left untouched")
    func unrelatedStringIsUntouched() {
        #expect(AppState.rewritingWebcalScheme("not a url") == "not a url")
        #expect(AppState.rewritingWebcalScheme("") == "")
    }

    // MARK: - Group 3d: canvasSessionExpired, distinct from isCanvasConnected

    @Test("SessionCookieStore.isExpired(service:) is false when nothing was ever persisted for that service")
    func isExpiredFalseWhenNeverConnected() {
        SessionCookieStore.clear()
        defer { SessionCookieStore.clear() }
        #expect(!SessionCookieStore.isExpired(service: .canvas))
    }

    @Test("SessionCookieStore.isExpired(service:) is true once every persisted entry for that service has aged past its expiry")
    func isExpiredTrueOnceEverythingIsStale() {
        SessionCookieStore.clear()
        defer { SessionCookieStore.clear() }
        let past = Date().addingTimeInterval(-3600)
        let cookie = HTTPCookie(properties: [
            .name: "sid", .value: "v", .domain: "canvas.upenn.edu", .path: "/", .expires: past,
        ])!
        SessionCookieStore.save([cookie], service: .canvas)
        #expect(SessionCookieStore.isExpired(service: .canvas))
    }

    @Test("SessionCookieStore.isExpired(service:) is false while a live (non-expired) cookie is on record")
    func isExpiredFalseWhileLiveCookieExists() {
        SessionCookieStore.clear()
        defer { SessionCookieStore.clear() }
        let future = Date().addingTimeInterval(3600)
        let cookie = HTTPCookie(properties: [
            .name: "sid", .value: "v", .domain: "canvas.upenn.edu", .path: "/", .expires: future,
        ])!
        SessionCookieStore.save([cookie], service: .canvas)
        #expect(!SessionCookieStore.isExpired(service: .canvas))
    }
}
