import Foundation
import Testing
@testable import LowHangingFruitKit
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
///
/// Grade Watcher availability tests that touch `.canvas` cookie state also
/// live here, for the same serialization reason (see the Group 4 note near
/// the bottom of this suite) — do not "tidy" them back out into their own
/// `GradeWatcherAvailabilityTests.swift` suite. Swift Testing runs distinct
/// suites in parallel by default, so a second `.serialized` suite touching
/// this same process-wide `.canvas` Keychain item would still race against
/// the tests below; only being members of this one suite serializes them
/// against each other.
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

    // MARK: - Group 3d: canvasSessionExpired, distinct from isCanvasConnected
    //
    // Moved here from `CanvasLoginHardeningTests` (docs/CANVAS_LOGIN_HARDENING.md
    // item 3d): that suite runs unserialized, so its `.canvas`-service
    // Keychain tests raced against this suite's own `.canvas`-service tests
    // over the same process-wide Keychain item, intermittently losing writes.
    // Every test that touches `SessionCookieStore` needs to live in this
    // `.serialized` suite — see the suite doc comment above.

    @Test("SessionCookieStore.isExpired(service:) is false when nothing was ever persisted for that service")
    func isExpiredFalseWhenNeverConnected() {
        withCleanStore {
            #expect(!SessionCookieStore.isExpired(service: .canvas))
        }
    }

    @Test("SessionCookieStore.isExpired(service:) is true once every persisted entry for that service has aged past its expiry")
    func isExpiredTrueOnceEverythingIsStale() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu", expiresDate: past)], service: .canvas)
            #expect(SessionCookieStore.isExpired(service: .canvas))
        }
    }

    @Test("SessionCookieStore.isExpired(service:) is false while a live (non-expired) cookie is on record")
    func isExpiredFalseWhileLiveCookieExists() {
        withCleanStore {
            let future = Date().addingTimeInterval(3600)
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu", expiresDate: future)], service: .canvas)
            #expect(!SessionCookieStore.isExpired(service: .canvas))
        }
    }

    // The read-time live-session gate, end to end through the real Keychain
    // (the pure rules are in `SessionCookieLiveSessionTests`; this is the only
    // test that proves `load(service:)` actually routes through them). It
    // uses a real past `expiresDate` for `canvas_session` rather than a
    // no-expiry cookie aged past 24 hours: there is no seam that can age a
    // saved cookie under `swift test` (`dict(from:)` stamps `capturedAt` as
    // now, and `ageCanvasSessionForTesting` is a no-op for the test runner),
    // and for the gate the two are the same state, "session-named cookie
    // persisted and no longer fresh".
    @Test("isExpired is true when only an analytics cookie outlives the Canvas session cookie (the 2026-10-08 phone's shape)")
    func isExpiredTrueWhenOnlyAnalyticsCookieSurvives() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            let farFuture = Date().addingTimeInterval(365 * 24 * 60 * 60)
            SessionCookieStore.save([
                cookie(name: "canvas_session", domain: "canvas.upenn.edu", expiresDate: past),
                cookie(name: "_ga", domain: "canvas.upenn.edu", expiresDate: farFuture),
            ], service: .canvas)
            #expect(SessionCookieStore.hasSavedCookies(service: .canvas))
            #expect(SessionCookieStore.load(service: .canvas).isEmpty)
            #expect(SessionCookieStore.isExpired(service: .canvas))
        }
    }

    @Test("a polluted set recovers once a fresh canvas_session is saved over the stale one, the state a successful silent renewal leaves")
    func pollutedSetRecoversAfterFreshSessionIsSaved() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            let farFuture = Date().addingTimeInterval(365 * 24 * 60 * 60)
            SessionCookieStore.save([
                cookie(name: "canvas_session", domain: "canvas.upenn.edu", expiresDate: past),
                cookie(name: "_ga", domain: "canvas.upenn.edu", expiresDate: farFuture),
            ], service: .canvas)
            #expect(SessionCookieStore.isExpired(service: .canvas))

            // Same name, domain and path, so `save` replaces the stale entry
            // rather than adding a second one. No expiry: a true session
            // cookie, captured just now, which is what Canvas re-issues.
            SessionCookieStore.save([cookie(name: "canvas_session", domain: "canvas.upenn.edu")], service: .canvas)

            let loaded = SessionCookieStore.load(service: .canvas)
            #expect(!loaded.isEmpty)
            #expect(loaded.contains { $0.name == "canvas_session" })
            #expect(!SessionCookieStore.isExpired(service: .canvas))
        }
    }

    @Test("a healthy set, a fresh canvas_session beside a far-future _ga, loads both and is not expired: the gate is not a filter on what is replayed")
    func healthySetLoadsEveryCookie() {
        withCleanStore {
            let farFuture = Date().addingTimeInterval(365 * 24 * 60 * 60)
            SessionCookieStore.save([
                cookie(name: "canvas_session", domain: "canvas.upenn.edu"),
                cookie(name: "_ga", domain: "canvas.upenn.edu", expiresDate: farFuture),
            ], service: .canvas)

            let names = Set(SessionCookieStore.load(service: .canvas).map(\.name))
            #expect(names == ["canvas_session", "_ga"])
            #expect(!SessionCookieStore.isExpired(service: .canvas))
        }
    }

    // The store-level half of the "Canvas login is gone" rule
    // (`CanvasLoginMissingTests`). `isExpired` stays exactly as it was: it is
    // false for a deleted item, indistinguishable from a never-connected
    // pasted-link install, and that is why the missing-login rule needs the
    // separate `hasSavedCookies` read plus a "logged in before" flag.

    @Test("hasSavedCookies is false when nothing was ever persisted for that service")
    func hasSavedCookiesFalseWhenEmpty() {
        withCleanStore {
            #expect(!SessionCookieStore.hasSavedCookies(service: .canvas))
        }
    }

    @Test("hasSavedCookies is true for a stale-only set, where load() is empty and isExpired is true")
    func hasSavedCookiesTrueForStaleOnlySet() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu", expiresDate: past)], service: .canvas)
            #expect(SessionCookieStore.hasSavedCookies(service: .canvas))
            #expect(SessionCookieStore.load(service: .canvas).isEmpty)
            #expect(SessionCookieStore.isExpired(service: .canvas))
        }
    }

    @Test("after remove(service:) hasSavedCookies is false and isExpired is still false, which is why the rule needs the flag")
    func removedItemIsNotReportedExpired() {
        withCleanStore {
            let past = Date().addingTimeInterval(-3600)
            SessionCookieStore.save([cookie(name: "sid", domain: "canvas.upenn.edu", expiresDate: past)], service: .canvas)
            SessionCookieStore.remove(service: .canvas)
            #expect(!SessionCookieStore.hasSavedCookies(service: .canvas))
            #expect(!SessionCookieStore.isExpired(service: .canvas))
        }
    }

    // MARK: - Full-fidelity round-trip (secure, httpOnly, sameSite, expiry)

    @Test("A realistic Canvas-like cookie (secure, httpOnly, future expiry) round-trips every attribute, not just name/value")
    func fullFidelityRoundTrip() {
        withCleanStore {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: "_csrf_token",
                .value: "abc123def456",
                .domain: "canvas.upenn.edu",
                .path: "/",
                .secure: "TRUE",
            ]
            props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            let future = Date().addingTimeInterval(3600)
            props[.expires] = future
            props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
            let original = HTTPCookie(properties: props)!

            SessionCookieStore.save([original], service: .canvas)
            let loaded = SessionCookieStore.load(service: .canvas)

            guard let reloaded = loaded.first(where: { $0.name == "_csrf_token" }) else {
                Issue.record("cookie did not survive the round trip at all")
                return
            }
            #expect(reloaded.value == "abc123def456")
            #expect(reloaded.domain == "canvas.upenn.edu")
            #expect(reloaded.path == "/")
            #expect(reloaded.isSecure)
            #expect(reloaded.isHTTPOnly)
            #expect(reloaded.sameSitePolicy == .sameSiteLax)
            // Keychain persistence round-trips through a string formatter, so
            // compare with a coarse tolerance rather than bit-for-bit equality.
            let expiresDelta = abs((reloaded.expiresDate ?? .distantPast).timeIntervalSince(future))
            #expect(expiresDelta < 1)
        }
    }

    // MARK: - Group 4: Grade Watcher availability tests that touch `.canvas`
    // cookie state
    //
    // Moved here from `GradeWatcherAvailabilityTests` for the same reason as
    // the Group 3d move above: that suite was its own `.serialized` suite,
    // but Swift Testing runs distinct suites in parallel by default, so it
    // was NOT serialized against this suite's own `.canvas`-service tests
    // over the same process-wide Keychain item. Folding these two tests in
    // here — rather than keeping a second `.serialized` suite alive — is
    // what actually serializes them. Each is `@MainActor` individually
    // because it touches `AppState`, but the suite itself deliberately stays
    // non-isolated so the rest of its tests are unaffected.

    /// Same in-memory-store injection as `IntroFlowTests`, so this suite
    /// can't contend with a real on-disk ledger from a machine that has
    /// actually run the app.
    @MainActor
    private func makeGradeWatcherState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    @MainActor
    @Test("a calendar-link-only install (feed URL set, no Canvas cookies) cannot use Grade Watcher")
    func calendarLinkOnlyCannotUseGradeWatcher() {
        SessionCookieStore.clear()
        let state = makeGradeWatcherState()
        defer {
            // `disconnectCanvas()` drops both the cookie session (already
            // empty here) and the feed URL this test set, so the next test
            // doesn't inherit either.
            state.disconnectCanvas()
            SessionCookieStore.clear()
        }

        state.updateCanvasICSURL("https://canvas.upenn.edu/feeds/calendars/user_test123.ics")
        state.refreshCanvasSessionExpiredState()

        #expect(state.isCanvasConnected)
        #expect(!state.canvasSessionExpired)
        #expect(!state.canUseGradeWatcher)
    }

    @MainActor
    @Test("an expired Canvas session still allows Grade Watcher — the reconnect path stays reachable")
    func expiredSessionCanUseGradeWatcher() {
        SessionCookieStore.clear()
        defer { SessionCookieStore.clear() }

        let past = Date().addingTimeInterval(-3600)
        let cookie = HTTPCookie(properties: [
            .name: "sid",
            .value: "v",
            .domain: "canvas.upenn.edu",
            .path: "/",
            .expires: past,
        ])!
        SessionCookieStore.save([cookie], service: .canvas)

        let state = makeGradeWatcherState()
        state.refreshCanvasSessionExpiredState()

        #expect(state.canvasSessionExpired)
        #expect(state.canUseGradeWatcher)
    }

    // MARK: - A refused Keychain read is not "signed out" (hardening plan A5)
    //
    // The Keychain can decline to answer (locked before first unlock, a
    // refused access list). The old code read that as `[]`, and `[]` is what
    // "nothing saved" and "everything aged out" both look like, so a refusal
    // raised the banner, started a renewal, or wrote back over the saved set.
    // The decisions are driven through their injectable halves, because a
    // test cannot make the real Keychain refuse.

    private typealias Entries = [[String: String]]
    private let refused = KeychainRead<Entries>.unavailable(errSecInteractionNotAllowed)

    private func entry(_ name: String) -> [String: String] {
        ["name": name, "value": "v", "domain": "canvas.upenn.edu", "path": "/"]
    }

    @Test("hasSavedCookies reads an unavailable Keychain as saved, a missing item as not saved")
    func hasSavedThreeWays() {
        #expect(SessionCookieStore.hasSavedCookies(from: refused))
        #expect(!SessionCookieStore.hasSavedCookies(from: .notFound))
        #expect(!SessionCookieStore.hasSavedCookies(from: .found([])))
        #expect(SessionCookieStore.hasSavedCookies(from: .found([entry("a")])))
    }

    @Test("isExpired reads an unavailable Keychain as not expired, and never asks for the fresh set")
    func isExpiredUnavailable() {
        var freshAsked = false
        let expired = SessionCookieStore.isExpired(
            service: .canvas,
            read: { _ in self.refused },
            fresh: { _ in freshAsked = true; return [] }
        )
        #expect(!expired)
        #expect(!freshAsked)
    }

    @Test("isExpired is false for a missing item and for an empty saved set")
    func isExpiredNothingSaved() {
        for read in [KeychainRead<Entries>.notFound, .found([])] {
            #expect(!SessionCookieStore.isExpired(service: .canvas, read: { _ in read }, fresh: { _ in [] }))
        }
    }

    @Test("isExpired is true only when entries are saved, nothing is fresh, and the set is still there on a re-read")
    func isExpiredConfirmed() {
        #expect(SessionCookieStore.isExpired(
            service: .canvas, read: { _ in .found([self.entry("a")]) }, fresh: { _ in [] }))
        #expect(!SessionCookieStore.isExpired(
            service: .canvas,
            read: { _ in .found([self.entry("a")]) },
            fresh: { _ in [self.cookie(name: "sid", domain: "canvas.upenn.edu")] }))
    }

    @Test("a read refused only on the confirming re-read does not pass for everything-aged-out")
    func isExpiredRefusedOnSecondRead() {
        var reads = 0
        let expired = SessionCookieStore.isExpired(
            service: .canvas,
            read: { _ in
                reads += 1
                return reads == 1 ? .found([self.entry("a")]) : self.refused
            },
            fresh: { _ in [] }   // load() came back empty because its own read was refused
        )
        #expect(!expired)
        #expect(reads == 2)
    }

    @Test("save never writes back over a set it could not read, and starts fresh from a missing one")
    func saveWriteBackGuard() {
        let incoming = [cookie(name: "new", domain: "canvas.upenn.edu")]
        #expect(SessionCookieStore.storedSet(afterSaving: incoming, into: refused) == nil)

        let fromNothing = SessionCookieStore.storedSet(afterSaving: incoming, into: .notFound)
        #expect(fromNothing?.map { $0["name"] } == ["new"])
    }

    @Test("save merges into a found set: the incoming cookie replaces its twin and the rest is kept")
    func saveMergesIntoFound() {
        let existing: Entries = [entry("keep"), entry("replace")]
        let incoming = [cookie(name: "replace", domain: "canvas.upenn.edu")]
        let merged = SessionCookieStore.storedSet(afterSaving: incoming, into: .found(existing))
        #expect(Set(merged?.compactMap { $0["name"] } ?? []) == ["keep", "replace"])
        #expect(merged?.count == 2)
        // The replaced entry now carries a capture stamp from this save.
        #expect(merged?.first { $0["name"] == "replace" }?["capturedAt"] != nil)
    }

    @Test("a second save updates the item in place: both saves' cookies are there, one item")
    func realKeychainTwoSavesKeepBoth() {
        withCleanStore {
            SessionCookieStore.save([cookie(name: "one", domain: "canvas.upenn.edu")], service: .canvas)
            SessionCookieStore.save([cookie(name: "two", domain: "canvas.upenn.edu")], service: .canvas)
            let names = Set(SessionCookieStore.load(service: .canvas).map(\.name))
            #expect(names == ["one", "two"])
            #expect(SessionCookieStore.hasSavedCookies(service: .canvas))
            #expect(!SessionCookieStore.isExpired(service: .canvas))
        }
    }

    @Test("the real Keychain says not saved after a clear, and saved after a save")
    func realKeychainSavedState() {
        withCleanStore {
            #expect(!SessionCookieStore.hasSavedCookies(service: .gradescope))
            SessionCookieStore.save([cookie(name: "g", domain: "www.gradescope.com")], service: .gradescope)
            #expect(SessionCookieStore.hasSavedCookies(service: .gradescope))
            SessionCookieStore.remove(service: .gradescope)
            #expect(!SessionCookieStore.hasSavedCookies(service: .gradescope))
        }
    }
}
