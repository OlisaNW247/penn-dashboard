import Foundation
import LowHangingFruitKit

/// One cheap question put straight to Canvas: is the session these cookies
/// belong to still alive? `GET /api/v1/users/self` with the saved cookies and
/// no bearer token.
///
/// **Why it exists.** Grade Watcher used to answer "no course succeeded and
/// one of them said 401" by deleting the saved Canvas cookie item. But
/// Canvas answers 401 for "not allowed" as well as for "signed out": a
/// concluded course, or one that restricts its grades or assignments, says
/// `401 {"status":"unauthorized"}` to a perfectly live session (CLAUDE.md,
/// "Canvas answers 401 for 'not allowed'"). A student whose only watched
/// course had ended therefore lost a working session to a refresh, and was
/// asked to sign in again for nothing. A course's 401 is evidence about that
/// course; `users/self` is evidence about the login, because every signed-in
/// student may read their own profile and nobody else's session can.
///
/// **What the wrong fixes would have been.** Reading the 401 body's wording
/// ("user not authorized to perform that action" versus "invalid access
/// token"), which Canvas has reworded before. Or keeping the delete and
/// adding a retry: the delete is the harm, and it cannot be undone, because
/// the cookies were the only copy.
///
/// **Three answers, and only one of them acts.** Nothing here deletes
/// anything. `.alive` and `.unknown` change nothing (offline, a 5xx, a
/// maintenance page and a vanity-domain redirect are all "I could not tell",
/// and not telling must never sign anyone out). `.dead` is the one verdict a
/// caller may act on, and the acting it does is the renewal path that
/// already exists, not a purge.
enum CanvasSessionProbe {

    enum Verdict: Equatable, Sendable {
        /// 200 with a JSON object: Canvas knows who is asking.
        case alive
        /// 401, or a redirect (or a final page) that is a login page.
        case dead
        /// Anything else, including a request that never got an answer.
        case unknown
    }

    // MARK: - Pure rule

    /// The whole verdict, from nothing but what came back. `finalURL` is
    /// where the answer came from: the response's own URL, or, for a 3xx the
    /// probe refused to follow, the redirect's target (`Location`), because
    /// that target is what says "login".
    ///
    /// - 401 is dead. Canvas answers a signed-out API call with a 401 and a
    ///   JSON body, never a redirect, so a bare 401 on `users/self` is the
    ///   cleanest "dead" there is (and unlike a course's 401 it cannot mean
    ///   "not allowed").
    /// - A login page, however it got reached, is dead. A 200 whose final
    ///   URL is a login page is a redirect that was followed (a session
    ///   handed in by a caller that follows them).
    /// - 200 with a JSON object is alive. A 200 with HTML on a page that is
    ///   not a login page is unknown, not dead: `CanvasGradesClient` reads
    ///   any HTML as a lapsed session, which is how a Canvas error page can
    ///   pass for one, and this rule exists to stop doing that.
    /// - Everything else (403, 404, 429, 5xx, a redirect somewhere that is
    ///   not a login page) is unknown.
    static func verdict(statusCode: Int, finalURL: URL?, body: Data) -> Verdict {
        if statusCode == 401 { return .dead }
        if isLoginPage(finalURL), (200..<400).contains(statusCode) { return .dead }
        if statusCode == 200, isJSONObject(body) { return .alive }
        return .unknown
    }

    /// Whether `url` is somewhere a signed-out student gets sent to sign in.
    ///
    /// A keyword rule on purpose: the eight supported Canvases front eight
    /// different single sign-on systems (`/login/saml`, `/cas/login`, a
    /// Shibboleth `/idp/profile/SAML2/Redirect/SSO`), so no host list
    /// survives, and a redirect that is *not* recognised as a login (a
    /// vanity-domain hop, say) falls to `.unknown`, which is the safe side.
    static func isLoginPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        let path = url.path.lowercased()
        let pathTokens = ["/login", "/saml", "/sso", "/cas/", "/idp/", "/signin", "/sign_in"]
        if pathTokens.contains(where: { path.contains($0) }) { return true }
        let firstLabel = (url.host ?? "").lowercased().split(separator: ".").first.map(String.init) ?? ""
        return ["idp", "sso", "login", "cas", "weblogin", "shibidp"].contains(firstLabel)
    }

    /// True for a body that is one JSON object, once Canvas's `while(1);`
    /// anti-hijacking prefix (which some endpoints still prepend) is gone.
    static func isJSONObject(_ body: Data) -> Bool {
        let stripped = CanvasGradesClient.stripXSSIPrefix(body)
        guard !stripped.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: stripped) else { return false }
        return parsed is [String: Any]
    }

    // MARK: - The request

    /// Puts the question to `baseURL`. Never throws, never deletes, never
    /// follows a redirect: the cookies go only to `baseURL`'s own host, and a
    /// redirect to an identity provider is read from its `Location` instead
    /// of visited, so a session cookie cannot be carried off-host by a hop.
    /// `session` is injectable so a test can stub the network; the default
    /// is an ephemeral one with no cookie jar of its own.
    static func probe(
        baseURL: URL,
        cookies: [HTTPCookie],
        session: URLSession = URLSession(configuration: .ephemeral),
        timeout: TimeInterval = 15
    ) async -> Verdict {
        let url = baseURL.appendingPathComponent("api/v1/users/self")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // An explicit `Cookie` header below means the system's own cookie
        // handling must be off (docs/CANVAS_LOGIN_HARDENING.md item 2c), and
        // no bearer token: this asks about the cookie session alone.
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        CanvasAuth.apply(to: &request, cookies: cookies, accessToken: nil)

        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirectDelegate())
            guard let http = response as? HTTPURLResponse else { return .unknown }
            var finalURL = http.url
            if (300..<400).contains(http.statusCode),
               let location = http.value(forHTTPHeaderField: "Location") {
                finalURL = URL(string: location, relativeTo: url)?.absoluteURL
            }
            return verdict(statusCode: http.statusCode, finalURL: finalURL, body: data)
        } catch {
            // Offline, timed out, cancelled: no answer is not "dead".
            return .unknown
        }
    }

    /// Answers every redirect with "do not follow", so the 3xx itself comes
    /// back to `probe` with its `Location` header intact.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
