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
        OpenURLAction { url in
            #if os(iOS)
            guard let appURL = appURL(for: url) else { return .systemAction }
            Task { @MainActor in
                if await UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { return }
                if await UIApplication.shared.open(appURL) { return }
                await UIApplication.shared.open(url)
            }
            return .handled
            #else
            return .systemAction
            #endif
        }
    }
}
