import Foundation
import Testing
@testable import LowHangingFruitUI

/// `SessionCookieStore` persists login cookies to the Keychain so a session
/// survives relaunch (see docs/CANVAS_LOGIN_DIAGNOSIS.md). These pin down the
/// expiry/staleness behavior added there: a cookie with a real, past
/// `expiresDate` — or a session-only cookie (no expiry at all) captured too
/// long ago — must never be handed back by `load()` and silently replayed
/// into a fresh login attempt. They also pin down the per-service isolation
/// added in docs/CANVAS_LOGIN_HARDENING.md item 2e: Canvas and Gradescope
/// cookies are stored under separate Keychain items now, keyed by service,
/// not by a domain-substring guess — so a purge of one service can never
/// touch the other's session even when both share a domain (e.g. both flow
/// through Penn SSO's `upenn.edu`).
///
/// The store is process-wide Keychain state (like `AppState`'s
/// `UserDefaults` usage noted in `GradeWatcherCourseResolutionTests`), so
/// every test clears it before and after.
// `.serialized`: every test in this suite shares process-wide Keychain items,
// so running them concurrently (Swift Testing's default) races on the same
// read-modify-write blobs and produces flaky cross-test pollution.
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
            SessionCookieStore.save([cookie(name: "future", domain: "canvas.upenn.edu", expiresDate: future)], service: .canvas)
            let loaded = SessionCookieStore.load(service: .canvas)
            #expect(loaded.contains { $0.name == "future" })
        }
    }

    @Test("A cookie with a past expiresDate is never reloaded — the never-replay-expired-cookies guarantee")
    func pastExpiryIsDropped() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            SessionCookieStore.save([cookie(name: "expired", domain: "canvas.upenn.edu", expiresDate: past)], service: .canvas)
            let loaded = SessionCookieStore.load(service: .canvas)
            #expect(!loaded.contains { $0.name == "expired" })
        }
    }

    @Test("A freshly captured session cookie (no server expiry — Penn SSO/Canvas's own kind) survives a same-moment reload")
    func freshSessionCookieIsKept() {
        withCleanStore {
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu")], service: .canvas)
            let loaded = SessionCookieStore.load(service: .canvas)
            #expect(loaded.contains { $0.name == "sid" })
        }
    }

    @Test("clear() removes every service's cookies")
    func clearRemovesEverything() {
        withCleanStore {
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu")], service: .canvas)
            SessionCookieStore.save([cookie(name: "gsid", domain: "www.gradescope.com")], service: .gradescope)
            SessionCookieStore.clear()
            #expect(SessionCookieStore.load(service: .canvas).isEmpty)
            #expect(SessionCookieStore.load(service: .gradescope).isEmpty)
        }
    }

    // MARK: - Per-service isolation (docs/CANVAS_LOGIN_HARDENING.md item 2e)

    @Test("Cookies saved under one service are invisible to load(service:) for the other service")
    func servicesAreIsolated() {
        withCleanStore {
            SessionCookieStore.save([cookie(name: "canvasCookie", domain: "canvas.upenn.edu")], service: .canvas)
            SessionCookieStore.save([cookie(name: "gradescopeCookie", domain: "www.gradescope.com")], service: .gradescope)

            let canvasLoaded = SessionCookieStore.load(service: .canvas)
            let gradescopeLoaded = SessionCookieStore.load(service: .gradescope)

            #expect(canvasLoaded.contains { $0.name == "canvasCookie" })
            #expect(!canvasLoaded.contains { $0.name == "gradescopeCookie" })
            #expect(gradescopeLoaded.contains { $0.name == "gradescopeCookie" })
            #expect(!gradescopeLoaded.contains { $0.name == "canvasCookie" })
        }
    }

    @Test("remove(service:) only drops that service's cookies, even when both services share a domain (Penn SSO)")
    func removeIsScopedToServiceNotDomain() {
        withCleanStore {
            // Both Canvas and a Gradescope-via-PennKey login can leave a
            // cookie on the exact same upenn.edu domain — the scenario that
            // made the old domain-substring `remove(domainContains: "upenn")`
            // cross-poison the other service.
            SessionCookieStore.save([cookie(name: "canvasSSO", domain: "idp.pennkey.upenn.edu")], service: .canvas)
            SessionCookieStore.save([cookie(name: "gradescopeSSO", domain: "idp.pennkey.upenn.edu")], service: .gradescope)

            SessionCookieStore.remove(service: .canvas)

            #expect(SessionCookieStore.load(service: .canvas).isEmpty)
            #expect(SessionCookieStore.load(service: .gradescope).contains { $0.name == "gradescopeSSO" })
        }
    }

    @Test("loadAll() folds every service's cookies together")
    func loadAllFoldsServices() {
        withCleanStore {
            SessionCookieStore.save([cookie(name: "canvasCookie", domain: "canvas.upenn.edu")], service: .canvas)
            SessionCookieStore.save([cookie(name: "gradescopeCookie", domain: "www.gradescope.com")], service: .gradescope)

            let all = SessionCookieStore.loadAll()
            #expect(all.contains { $0.name == "canvasCookie" })
            #expect(all.contains { $0.name == "gradescopeCookie" })
        }
    }
}
