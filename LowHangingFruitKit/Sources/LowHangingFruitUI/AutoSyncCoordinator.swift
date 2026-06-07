import Foundation
import WebKit

@MainActor
enum AutoSyncCoordinator {
    static func syncConnectedServices(state: AppState) async {
        let cookies = await allCookies()

        if state.isCanvasDiscoveryConnected && !state.canvasItems.isEmpty {
            let canvasCookies = cookies.filter { cookie in
                cookie.domain.localizedCaseInsensitiveContains("canvas.upenn.edu")
            }
            if !canvasCookies.isEmpty {
                await state.scanCanvasRequirements(cookies: canvasCookies, reportErrors: false)
            } else {
                state.setCanvasDiscoveryConnected(false)
            }
        }
    }

    private static func allCookies() async -> [HTTPCookie] {
        let store: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        // WKWebsiteDataStore drops session cookies (Gradescope/SSO) between
        // launches, so fold in the ones we persisted at connect time. Re-inject
        // them into the WebView store too, so the in-app login shows as signed in.
        let persisted = SessionCookieStore.load()
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        for cookie in persisted {
            await cookieStore.setCookie(cookie)
        }

        // Live store values win over persisted ones for the same cookie.
        let liveKeys = Set(store.map { "\($0.name)|\($0.domain)|\($0.path)" })
        let merged = persisted.filter { !liveKeys.contains("\($0.name)|\($0.domain)|\($0.path)") } + store
        return merged
    }
}
