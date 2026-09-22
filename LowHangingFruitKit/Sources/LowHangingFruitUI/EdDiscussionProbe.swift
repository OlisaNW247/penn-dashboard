#if DEBUG
import Foundation
import WebKit
import LowHangingFruitKit

/// Owner-only diagnostic (CLAUDE.md's "probe ed discussion" task): drives a
/// hidden, hardened `WKWebView` through a Canvas course's "Ed Discussion"
/// LTI launch and reports whether the WebView actually ends up on Ed, signed
/// in — hosts, paths, HTTP-adjacent status codes, and the NAMES of web
/// storage keys and cookies only, never a value (see `EdProbeScript`'s own
/// privacy-rule doc comment in the Kit target). Compiles out of every
/// Release build; the only caller is
/// `AppState.probeEdDiscussionForTesting()`.
///
/// Shape deliberately mirrors `CanvasSessionRenewer.performAttempt` (same
/// file, same target): a `WKWebViewConfiguration` bound to
/// `LoginDataStores.canvas` — never `.default()` or a fresh store, because
/// the whole point is riding whatever Canvas session the app's real login
/// already established — the same UA hardening, the shared `SettleWaiter`
/// resumed-once signal, strong `active*` references discarded in one
/// `defer`, and a hard timeout racing navigation settlement. Never added to
/// any view hierarchy: `webView.frame` stays `.zero`.
@MainActor
final class EdDiscussionProbe {
    /// Once the WebView's main frame first lands on an Ed host, Ed's own
    /// single-page app still has to boot (parse its bundle, read whatever
    /// session it finds, render) before `document.cookie`/`localStorage`
    /// reflect its finished state — settling the instant the URL changes
    /// would race that boot and likely under-report. Not measured against a
    /// real Ed session (`docs/`'s "known gaps" pattern: this whole feature
    /// is unverified against real Canvas/Ed data), so treat 3s as a
    /// reasonable guess rather than a tuned constant.
    fileprivate static let settleAfterLandingOnEd: TimeInterval = 3
    /// A borderless LTI launch is normally two or three redirects
    /// (Canvas → Ed's own OAuth/LTI endpoint → Ed) that complete in a couple
    /// of seconds; 40s leaves headroom for a slow network without leaving
    /// the owner staring at a spinner indefinitely if something upstream
    /// genuinely hangs.
    private static let hardTimeout: TimeInterval = 40

    /// See `CanvasSessionRenewer.activeWebView`'s doc comment for why these
    /// three need a strong reference held on `self` rather than being local
    /// variables: `WKWebView.navigationDelegate` is `weak`, and the WebView
    /// itself would otherwise have no owner keeping it alive across the
    /// `await` in `run(launchURL:)`.
    private var activeWebView: WKWebView?
    private var activeDelegate: EdProbeNavigationDelegate?
    private var activeWaiter: SettleWaiter?

    /// Runs one probe attempt end to end and returns the whole report as one
    /// string, ready to show in Settings or copy to the pasteboard. Never
    /// throws — every failure mode (script error, decode failure, timeout)
    /// becomes text in the result instead, since this is a diagnostic the
    /// owner reads, not a path anything else depends on succeeding.
    func run(launchURL: URL) async -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = LoginDataStores.canvas
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.customUserAgent = LoginUserAgent.mobileSafari

        let waiter = SettleWaiter()
        let delegate = EdProbeNavigationDelegate(waiter: waiter)
        webView.navigationDelegate = delegate
        activeWebView = webView
        activeDelegate = delegate
        activeWaiter = waiter
        defer {
            activeWebView?.navigationDelegate = nil
            activeWebView = nil
            activeDelegate = nil
            activeWaiter = nil
        }

        // GET-only, exactly one `load` call — same discipline
        // `CanvasSessionRenewer` documents for its own single load, for the
        // same reason: this probe must never itself cause a second
        // credential submission or LTI re-launch.
        webView.load(URLRequest(url: launchURL))

        let timeoutTask = Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(Self.hardTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            waiter?.signal(.timedOut)
        }
        _ = await waiter.wait()
        timeoutTask.cancel()

        let finalPage = CanvasSessionRenewer.hostPathString(webView.url) ?? "(no page)"

        let reportText = await Self.formattedReport(from: webView)
        // Fetched once, raw, and reused for both the names-only display line
        // and `nativeWhoAmI`'s own request — see `edCookies()`'s doc comment
        // for why the split exists at all.
        let edCookies = await Self.edCookies()
        let cookieLines = Self.edCookieLines(from: edCookies)
        let nativeWhoAmILine = await Self.nativeWhoAmI(using: edCookies)

        var lines: [String] = []
        lines.append("hops: \(delegate.hops.isEmpty ? "(none)" : delegate.hops.joined(separator: " → "))")
        lines.append("final: \(finalPage)")
        lines.append(reportText)
        lines.append("ed cookies (names only): \(cookieLines.isEmpty ? "(none)" : cookieLines.joined(separator: ", "))")
        lines.append(nativeWhoAmILine)
        return lines.joined(separator: "\n")
    }

    /// Runs `EdProbeScript.inspectPage` and decodes its result.
    ///
    /// Uses the completion-handler form of `callAsyncJavaScript`
    /// (`_:arguments:in:in:completionHandler:` — two `in` labels, frame then
    /// content world, exactly as `CanvasAccessTokenMinter.mint` documents
    /// this same API) rather than the `async throws` overload, wrapped in a
    /// `withCheckedContinuation` — matching this codebase's established
    /// pattern for bridging a WebKit completion handler into `async`.
    ///
    /// The completion handler's `Result<Any, Error>` is narrowed to a local,
    /// `Sendable` `ScriptOutcome` (String-only payloads) BEFORE it crosses
    /// the continuation, never the raw `Any`/`Error` — this is the same trap
    /// `CanvasSessionRenewer.handleNonCanvasFinish` already hit and
    /// documents: `Any?` is not `Sendable`, and letting it cross a
    /// continuation fails with "sending value risks causing data races."
    /// Decoded via plain `Foundation.JSONDecoder` — no custom date/key
    /// strategy needed, since every field in `EdProbeReport` already matches
    /// the JS's own camelCase names. A script error or a decode failure
    /// becomes descriptive text rather than being thrown further — see
    /// `run(launchURL:)`'s own "never throws" doc comment.
    private static func formattedReport(from webView: WKWebView) async -> String {
        enum ScriptOutcome: Sendable {
            case json(String)
            case error(String)
            case empty
        }
        let outcome: ScriptOutcome = await withCheckedContinuation { (continuation: CheckedContinuation<ScriptOutcome, Never>) in
            webView.callAsyncJavaScript(
                EdProbeScript.inspectPage,
                arguments: [:],
                in: nil,
                // `.page` is the page's own JavaScript world, not an
                // isolated client world (`CanvasAccessTokenMinter` uses
                // `.defaultClient`; either sees `document.cookie`, storage
                // and same-origin `fetch`). The page world is the one whose
                // `fetch` runs exactly as Ed's own client code would, which
                // is the comparison this probe exists to make.
                in: .page
            ) { result in
                switch result {
                case let .success(value):
                    if let json = value as? String {
                        continuation.resume(returning: .json(json))
                    } else {
                        continuation.resume(returning: .empty)
                    }
                case let .failure(error):
                    continuation.resume(returning: .error(error.localizedDescription))
                }
            }
        }
        switch outcome {
        case .empty:
            return "probe script returned no usable result"
        case let .error(message):
            return "probe script failed: \(message)"
        case let .json(jsonString):
            guard let data = jsonString.data(using: .utf8) else {
                return "probe script returned no usable result"
            }
            do {
                let report = try JSONDecoder().decode(EdProbeReport.self, from: data)
                return report.formatted()
            } catch {
                return "could not decode probe result: \(error.localizedDescription)\nraw: \(jsonString)"
            }
        }
    }

    /// Read-only harvest from the SAME persistent store the WebView just
    /// navigated in — never `setCookie`/`removeData` against it, matching
    /// `CanvasSessionRenewer.performAttempt`'s own read-only cookie harvest.
    /// Returns the RAW cookies (filtered to a domain containing "edstem")
    /// rather than already-formatted text, because two different callers
    /// need them for two different reasons: `edCookieLines` turns them into
    /// the names-only display line, and `nativeWhoAmI` needs the actual
    /// `Cookie:` header WebKit would have sent — fetching once and sharing
    /// the result avoids two separate trips to the cookie store for what is,
    /// underneath, the same one-time snapshot.
    private static func edCookies() async -> [HTTPCookie] {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            LoginDataStores.canvas.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return cookies.filter { $0.domain.localizedCaseInsensitiveContains("edstem") }
    }

    /// Names, domains and expiry dates only; never a cookie's value —
    /// enforcing this task's privacy rule.
    private static func edCookieLines(from cookies: [HTTPCookie]) -> [String] {
        cookies
            .map { cookie -> String in
                let expiry: String
                if cookie.isSessionOnly {
                    expiry = "session"
                } else if let expires = cookie.expiresDate {
                    expiry = dateFormatter.string(from: expires)
                } else {
                    expiry = "session"
                }
                return "\(cookie.name) @ \(cookie.domain) (expires \(expiry))"
            }
            .sorted()
    }

    /// A SECOND, independent "is this session actually good" check, run
    /// entirely outside the WebView/page context, alongside (not instead
    /// of) `EdProbeScript`'s in-page `fetch`.
    ///
    /// Why both exist: the in-page `fetch` runs under Ed's OWN page origin
    /// (`us.edstem.org`), so if Ed's API doesn't allow a credentialed
    /// cross-origin call from its own page in whatever configuration this
    /// launch produced, the in-page fetch fails with a generic, content-free
    /// "Load failed" — which says nothing about whether the session itself
    /// is valid, only that that ONE call shape didn't work. This request, by
    /// contrast, is built and sent exactly the way a plain URLSession-based
    /// Ed client (or a future non-WebView integration) would send it: a
    /// `Cookie` header built straight from the cookies just harvested from
    /// `LoginDataStores.canvas`, nothing WebView- or page-origin-specific.
    /// Its status is therefore the answer that actually matters for "does
    /// the session Canvas's LTI launch produced work for a real API call" —
    /// independent of whatever CORS policy governs the in-page path.
    ///
    /// Reports only an HTTP status and (for a 2xx JSON response) a course
    /// count — never a header, never the response body, matching this
    /// task's names-only/no-values privacy rule exactly as strictly as
    /// `EdProbeScript` does for the in-page side.
    private static func nativeWhoAmI(using edCookies: [HTTPCookie]) async -> String {
        guard !edCookies.isEmpty else {
            return "native whoAmI: skipped (no ed cookies in the store)"
        }
        guard let url = URL(string: "https://us.edstem.org/api/user") else {
            return "native whoAmI: skipped (bad URL)"
        }
        var request = URLRequest(url: url)
        // `httpShouldHandleCookies = false` plus an explicit `Cookie` header
        // built from exactly the cookies harvested above is the same
        // discipline every other Canvas client in this codebase already
        // follows (`CanvasCourseContentClient.fetch`) — this request's only
        // credential is the header set below, never whatever
        // `URLSession(configuration: .ephemeral)`'s own (empty, freshly
        // created) cookie jar might otherwise contribute.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in HTTPCookie.requestHeaderFields(with: edCookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let session = URLSession(configuration: .ephemeral)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "native whoAmI: error: not an HTTP response"
            }
            guard (200..<300).contains(http.statusCode) else {
                return "native whoAmI: status=\(http.statusCode) courses=n/a"
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let courses = json["courses"] as? [Any]
            else {
                return "native whoAmI: status=\(http.statusCode) courses=unparsed"
            }
            return "native whoAmI: status=\(http.statusCode) courses=\(courses.count)"
        } catch {
            return "native whoAmI: error: \(error.localizedDescription)"
        }
    }

    /// Fixed `en_US_POSIX`/UTC — a diagnostic string shown once to the app
    /// owner, not a cached document, but there's no reason to let it drift
    /// with the device locale/timezone either.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// Observe-only `WKNavigationDelegate` local to this probe — same posture as
/// `CanvasSessionRenewer`'s own `RenewalNavigationDelegate` (never cancels,
/// redirects or re-navigates; only watches) but simpler, since this probe
/// isn't trying to auto-fill anything: it just wants to know when the chain
/// has landed on Ed, and to keep a plain host+path hop list along the way.
@MainActor
private final class EdProbeNavigationDelegate: NSObject, WKNavigationDelegate {
    private let waiter: SettleWaiter
    /// Plain host+path (never the query string) for every navigation this
    /// probe attempt saw, in the order they happened — read back by
    /// `EdDiscussionProbe.run(launchURL:)` only after `waiter.wait()`
    /// resolves. Stored on the delegate itself, appended to only from this
    /// delegate's own (`@MainActor`-isolated) callbacks, rather than
    /// captured by an `@escaping` closure into a `var` local to `run`: a
    /// mutable local captured by an escaping closure is exactly the shape
    /// Swift 6 strict concurrency flags as a possible data race, and this
    /// diagnostic was written with no compiler on hand to confirm whether it
    /// actually would have been flagged here — so it's avoided outright
    /// rather than gambled on.
    private(set) var hops: [String] = []
    /// Guards against settling twice if Ed's own SPA does a same-host
    /// client-side navigation that somehow re-triggers `didFinish` — the
    /// settle-after-boot `Task` below should only ever be started once.
    private var hasSeenEd = false

    init(waiter: SettleWaiter) {
        self.waiter = waiter
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hops.append(CanvasSessionRenewer.hostPathString(webView.url) ?? "(no host)")
        guard !hasSeenEd, EdHosts.isEd(webView.url) else { return }
        hasSeenEd = true
        Task { @MainActor [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(EdDiscussionProbe.settleAfterLandingOnEd * 1_000_000_000))
            guard !Task.isCancelled else { return }
            waiter?.signal(.finished)
        }
    }

    /// A borderless LTI launch can produce one aborted intermediate hop
    /// (the tool's own launch form posting, then immediately redirecting)
    /// that WebKit reports as a failure rather than a `didFinish` — logged
    /// into the hop list and NOT treated as fatal; only the hard timeout in
    /// `run(launchURL:)` gives up on a chain that never reaches Ed.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        hops.append("error: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        hops.append("error: \(error.localizedDescription)")
    }

    // Same signature discipline `RenewalNavigationDelegate` documents for
    // these two — required by the protocol, and this probe never wants to
    // steer the chain, only observe it.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}
#endif
