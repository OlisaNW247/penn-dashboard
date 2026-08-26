import Foundation
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
        guard state.isGradescopeConnected else { return }
        if let last = state.lastGradescopeSync,
           now.timeIntervalSince(last) < gradescopeMinInterval {
            return   // synced recently — skip this tick
        }
        let cookies = await gradescopeCookies()
        if cookies.isEmpty {
            state.setGradescopeConnected(false)
        } else {
            await state.syncGradescope(cookies: cookies, reportErrors: false)
        }
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
        let cookies = await canvasCookies()
        guard !cookies.isEmpty else { return }
        await state.refreshGradeWatcher(cookies: cookies)
        // Readings/silent-course detection (docs/READINGS_COURSES_PLAN.md)
        // piggybacks on the same session rather than gathering its own —
        // a separate, unrelated axis from Grade Watcher's course coverage
        // (see the plan's "Hard requirement — Grade Watcher independence"),
        // just sharing the cookies already in hand.
        await state.refreshCourseIntel(cookies: cookies)
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
    private static func gradescopeCookies() async -> [HTTPCookie] {
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
    static func canvasCookies() async -> [HTTPCookie] {
        let live: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.canvas.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let persisted = SessionCookieStore.load(service: .canvas)
        let liveKeys = Set(live.map { "\($0.name)|\($0.domain)|\($0.path)" })
        let merged = persisted.filter { !liveKeys.contains("\($0.name)|\($0.domain)|\($0.path)") } + live
        return merged.filter { $0.domain.localizedCaseInsensitiveContains("canvas") }
    }
}
