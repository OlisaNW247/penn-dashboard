import Foundation
import LowHangingFruitKit
import WebKit

/// Re-syncs cookie-authenticated sources on launch and activation, using the
/// login cookies persisted at connect time. Canvas's ICS feed is cookieless and
/// is synced separately (`AppState.syncIfConfigured`); this handles Gradescope,
/// whose session cookies `WKWebsiteDataStore` drops between launches.
@MainActor
enum AutoSyncCoordinator {
    /// Minimum spacing between automatic Gradescope scrapes. Gradescope has no
    /// student API, so a sync fetches the account page plus every course and
    /// assignment page — far too heavy to run on the dashboard's 5-minute Canvas
    /// loop. Throttling keeps request volume low (a courtesy to Gradescope and a
    /// hedge against rate-limiting the user's account) and saves battery.
    /// Assignment lists rarely change within the window.
    static let gradescopeMinInterval: TimeInterval = 15 * 60

    /// Minimum spacing between automatic Canvas-grades refreshes. Lighter than
    /// Gradescope (paginated REST JSON, not full-page scrapes), but still a
    /// per-course fetch, so it's throttled off the dashboard's 5-minute loop.
    static let canvasGradesMinInterval: TimeInterval = 15 * 60

    static func syncConnectedServices(state: AppState, now: Date = Date()) async {
        await syncConnectedServices(
            state: state,
            now: now,
            gradescopeCookieProvider: gradescopeCookies,
            emptySetOutcome: SessionCookieStore.emptyGradescopeSetOutcome
        )
    }

    /// The seam behind `syncConnectedServices(state:now:)`: the cookie read and
    /// the reading of an empty result are injected so a test can hand it an
    /// empty set without touching `WKWebsiteDataStore` or the Keychain.
    ///
    /// **An empty cookie set never disconnects.** This used to call
    /// `setGradescopeConnected(false)` on it, which turned "no cookies came
    /// back this time" into a permanent disconnect: the next tick's `guard
    /// state.isGradescopeConnected` stopped every future sync and the student
    /// had to sign in again by hand. Gradescope's cookies carry no expiry and,
    /// since 2026-10-27, no 24-hour clock either
    /// (`SessionCookieStore.maxAge(for:)`), so an empty read is a Keychain
    /// that answered badly or an item that is gone. The wrong fix is keeping
    /// the disconnect but making it rarer: any call to
    /// `setGradescopeConnected(false)` that a read failure can reach is the bug.
    ///
    /// **But a definitively gone set is evidence.** A phone restored from a
    /// backup keeps the "connected" flag and the rows while its this-device-only
    /// Keychain items stay behind; nothing is then sent to Gradescope, so no
    /// login form ever answers, and the student would read stale rows forever.
    /// `emptySetOutcome` reads the saved set once more and, when it answers
    /// "not found" (or every entry is expired), records the same sighting a
    /// login form is; two such runs an hour apart raise "reconnect gradescope"
    /// (`GradescopeReauthRule`). A Keychain that would not answer counts for
    /// nothing. Still no disconnect: the flag, the rows and the cookies stay.
    static func syncConnectedServices(
        state: AppState,
        now: Date,
        gradescopeCookieProvider: () async -> [HTTPCookie],
        emptySetOutcome: () -> GradescopeReauthRule.Outcome
    ) async {
        guard state.isGradescopeConnected else { return }
        if let last = state.lastGradescopeSync,
           now.timeIntervalSince(last) < gradescopeMinInterval {
            return   // synced recently — skip this tick
        }
        let cookies = await gradescopeCookieProvider()
        guard !cookies.isEmpty else {
            state.recordGradescopeOutcome(emptySetOutcome(), now: now)
            return
        }
        await state.syncGradescope(cookies: cookies, reportErrors: false)
    }

    /// Refreshes Canvas grades (and thus the submission side-channel that drives
    /// auto "submitted" state) using the persisted Canvas session, throttled and
    /// launch/activation-driven like the Gradescope sync. Grades otherwise only
    /// refresh when the user opens Grade Watcher; this makes submission detection
    /// work on the dashboard without visiting that screen.
    static func refreshCanvasGrades(state: AppState, now: Date = Date()) async {
        // A pasted-calendar-link install has no cookie session at all, so this
        // path could only ever no-op — gate on `canUseGradeWatcher`, not the
        // weaker `isCanvasConnected` (true for that install too).
        guard state.canUseGradeWatcher else { return }
        if let last = state.gradeWatcher.lastRefreshed,
           now.timeIntervalSince(last) < canvasGradesMinInterval {
            return
        }
        let cookies = await canvasCookies(forHost: state.canvasInstallation.host)
        // A usable Canvas access token authenticates every REST fetch below
        // on its own (`CanvasAuth.apply` sends `Bearer <token>` and no
        // cookies at all when one's present) — so an empty cookie array is
        // no longer automatically "nothing to do here." Only bail when
        // BOTH are missing. `CanvasDiscoveryClient` inside
        // `refreshCourseIntel` below stays cookie-only regardless (it
        // scrapes HTML pages a Bearer token is never honored on) and will
        // simply no-op on an empty cookie array, same as it always has for
        // a session with no cookies at all.
        guard !cookies.isEmpty || state.hasCanvasCredentials else { return }
        await state.refreshGradeWatcher(cookies: cookies)
        // Readings/silent-course detection (docs/READINGS_COURSES_PLAN.md)
        // piggybacks on the same session rather than gathering its own —
        // a separate, unrelated axis from Grade Watcher's course coverage
        // (see the plan's "Hard requirement — Grade Watcher independence"),
        // just sharing the cookies already in hand.
        await state.refreshCourseIntel(cookies: cookies)
        // Course materials for `ask` ride the same session, throttled by
        // their own staleness window (`AppState.courseKnowledgeStaleAfter`,
        // one hour) rather than this function's 15-minute one. With
        // `BackendServices` configured this is no longer just a Canvas
        // fetch — it's a manifest exchange with LHF's shared course-material
        // store first, then Canvas only for whatever the manifest says this
        // phone doesn't already have fresh (see the header of
        // `AppState+CourseKnowledge.swift`). Settings no longer offers an
        // on-demand trigger for this; it always rides this refresh.
        await state.refreshCourseKnowledge(cookies: cookies)
    }

    /// Gathers Gradescope session cookies: the Keychain-persisted set
    /// (survives relaunch — `WKWebsiteDataStore` drops session-only cookies
    /// between launches) folded with whatever Gradescope's isolated login
    /// store currently holds live (live values win on overlap for the same
    /// cookie). These are only ever used to build an explicit `Cookie` header
    /// for `GradescopeClient`'s requests (see docs/CANVAS_LOGIN_HARDENING.md
    /// item 2c) — they are deliberately NOT written back into any
    /// `WKWebsiteDataStore`. An earlier version of this function replayed the
    /// persisted set into the live login store to "keep the in-app login
    /// warm"; that's exactly the mechanism that poisoned a fresh login
    /// attempt with a dead cookie (docs/CANVAS_LOGIN_DIAGNOSIS.md H1/H2), and
    /// it served no purpose for the HTTP fetches, which never read from that
    /// store in the first place.
    static func gradescopeCookies() async -> [HTTPCookie] {
        let live: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.gradescope.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let persisted = SessionCookieStore.load(service: .gradescope)
        let liveKeys = Set(live.map { "\($0.name)|\($0.domain)|\($0.path)" })
        let merged = persisted.filter { !liveKeys.contains("\($0.name)|\($0.domain)|\($0.path)") } + live
        return merged.filter { $0.domain.localizedCaseInsensitiveContains("gradescope") }
    }

    /// Gathers Canvas session cookies the same way `gradescopeCookies()` does
    /// for Gradescope — see its doc comment for why the live login store is
    /// only ever read from, never written back to. Shared by this
    /// coordinator's launch-time grades refresh and `GradeWatcherView`'s own
    /// refresh, so both callers agree on one cookie-gathering implementation.
    ///
    /// Penn keeps the original substring filter (`domain contains "canvas"`)
    /// verbatim rather than the generalized `cookie(_:belongsTo:)` match
    /// below, matching the session behaviour a co-owner's phone has run
    /// unchanged for a week (39b2fff): this function's only job at Penn is
    /// producing exactly the cookie set that build gathers, byte for byte.
    /// Non-Penn installations didn't exist at 39b2fff and never know
    /// "canvas" is even in their hostname (Columbia's is
    /// `courseworks.columbia.edu`), so they use the newer, host-aware match.
    static func canvasCookies(forHost canvasHost: String = CanvasInstallation.penn.host) async -> [HTTPCookie] {
        let live: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.canvas.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let persisted = SessionCookieStore.load(service: .canvas)
        let liveKeys = Set(live.map { "\($0.name)|\($0.domain)|\($0.path)" })
        let merged = persisted.filter { !liveKeys.contains("\($0.name)|\($0.domain)|\($0.path)") } + live
        if canvasHost == CanvasInstallation.penn.host {
            return merged.filter { $0.domain.localizedCaseInsensitiveContains("canvas") }
        }
        return merged.filter { cookie($0, belongsTo: canvasHost) }
    }

    /// Canvas installations are not required to put the word "canvas" in
    /// their hostname (Columbia uses `courseworks.columbia.edu`, for example).
    /// Match normal cookie-domain semantics against the selected installation
    /// instead of guessing from a product-name substring.
    nonisolated static func cookie(_ cookie: HTTPCookie, belongsTo host: String) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}
