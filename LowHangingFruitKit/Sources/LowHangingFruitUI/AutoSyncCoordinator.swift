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
        guard state.isCanvasConnected else { return }
        if let last = state.gradeWatcher.lastRefreshed,
           now.timeIntervalSince(last) < canvasGradesMinInterval {
            return
        }
        let cookies = await canvasCookies()
        guard !cookies.isEmpty else { return }
        await state.refreshGradeWatcher(cookies: cookies)
    }

    private static func gradescopeCookies() async -> [HTTPCookie] {
        let live: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }

        // Session cookies vanish between launches, so fold in the persisted set
        // and re-inject them into the WebView store (keeps the in-app login warm).
        let persisted = SessionCookieStore.load()
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in persisted { await cookieStore.setCookie(cookie) }

        // Live values win over persisted ones for the same cookie.
        let liveKeys = Set(live.map { "\($0.name)|\($0.domain)|\($0.path)" })
        let merged = persisted.filter { !liveKeys.contains("\($0.name)|\($0.domain)|\($0.path)") } + live
        return merged.filter { $0.domain.localizedCaseInsensitiveContains("gradescope") }
    }

    /// Gathers Canvas session cookies the same way `gradescopeCookies()` does for
    /// Gradescope: the persisted set (survives relaunch) folded with whatever the
    /// in-app WebView session currently holds (live values win on overlap), replayed
    /// into the WebView store so the in-app login stays warm. Shared by this
    /// coordinator's launch-time grades refresh and `GradeWatcherView`'s own
    /// refresh, so both callers agree on one cookie-gathering implementation.
    static func canvasCookies() async -> [HTTPCookie] {
        let live: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let persisted = SessionCookieStore.load()
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in persisted { await cookieStore.setCookie(cookie) }
        let liveKeys = Set(live.map { "\($0.name)|\($0.domain)|\($0.path)" })
        let merged = persisted.filter { !liveKeys.contains("\($0.name)|\($0.domain)|\($0.path)") } + live
        return merged.filter { $0.domain.localizedCaseInsensitiveContains("canvas") }
    }
}
