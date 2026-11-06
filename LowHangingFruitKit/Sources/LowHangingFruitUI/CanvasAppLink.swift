import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Canvas documents canvas-courses://host/courses/... for its Student app.
/// Keep the original HTTPS URL for platforms or installations without the app.
enum CanvasAppLink {
    static func appURL(for url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              url.pathComponents.count >= 3,
              url.pathComponents[1] == "courses",
              !url.pathComponents[2].isEmpty,
              url.pathComponents[2].allSatisfy(\.isNumber) else { return nil }
        parts.scheme = "canvas-courses"
        return parts.url
    }

    @MainActor static var action: OpenURLAction {
        OpenURLAction { url in result(for: url) }
    }

    /// What `action` does for one URL, so other open-URL actions (the links in
    /// an ask answer) can route a Canvas URL the same way a card does.
    /// `.systemAction` means "not ours, let the system open it".
    static func result(for url: URL) -> OpenURLAction.Result {
        #if os(iOS)
        guard let appURL = appURL(for: url) else { return .systemAction }
        Task { @MainActor in
            #if DEBUG
            // `canOpenURL` returns false unless `canvas-courses` is listed in
            // LSApplicationQueriesSchemes, which this app does not declare;
            // `open(_:)` of an undeclared scheme still works. This line tells
            // those two cases apart on the phone.
            print("LHF-LINK canOpenURL canvas-courses: \(UIApplication.shared.canOpenURL(URL(string: "canvas-courses://x")!))")
            #endif
            if await UIApplication.shared.open(url, options: [.universalLinksOnly: true]) {
                logOutcome("universal", url)
                return
            }
            if await UIApplication.shared.open(appURL) {
                logOutcome("scheme", url)
                return
            }
            let web = await UIApplication.shared.open(url)
            logOutcome(web ? "scheme failed, web" : "all branches failed", url)
        }
        return .handled
        #else
        return .systemAction
        #endif
    }

    #if os(iOS)
    /// DEBUG only, print only (no ring buffer). Host and path, never the query,
    /// fragment, a cookie or a token.
    private static func logOutcome(_ branch: String, _ url: URL) {
        #if DEBUG
        print("LHF-LINK \(branch) \(url.host ?? "-")\(url.path)")
        #endif
    }
    #endif
}
