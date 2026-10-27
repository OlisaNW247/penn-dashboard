import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The read-time gate behind `SessionCookieStore.load(service:)`: a Canvas set
/// that once held a session cookie is only as alive as that cookie, so
/// analytics cookies with far-future expiry dates (`_ga`, `_gid`,
/// `last_known_canvas_host`, found on a real phone 2026-10-08) cannot keep the
/// set looking signed in after `canvas_session` itself has gone stale.
///
/// These call the pure `gatedOnLiveSession` and `isCanvasSessionCookieName`
/// directly and touch neither the Keychain nor `UserDefaults`, which is why
/// they may live outside `SessionCookieStoreTests`' `.serialized` suite (the
/// tests that go through the real Keychain are in that suite, beside the
/// `isExpired` ones).
@Suite("Session cookie live-session gate")
struct SessionCookieLiveSessionTests {

    private func cookie(_ name: String, domain: String = "canvas.upenn.edu") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: "v",
            .domain: domain,
            .path: "/",
            .expires: Date().addingTimeInterval(365 * 24 * 60 * 60),
        ])!
    }

    private func names(_ cookies: [HTTPCookie]) -> [String] { cookies.map(\.name) }

    @Test("a polluted set -- analytics cookies fresh, canvas_session persisted but gone from fresh -- reads as empty")
    func pollutedSetIsEmpty() {
        let fresh = [cookie("_ga"), cookie("last_known_canvas_host", domain: "sso.canvaslms.com")]
        let gated = SessionCookieStore.gatedOnLiveSession(
            fresh: fresh,
            persistedNames: ["_ga", "last_known_canvas_host", "canvas_session"],
            service: .canvas
        )
        #expect(gated.isEmpty)
    }

    @Test("canvas_session in fresh returns everything in fresh, analytics cookies included")
    func liveSessionKeepsEverything() {
        let fresh = [cookie("canvas_session"), cookie("_ga"), cookie("_gid")]
        let gated = SessionCookieStore.gatedOnLiveSession(
            fresh: fresh,
            persistedNames: ["canvas_session", "_ga", "_gid"],
            service: .canvas
        )
        #expect(names(gated) == ["canvas_session", "_ga", "_gid"])
    }

    @Test("_normandy_session and _legacy_normandy_session each count as a live session")
    func normandyNamesCountAsLive() {
        for sessionName in ["_normandy_session", "_legacy_normandy_session"] {
            let fresh = [cookie(sessionName), cookie("_ga")]
            let gated = SessionCookieStore.gatedOnLiveSession(
                fresh: fresh,
                persistedNames: [sessionName, "_ga"],
                service: .canvas
            )
            #expect(names(gated) == [sessionName, "_ga"], "\(sessionName) should keep the set alive")
        }
    }

    @Test("matching is case-insensitive in both persistedNames and fresh")
    func matchingIsCaseInsensitive() {
        // Persisted under a differently cased name, session gone from fresh: still gated to empty.
        let polluted = SessionCookieStore.gatedOnLiveSession(
            fresh: [cookie("_ga")],
            persistedNames: ["_ga", "Canvas_Session"],
            service: .canvas
        )
        #expect(polluted.isEmpty)

        // Differently cased session cookie in fresh: set stays alive.
        let live = SessionCookieStore.gatedOnLiveSession(
            fresh: [cookie("CANVAS_SESSION"), cookie("_ga")],
            persistedNames: ["CANVAS_SESSION", "_ga"],
            service: .canvas
        )
        #expect(names(live) == ["CANVAS_SESSION", "_ga"])
    }

    @Test("no session-named cookie ever persisted: fresh is returned unchanged (an unknown session cookie name keeps today's rule)")
    func unknownSessionNameKeepsOldRule() {
        let fresh = [cookie("_ga"), cookie("some_school_sid")]
        let gated = SessionCookieStore.gatedOnLiveSession(
            fresh: fresh,
            persistedNames: ["_ga", "some_school_sid", "stale_unknown_sid"],
            service: .canvas
        )
        #expect(names(gated) == ["_ga", "some_school_sid"])

        let none = SessionCookieStore.gatedOnLiveSession(fresh: [], persistedNames: ["stale_unknown_sid"], service: .canvas)
        #expect(none.isEmpty)
    }

    @Test("Gradescope with the polluted shape is returned unchanged")
    func gradescopeIsUntouched() {
        let fresh = [cookie("_ga", domain: "www.gradescope.com")]
        let gated = SessionCookieStore.gatedOnLiveSession(
            fresh: fresh,
            persistedNames: ["_ga", "canvas_session"],
            service: .gradescope
        )
        #expect(names(gated) == ["_ga"])
    }

    @Test("Ed with the polluted shape is returned unchanged: its session is judged by Ed's own 401, not by Canvas cookie names")
    func edIsUntouched() {
        let fresh = [cookie("_ga", domain: "us.edstem.org")]
        let gated = SessionCookieStore.gatedOnLiveSession(
            fresh: fresh,
            persistedNames: ["_ga", "canvas_session"],
            service: .ed
        )
        #expect(names(gated) == ["_ga"])
    }

    @Test("a session-named cookie persisted and nothing fresh at all reads as empty")
    func persistedSessionWithNothingFreshIsEmpty() {
        let gated = SessionCookieStore.gatedOnLiveSession(
            fresh: [],
            persistedNames: ["canvas_session"],
            service: .canvas
        )
        #expect(gated.isEmpty)
    }

    @Test("isCanvasSessionCookieName: the session names are true; CSRF, log_session_id and analytics names are false")
    func sessionNameMatching() {
        #expect(SessionCookieStore.isCanvasSessionCookieName("canvas_session"))
        #expect(SessionCookieStore.isCanvasSessionCookieName("_normandy_session"))
        #expect(SessionCookieStore.isCanvasSessionCookieName("_legacy_normandy_session"))
        #expect(SessionCookieStore.isCanvasSessionCookieName("Canvas_Session"))
        #expect(!SessionCookieStore.isCanvasSessionCookieName("_csrf_token"))
        #expect(!SessionCookieStore.isCanvasSessionCookieName("log_session_id"))
        #expect(!SessionCookieStore.isCanvasSessionCookieName("_ga"))
        #expect(!SessionCookieStore.isCanvasSessionCookieName("last_known_canvas_host"))
        #expect(!SessionCookieStore.isCanvasSessionCookieName(""))
    }

    /// `CanvasSessionRenewer` keeps its own private copy of the two marker
    /// names (its harvest was left byte for byte as `39b2fff` ran it), and the
    /// store's gate keeps another. If the two ever disagree, the renewer would
    /// save a cookie the gate does not count as a session (or the reverse) and
    /// the sign-in trigger would drift without any test failing. The renewer's
    /// matcher is main-actor isolated with its class, so only this one test is
    /// `@MainActor`; the suite stays nonisolated.
    @MainActor
    @Test("the renewer's session-cookie matcher and the store's agree on every name")
    func renewerAndStoreAgreeOnSessionNames() {
        let names = [
            "canvas_session", "_legacy_normandy_session", "_normandy_session", "CANVAS_SESSION",
            "_csrf_token", "log_session_id", "_ga", "last_known_canvas_host",
        ]
        for name in names {
            let c = cookie(name)
            #expect(
                CanvasSessionRenewer.isCanvasSessionCookie(c) == SessionCookieStore.isCanvasSessionCookieName(name),
                "the renewer and the store disagree about \(name)"
            )
        }
    }
}
