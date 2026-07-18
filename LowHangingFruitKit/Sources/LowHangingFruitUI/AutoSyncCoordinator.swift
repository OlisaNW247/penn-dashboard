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
}
