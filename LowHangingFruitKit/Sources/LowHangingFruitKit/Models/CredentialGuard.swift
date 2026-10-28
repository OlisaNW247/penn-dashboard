import Foundation

/// Where a session cookie or a bearer token is allowed to go.
///
/// **The rule.** A credential goes to the host it was issued for, over
/// HTTPS, and nowhere else, however the request got there: a URL a server put
/// in a page, a `Link` header, or a redirect. Every client that attaches a
/// `Cookie` or `Authorization` header explicitly (which they all do, with
/// `httpShouldHandleCookies = false`, because `HTTPCookieStorage` would
/// otherwise rewrite the header, `docs/CANVAS_LOGIN_HARDENING.md` item 2c)
/// has no storage to scope the cookie by domain for it. The header goes on
/// whatever request is built, and on whatever request a redirect builds from
/// it.
///
/// Two halves, both needed:
///
/// - **`CredentialOrigin.isSameOrigin`** for a URL the client is about to
///   request. Gradescope reads course and assignment links out of HTML with
///   `URL(string: href, relativeTo: baseURL)`, which leaves an absolute
///   `href` pointing wherever the page says, and the client then sent the
///   student's Gradescope cookie there.
/// - **`CredentialRedirectGuard`** for a URL the server sends the client on
///   to. A 302 from Canvas to a pre-signed file URL on a CDN is ordinary
///   (that is how file downloads work), and `URLSession` builds the second
///   request from the first, custom `Cookie` header included. It strips
///   `Authorization` across hosts on current systems and not a `Cookie` the
///   caller set by hand, and nothing here should depend on which.
///
/// The wrong fix is a guard on the first half alone: the redirect is the case
/// the client's own URL check never sees.
enum CredentialOrigin {
    /// Whether `url` is HTTPS on the same host and port as `base`. Host names
    /// compare case-insensitively; a missing port is the scheme's default.
    static func isSameOrigin(_ url: URL, as base: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              let baseHost = base.host?.lowercased()
        else { return false }
        return host == baseHost && (url.port ?? 443) == (base.port ?? 443)
    }
}

/// A per-request redirect delegate that takes credentials off a hop to
/// another origin. Passed to `URLSession.data(for:delegate:)`, so it works for
/// whichever session the caller supplied (the shared one, an ephemeral one,
/// a test's) without the client having to own the session's configuration.
///
/// Stateless, so one instance per request is free and it is trivially
/// `Sendable`.
final class CredentialRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    /// Headers that carry a credential. `Proxy-Authorization` is not ours to
    /// send, but a redirect must not be the way it leaks either.
    static let credentialHeaders = ["Cookie", "Authorization", "Proxy-Authorization"]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.sanitized(request, redirectedFrom: response.url))
    }

    /// `redirect` with its credentials removed unless it stays on the same
    /// HTTPS origin as the request that was redirected. A redirect to a
    /// different host, a different port, or a downgrade to HTTP loses them.
    /// Cookie handling is also switched off on the stripped request, so
    /// `URLSession` cannot add cookies from shared storage back.
    static func sanitized(_ redirect: URLRequest, redirectedFrom origin: URL?) -> URLRequest {
        if let origin, let target = redirect.url, CredentialOrigin.isSameOrigin(target, as: origin) {
            return redirect
        }
        var stripped = redirect
        for header in credentialHeaders {
            stripped.setValue(nil, forHTTPHeaderField: header)
        }
        stripped.httpShouldHandleCookies = false
        return stripped
    }
}

extension URLSession {
    /// `data(for:)` for a request that carries a credential: a redirect to
    /// another origin goes out without it (`CredentialRedirectGuard`).
    func credentialSafeData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: CredentialRedirectGuard())
    }
}
