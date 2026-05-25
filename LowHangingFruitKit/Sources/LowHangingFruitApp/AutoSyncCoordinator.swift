import Foundation
import WebKit

@MainActor
enum AutoSyncCoordinator {
    static func syncConnectedServices(state: AppState) async {
        let cookies = await allCookies()

        if state.isGradescopeConnected {
            let gradescopeCookies = cookies.filter { cookie in
                cookie.domain.localizedCaseInsensitiveContains("gradescope.com")
            }
            if !gradescopeCookies.isEmpty {
                await state.syncGradescope(cookies: gradescopeCookies, reportErrors: false)
            } else {
                state.setGradescopeConnected(false)
            }
        }

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
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
