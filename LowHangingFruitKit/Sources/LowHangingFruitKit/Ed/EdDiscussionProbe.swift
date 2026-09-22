import Foundation

/// Pure, reusable pieces of the "probe ed discussion" DEBUG diagnostic
/// (`EdDiscussionProbe` in `LowHangingFruitUI` drives the actual `WKWebView`;
/// everything in this file is Kit-side and has no WebKit dependency, so it's
/// exercised directly by `swift test`). The one question this whole feature
/// exists to answer: when the app opens a Canvas course's "Ed Discussion" nav
/// tool (an LTI launch) inside its own Canvas login WebView, does the WebView
/// actually end up on Ed, signed in? Nothing here is DEBUG-gated on purpose —
/// these are plain data/URL helpers a later, real feature (surfacing Ed
/// content the same way course materials are surfaced today) would reuse
/// as-is; only the UI-side WebView driver and its Settings row are
/// DEBUG-only.
public enum EdHosts {
    /// True for `edstem.org` itself and any of its subdomains
    /// (`us.edstem.org`, the one the widely-deployed Ed integration actually
    /// runs on). Deliberately host-only, not path- or scheme-qualified —
    /// this is used to recognize "the WebView's main frame is now on Ed at
    /// all," which is the coarse signal the probe waits on before it tries
    /// anything JavaScript-side.
    public static func isEd(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "edstem.org" || host.hasSuffix(".edstem.org")
    }
}

/// Finds the Ed Discussion entry, if any, in a course's Canvas navigation
/// tabs (`CanvasCourseTab`, from `GET /courses/:id/tabs`).
public enum EdTabFinder {
    /// URL evidence beats label text: an instructor can rename the nav entry
    /// to anything ("Q&A", "Discussion Board", …), but the tab's own
    /// `url`/`html_url` still points at Canvas's `external_tools` launch
    /// page for whichever LTI tool is actually configured, and for Ed that
    /// page URL (or, on some Canvas versions, the tab's `url` field
    /// directly) contains "edstem" regardless of what the label says. Only
    /// when neither URL field mentions Ed does this fall back to the label,
    /// and only a conservative reading of the label: the tab's lowercased
    /// label's FIRST word must itself start with "ed" — matching "Ed", "Ed
    /// Discussion", "Ed (Q&A)" (first word "ed"), and "EdStem" (first word
    /// "edstem", a common one-word branding of the same product) — while
    /// leaving "Feedback" alone (first word "feedback", which contains the
    /// substring "ed" but does not itself START with "ed") and "Media
    /// Gallery" / "Modules" alone (first words "media"/"modules"). A plain
    /// `label.contains("ed")` would have wrongly matched "Feedback"; that's
    /// the bug this word-position check exists to avoid.
    public static func edTab(in tabs: [CanvasCourseTab]) -> CanvasCourseTab? {
        if let byURL = tabs.first(where: { tab in
            let candidates = [tab.url, tab.htmlURL].compactMap { $0?.lowercased() }
            return candidates.contains { $0.contains("edstem") }
        }) {
            return byURL
        }
        return tabs.first { tab in
            guard let firstWord = tab.label.lowercased().split(separator: " ").first else { return false }
            return firstWord.hasPrefix("ed")
        }
    }

    /// The URL to actually load in the probe's WebView, built from the tab's
    /// `html_url` (Canvas's own `external_tools` launch page for that tool,
    /// resolved against `canvasBase` if the stored value is relative) with
    /// `display=borderless` appended.
    ///
    /// Why `display=borderless` is not optional: Canvas's normal
    /// `external_tools` launch page renders the LTI tool inside an `<iframe>`
    /// — the tool's auto-submitting SAML/LTI launch form posts and redirects
    /// entirely *inside that iframe*, while the WebView's own main frame
    /// stays on canvas.upenn.edu the whole time. A main-frame script (this
    /// probe's `EdProbeScript.inspectPage`, or `didFinish`'s own
    /// `webView.url`) would then see only Canvas, never Ed, no matter how
    /// long it waits — the exact false negative this diagnostic exists to
    /// avoid. `display=borderless` is Canvas's own documented "give me just
    /// the tool, no chrome" query parameter, and it changes what Canvas
    /// EMITS: instead of an iframe wrapper, Canvas serves the tool's
    /// auto-submitting launch form directly as the page itself, so THAT
    /// navigation happens on the WebView's main frame and the WebView's own
    /// `url` genuinely becomes an Ed URL once the LTI hop completes.
    public static func launchURL(for tab: CanvasCourseTab, canvasBase: URL) -> URL? {
        guard let raw = tab.htmlURL, !raw.isEmpty else { return nil }
        let resolved: URL?
        if let absolute = URL(string: raw), absolute.scheme != nil {
            resolved = absolute
        } else {
            resolved = URL(string: raw, relativeTo: canvasBase)
        }
        guard let resolved, var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            return nil
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "display", value: "borderless"))
        components.queryItems = items
        return components.url
    }
}

/// The in-page JavaScript run once the probe's WebView settles on (what it
/// believes is) Ed. Run via `WKWebView.callAsyncJavaScript`, `.page` content
/// world, main frame only.
///
/// **The privacy rule this whole diagnostic exists under: names only, never
/// values.** `Object.keys(localStorage)` and `Object.keys(sessionStorage)`
/// enumerate KEY NAMES without ever calling `getItem`, and cookie reporting
/// parses `document.cookie` for the text before each `=` and discards
/// everything after it. The one exception — reading an actual API response
/// body — is `whoAmI`, and even there only a course count and the student's
/// own already-known course codes are kept; no token, id, name or session
/// value from that response is ever read into the returned object. This is
/// enforced by convention here, not by a runtime guard, so any change to
/// this string must preserve it: see `EdDiscussionProbeTests` for the
/// standing check that this source contains no `getItem` call.
public enum EdProbeScript {
    /// A JSON object (via `JSON.stringify`) with this shape, every field
    /// optional because each step below runs in its own try/catch and a
    /// failure produces `<field>Error` text instead of aborting the rest of
    /// the script:
    /// ```
    /// {
    ///   "host": "us.edstem.org", "path": "/course/1234", "title": "...",
    ///   "localStorageKeys": ["ed_session", ...],
    ///   "sessionStorageKeys": [...],
    ///   "cookieNames": ["ed_session_v2", ...],
    ///   "whoAmI": { "status": 200, "ok": true, "courseCount": 3,
    ///               "courseCodes": ["CIS 1200", ...] },
    ///   "pageError": "...", "localStorageKeysError": "...",
    ///   "sessionStorageKeysError": "...", "cookieNamesError": "...",
    ///   "whoAmIError": "..."
    /// }
    /// ```
    /// Written as an async IIFE that RETURNS a Promise, which
    /// `callAsyncJavaScript` awaits itself (per its own documented contract
    /// — it either awaits a returned thenable or reads a plain `return`
    /// value), so this same string would also work unchanged if some future
    /// caller needed to embed it inside a larger script.
    public static let inspectPage: String = """
    return (async () => {
      var out = {};
      try {
        out.host = location.host;
        out.path = location.pathname;
        out.title = (document.title || "").slice(0, 80);
      } catch (e) {
        out.pageError = String((e && e.message) || e);
      }
      try {
        out.localStorageKeys = Object.keys(localStorage);
      } catch (e) {
        out.localStorageKeysError = String((e && e.message) || e);
      }
      try {
        out.sessionStorageKeys = Object.keys(sessionStorage);
      } catch (e) {
        out.sessionStorageKeysError = String((e && e.message) || e);
      }
      try {
        out.cookieNames = document.cookie
          ? document.cookie.split(";").map(function (p) { return p.split("=")[0].trim(); }).filter(Boolean)
          : [];
      } catch (e) {
        out.cookieNamesError = String((e && e.message) || e);
      }
      try {
        // The one live network call this script makes, and the actual test:
        // a 2xx here means the session Ed's launch established is carried in
        // an ordinary cookie a plain `credentials: "include"` fetch can ride
        // on — the strongest possible "yes, signed in" signal. A non-2xx
        // (401 most likely) means Ed's own web client authenticates some
        // other way (a bearer token stashed in storage, most likely — which
        // is exactly what the storage key names above are for), and that is
        // itself the finding this probe reports, not a failure to work
        // around.
        var resp = await fetch("https://us.edstem.org/api/user", { credentials: "include" });
        var whoAmI = { status: resp.status, ok: resp.ok, courseCount: null, courseCodes: [] };
        if (resp.ok) {
          try {
            var body = await resp.json();
            var courses = (body && body.courses) || [];
            whoAmI.courseCount = courses.length;
            whoAmI.courseCodes = courses.slice(0, 20).map(function (c) {
              return c && c.course && c.course.code;
            });
          } catch (parseErr) {
            whoAmI.parseError = String((parseErr && parseErr.message) || parseErr);
          }
        }
        out.whoAmI = whoAmI;
      } catch (e) {
        out.whoAmIError = String((e && e.message) || e);
      }
      return JSON.stringify(out);
    })();
    """
}

/// Decoded form of `EdProbeScript.inspectPage`'s JSON result. Every field is
/// optional: a fresh install, an ad blocker, or a genuinely signed-out Ed
/// session can each legitimately produce a report missing several of these,
/// and a missing field is itself informative (paired with its `...Error`
/// sibling) rather than something to treat as a decode failure.
public struct EdProbeReport: Decodable, Sendable {
    public struct WhoAmI: Decodable, Sendable {
        public let status: Int?
        public let ok: Bool?
        public let courseCount: Int?
        public let courseCodes: [String?]?
        public let parseError: String?
    }

    public let host: String?
    public let path: String?
    public let title: String?
    public let localStorageKeys: [String]?
    public let sessionStorageKeys: [String]?
    public let cookieNames: [String]?
    public let whoAmI: WhoAmI?
    public let pageError: String?
    public let localStorageKeysError: String?
    public let sessionStorageKeysError: String?
    public let cookieNamesError: String?
    public let whoAmIError: String?

    /// Compact multi-line text for the Settings row / pasteboard — never
    /// truncates a name list (there are at most a few dozen), only ever
    /// prints names/counts/statuses.
    public func formatted() -> String {
        var lines: [String] = []
        if let host, let path {
            lines.append("landed: \(host)\(path)")
        } else if let pageError {
            lines.append("landed: <error: \(pageError)>")
        } else {
            lines.append("landed: (unknown)")
        }
        if let title, !title.isEmpty {
            lines.append("title: \(title)")
        }
        lines.append("localStorage keys: \(Self.list(localStorageKeys, error: localStorageKeysError))")
        lines.append("sessionStorage keys: \(Self.list(sessionStorageKeys, error: sessionStorageKeysError))")
        lines.append("cookie names: \(Self.list(cookieNames, error: cookieNamesError))")
        if let whoAmI {
            var line = "whoAmI: status=\(whoAmI.status.map(String.init) ?? "?") ok=\(whoAmI.ok.map { $0 ? "true" : "false" } ?? "?")"
            if let count = whoAmI.courseCount {
                line += " courses=\(count)"
                let codes = (whoAmI.courseCodes ?? []).compactMap { $0 }
                if !codes.isEmpty {
                    line += " [\(codes.joined(separator: ", "))]"
                }
            } else {
                line += " courses=nil"
            }
            if let parseError = whoAmI.parseError {
                line += " parseError=\(parseError)"
            }
            lines.append(line)
        } else if let whoAmIError {
            lines.append("whoAmI: <error: \(whoAmIError)>")
        }
        return lines.joined(separator: "\n")
    }

    private static func list(_ values: [String]?, error: String?) -> String {
        if let values { return values.isEmpty ? "(none)" : values.joined(separator: ", ") }
        if let error { return "<error: \(error)>" }
        return "(unavailable)"
    }
}
