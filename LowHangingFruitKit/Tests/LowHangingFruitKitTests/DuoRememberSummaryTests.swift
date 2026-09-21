import Foundation
import Testing
@testable import LowHangingFruitUI

/// Pure coverage for `AppState.duoRememberSummary(cookies:now:)` — the
/// plain-language read of how long Duo will keep skipping its own prompt
/// for this device, computed from the `duosecurity`-domain cookies in the
/// persistent login WebView store (`AppState.refreshDuoRememberSummary()`).
///
/// `duoRememberSummary(cookies:now:)` is `nonisolated` specifically so it's
/// callable from a plain, non-`@MainActor` test function — `AppState` itself
/// is `@MainActor`, and a `static func` on it inherits that isolation by
/// default, which is exactly the `decidedText`/`tokenIsHealthyEnoughToSkipExpiryCheck`
/// trap (CLAUDE.md): a synchronous swift-testing executor calling an
/// isolated static would die in `_dispatch_assert_queue_fail` with no
/// "Fatal error" line. This suite is deliberately NOT `@MainActor` for that
/// reason, and every test here calls the static function directly with no
/// `await` and no `AppState` instance at all — it's the pure decision, not
/// the live-cookie-read wrapper (`refreshDuoRememberSummary()`, which needs
/// a real `WKWebsiteDataStore` and isn't exercised here for the same
/// WebView-orchestration reason `CanvasSessionRenewerTests`' header comment
/// gives for that class).
@Suite("Duo remembered-device summary")
struct DuoRememberSummaryTests {
    private static let reference = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15, arbitrary and fixed

    private func cookie(name: String, expiresDate: Date? = nil, value: String = "opaque") -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: "api-abc123.duosecurity.com",
            .path: "/",
        ]
        if let expiresDate {
            props[.expires] = expiresDate
        }
        return HTTPCookie(properties: props)!
    }

    @Test("no cookies at all reports no remembered-device cookie")
    func noneReportsNoCookie() {
        let summary = AppState.duoRememberSummary(cookies: [], now: Self.reference)
        #expect(summary == "duo has no remembered-device cookie in the login store")
    }

    @Test("cookies with no expiry (true session cookies) report the count, not a date")
    func sessionOnlyCookiesReportCount() {
        let cookies = [
            cookie(name: "_duo_session"),
            cookie(name: "duo_csrf"),
        ]
        let summary = AppState.duoRememberSummary(cookies: cookies, now: Self.reference)
        #expect(summary == "duo: 2 session-only cookies, none with an expiry")
    }

    @Test("the latest expiry among multiple cookies is the one reported")
    func latestExpiryChosen() throws {
        let sooner = Self.reference.addingTimeInterval(10 * 86_400) // 10 days out
        let later = Self.reference.addingTimeInterval(29 * 86_400) // 29 days out
        let cookies = [
            cookie(name: "duo_older", expiresDate: sooner),
            cookie(name: "duo_remembered_device", expiresDate: later),
        ]
        let summary = AppState.duoRememberSummary(cookies: cookies, now: Self.reference)
        // 2027-01-15 + 29 days = 2027-02-13.
        #expect(summary == "duo cookie duo_remembered_device lives until 2027-02-13 (29 days); "
            + "penn's own remember window is shorter and shows up here as needsDuo when it lapses")
    }

    @Test("a mix of session-only and expiring cookies reports the expiring one, ignoring the session-only ones for the date")
    func mixedCookiesIgnoresSessionOnlyForDate() {
        let later = Self.reference.addingTimeInterval(5 * 86_400)
        let cookies = [
            cookie(name: "_duo_session"),
            cookie(name: "duo_remembered_device", expiresDate: later),
        ]
        let summary = AppState.duoRememberSummary(cookies: cookies, now: Self.reference)
        #expect(summary == "duo cookie duo_remembered_device lives until 2027-01-20 (5 days); "
            + "penn's own remember window is shorter and shows up here as needsDuo when it lapses")
    }

    @Test("an expiry already in the past floors days left at zero, never negative")
    func pastExpiryFloorsAtZero() {
        let past = Self.reference.addingTimeInterval(-86_400)
        let cookies = [cookie(name: "duo_expired", expiresDate: past)]
        let summary = AppState.duoRememberSummary(cookies: cookies, now: Self.reference)
        // A literal `(-1 days)` substring check, not a bare "-1" check — the
        // formatted date itself (`2027-01-14`) legitimately contains a
        // hyphen immediately followed by a digit, which would make a bare
        // "-1" substring check a false positive here.
        #expect(summary.contains("(0 days)"))
        #expect(!summary.contains("(-1 days)"))
    }

    // MARK: - Cookie name truncation (real-device finding, 2026-09-21)
    //
    // A real phone printed the full Duo cookie name in "simulate canvas
    // logout"'s output — `trc|DUTKR0NGCLJFQTDS0HKM|DAERLE1A5S4KKX9U2Q6M` —
    // which embeds a per-device identifier after the first `|` and ends up
    // in `DiagnosticsReport`, and from there in "report a problem" emails.
    // Only the prefix before the first `|` (Duo's own cookie-purpose tag,
    // not a per-device secret) is worth keeping.

    @Test("a cookie name containing | is truncated to the prefix before it, plus an ellipsis")
    func cookieNameWithPipeIsTruncated() {
        let cookies = [
            cookie(
                name: "trc|DUTKR0NGCLJFQTDS0HKM|DAERLE1A5S4KKX9U2Q6M",
                expiresDate: Self.reference.addingTimeInterval(399 * 86_400)
            ),
        ]
        let summary = AppState.duoRememberSummary(cookies: cookies, now: Self.reference)
        #expect(summary.contains("duo cookie trc|… lives until"))
        #expect(!summary.contains("DUTKR0NGCLJFQTDS0HKM"))
        #expect(!summary.contains("DAERLE1A5S4KKX9U2Q6M"))
    }

    @Test("a cookie name with no | is reported unchanged")
    func cookieNameWithoutPipeIsUnchanged() {
        let cookies = [
            cookie(name: "duo_remembered_device", expiresDate: Self.reference.addingTimeInterval(5 * 86_400)),
        ]
        let summary = AppState.duoRememberSummary(cookies: cookies, now: Self.reference)
        #expect(summary.contains("duo cookie duo_remembered_device lives until"))
    }
}
