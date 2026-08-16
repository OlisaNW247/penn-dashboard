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
    //
    // The `isExpired(service:)` coverage that used to live here now lives in
    // `SessionCookieStoreTests` instead (see that file's "Group 3d" section).
    // This suite runs with Swift Testing's default (parallel, unserialized)
    // execution, but `SessionCookieStore` is process-wide Keychain state
    // shared across every test that touches it — so a Keychain test here ran
    // concurrently with `SessionCookieStoreTests`' own `.canvas`-service tests
    // (which *are* `.serialized`, but only relative to each other, not to an
    // unrelated suite). The result was a genuine data race, not a product
    // bug: one test's `SessionCookieStore.clear()`/`save()` could interleave
    // with another's `save()`/`isExpired()` on the exact same Keychain item,
    // since `SessionCookieStore.write()` is a non-atomic delete-then-add.
    // That's what intermittently produced "SessionCookieStore.isExpired ...
    // is false while a live cookie is on record → true" here, and a sibling
    // "future expiresDate cookie disappears" failure over in
    // `SessionCookieStoreTests` — both symptoms of the same race, not a
    // cookie-serialization bug. See docs/CANVAS_LOGIN_HARDENING.md item 3d
    // for the full writeup.
}
