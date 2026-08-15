import Foundation
import Testing
@testable import LowHangingFruitUI

/// `SessionCookieStore` persists login cookies to the Keychain so a session
/// survives relaunch (see docs/CANVAS_LOGIN_DIAGNOSIS.md). These pin down the
/// expiry/staleness behavior added there: a cookie with a real, past
/// `expiresDate` — or a session-only cookie (no expiry at all) captured too
/// long ago — must never be handed back by `load()` and silently replayed
/// into a fresh login attempt.
///
/// The store is a single process-wide Keychain item (like `AppState`'s
/// `UserDefaults` usage noted in `GradeWatcherCourseResolutionTests`), so
/// every test clears it before and after.
// `.serialized`: every test in this suite shares one process-wide Keychain
// item, so running them concurrently (Swift Testing's default) races on the
// same read-modify-write blob and produces flaky cross-test pollution.
@Suite("Session cookie store", .serialized)
struct SessionCookieStoreTests {

    private func withCleanStore(_ body: () -> Void) {
        SessionCookieStore.clear()
        defer { SessionCookieStore.clear() }
        body()
    }

    private func cookie(name: String, domain: String, expiresDate: Date? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "v",
            .domain: domain,
            .path: "/",
        ]
        if let expiresDate { props[.expires] = expiresDate }
        return HTTPCookie(properties: props)!
    }

    @Test("A cookie with a future expiresDate is persisted and reloaded")
    func futureExpiryIsKept() {
        withCleanStore {
            let future = Date().addingTimeInterval(3600)
            SessionCookieStore.save([cookie(name: "future", domain: "canvas.upenn.edu", expiresDate: future)])
            let loaded = SessionCookieStore.load()
            #expect(loaded.contains { $0.name == "future" })
        }
    }

    @Test("A cookie with a past expiresDate is never reloaded — the never-replay-expired-cookies guarantee")
    func pastExpiryIsDropped() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            SessionCookieStore.save([cookie(name: "expired", domain: "canvas.upenn.edu", expiresDate: past)])
            let loaded = SessionCookieStore.load()
            #expect(!loaded.contains { $0.name == "expired" })
        }
    }

    @Test("A freshly captured session cookie (no server expiry — Penn SSO/Canvas's own kind) survives a same-moment reload")
    func freshSessionCookieIsKept() {
        withCleanStore {
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu")])
            let loaded = SessionCookieStore.load()
            #expect(loaded.contains { $0.name == "sid" })
        }
    }

    @Test("remove(domainContains:) only drops matching-domain cookies, leaving others intact")
    func removeIsScopedToDomain() {
        withCleanStore {
            SessionCookieStore.save([
                cookie(name: "canvasCookie", domain: "canvas.upenn.edu"),
                cookie(name: "gradescopeCookie", domain: "www.gradescope.com"),
            ])
            SessionCookieStore.remove(domainContains: "canvas")
            let loaded = SessionCookieStore.load()
            #expect(!loaded.contains { $0.name == "canvasCookie" })
            #expect(loaded.contains { $0.name == "gradescopeCookie" })
        }
    }

    @Test("clear() removes everything")
    func clearRemovesEverything() {
        withCleanStore {
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu")])
            SessionCookieStore.clear()
            #expect(SessionCookieStore.load().isEmpty)
        }
    }
}
