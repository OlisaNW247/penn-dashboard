import Foundation

// MARK: – Errors
//
// Shared by every type in this file's neighborhood (`BackendClient`,
// `BackendAssistantResponder`) rather than nested inside one of them,
// because both the auth layer here and the request layer in
// `BackendClient.swift` throw it. `Equatable` so tests can assert on it
// directly, `Sendable` because a `BackendClient` call site awaits it across
// actor and task boundaries without a second thought. The status/date it
// carries are the most a caller should ever need to decide what to tell the
// student — never a URL, never a response body, never a token, for the same
// reason `ClaudeAssistantResponder.ResponderError` (its predecessor) never
// carried more than a status code.
enum BackendError: Error, Sendable, Equatable {
    /// `BackendConfiguration.current` was `nil` when something tried to
    /// reach the backend anyway. In practice nothing in this Kit constructs
    /// a `BackendSession`/`BackendClient` without a configuration in hand
    /// (`BackendServices.client` is `nil` instead), so this case exists for
    /// completeness of the switch in `BackendAssistantResponder
    /// .friendlyMessage(for:)` rather than because any code path here
    /// throws it today.
    case notConfigured
    /// A function call came back 401 even after one forced token refresh —
    /// distinct from the generic `.http(401)` a first, un-retried failure
    /// would be, because by this point retrying again cannot help.
    case unauthorized
    case http(Int)
    case quotaExceeded(resetAt: Date?)
    case transport
    case decoding
}

/// A plain, neutral description for contexts outside `ask`'s own transcript
/// — `AppState.deleteBackendData()` surfaces a failed `deleteAccount()` call
/// through `error.localizedDescription` in a settings notice, which without
/// this conformance would fall back to Swift's generic "The operation
/// couldn't be completed" text instead of naming what actually went wrong.
/// Deliberately separate from `BackendAssistantResponder.friendlyMessage
/// (for:)`, which is phrased for the middle of an answer ("answering from
/// your phone instead") and would read strangely stitched into an unrelated
/// settings alert.
extension BackendError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "no server is configured."
        case .unauthorized:
            return "couldn't verify your session with the server."
        case let .http(status):
            return "the server returned an error (\(status))."
        case .quotaExceeded:
            return "you've hit today's question limit."
        case .transport:
            return "couldn't reach the server."
        case .decoding:
            return "got an unexpected response from the server."
        }
    }
}

/// Holds the access token that authenticates every call to LHF's own
/// backend, and knows how to get a new one. See `backend/PROTOCOL.md`'s
/// "Auth (Supabase GoTrue)" section — this type is the client-side half of
/// that contract, nothing more: it does not decide *when* a call happens,
/// only how to attach a valid `Authorization: Bearer` to one.
///
/// An `actor`, not a plain struct, because the cached token and its expiry
/// are mutable state read and written from whatever concurrent call sites
/// end up racing to refresh it (two `ask` requests fired close together
/// should not both trigger a network round trip to GoTrue); actor isolation
/// makes that a non-issue instead of a bug to reason about by hand.
actor BackendSession {
    private let configuration: BackendConfiguration
    private let urlSession: URLSession

    /// `nil` until the first successful sign-up or refresh. There is
    /// deliberately no persisted access token — only the refresh token in
    /// `BackendIdentityStore` survives a relaunch; a short-lived access
    /// token that happened to still be valid across a cold launch would
    /// save exactly one network round trip at the cost of a second place a
    /// credential could leak (state restoration, a crash log of `self`).
    private var cachedToken: String?
    private var cachedTokenExpiresAt: Date?

    init(configuration: BackendConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    /// A usable access token: the cached one if it still has more than a
    /// minute of life left, otherwise a freshly minted one.
    ///
    /// The 60-second margin is what keeps a token from expiring *in transit*
    /// — between this method returning it and the caller's request actually
    /// reaching the server, which for a "valid for one more second" token
    /// would otherwise be a real, if rare, race. `forceRefresh` exists for
    /// `BackendClient`'s 401-retry path: a token that this method believed
    /// was still good but the server has already revoked (identity deleted
    /// server-side, a manual token rotation) needs to bypass the cache
    /// entirely rather than hand back the same stale token a second time.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let token = cachedToken,
           let expiresAt = cachedTokenExpiresAt,
           expiresAt.timeIntervalSinceNow > 60 {
            return token
        }

        guard let identity = BackendIdentityStore.load() else {
            return try await signUpAnonymously()
        }

        do {
            return try await refresh(with: identity)
        } catch BackendError.http(400), BackendError.http(401) {
            // The refresh token itself is no longer good — expired,
            // revoked, or the row was deleted server-side. There is no
            // partial-credit retry here: the identity is discarded outright
            // and a brand new anonymous identity takes its place, exactly
            // as `backend/PROTOCOL.md`'s anonymous-sign-in model intends
            // (there is no student-facing "log back in" to offer instead).
            BackendIdentityStore.clear()
            return try await signUpAnonymously()
        }
    }

    /// Drops the in-memory token and the persisted identity. Called after a
    /// successful `delete-account` call (`BackendClient.deleteAccount()`) so
    /// the very next `ask` after that starts a brand new anonymous identity
    /// rather than one the server just told us it deleted.
    func forgetIdentity() {
        cachedToken = nil
        cachedTokenExpiresAt = nil
        BackendIdentityStore.clear()
    }

    // MARK: - GoTrue calls

    private func signUpAnonymously() async throws -> String {
        var request = authRequest(path: "auth/v1/signup")
        // Anonymous sign-in per `backend/PROTOCOL.md`: an empty JSON object,
        // not an absent body — GoTrue's anonymous-signup endpoint requires a
        // `Content-Type: application/json` request with a parseable (if
        // empty) JSON body.
        request.httpBody = Data("{}".utf8)
        return try await performAuth(request)
    }

    private func refresh(with identity: BackendIdentity) async throws -> String {
        var request = authRequest(
            path: "auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")]
        )
        request.httpBody = try? JSONEncoder().encode(RefreshRequestBody(refreshToken: identity.refreshToken))
        return try await performAuth(request)
    }

    private func authRequest(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: configuration.url.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Shared tail of both GoTrue calls: send, check status, decode, and —
    /// on success — persist the rotated refresh token and cache the new
    /// access token before returning it. Anthropic's key never appears in
    /// this file at all, but the discipline is the same one
    /// `ClaudeAssistantResponder`'s header insisted on for its own
    /// credential: nothing here ever logs `request`, `data`, or the decoded
    /// tokens, on success or failure.
    private func performAuth(_ request: URLRequest) async throws -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw BackendError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.transport }
        guard (200..<300).contains(http.statusCode) else { throw BackendError.http(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(GoTrueResponse.self, from: data) else {
            throw BackendError.decoding
        }

        BackendIdentityStore.save(BackendIdentity(userID: decoded.user.id, refreshToken: decoded.refreshToken))
        cachedToken = decoded.accessToken
        cachedTokenExpiresAt = Date().addingTimeInterval(decoded.expiresIn)
        return decoded.accessToken
    }
}

// MARK: - GoTrue wire shapes
//
// Hand-written, mirroring `backend/PROTOCOL.md`'s "Auth" section exactly,
// for the same reason every other request/response shape in this Kit is
// hand-written rather than built from `[String: Any]`: a typo in a
// dictionary key is a runtime bug against a live server, a typo here is a
// compile error.

private struct RefreshRequestBody: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

/// Both `/auth/v1/signup` and `/auth/v1/token?grant_type=refresh_token`
/// return this same shape (`backend/PROTOCOL.md`), so one type decodes
/// either response. Only the fields `performAuth` actually reads are
/// modeled — `token_type` and `expires_at` are real fields on the response
/// but nothing downstream needs them, `expires_in` (seconds from now) being
/// sufficient to compute the same expiry `expires_at` would have given.
private struct GoTrueResponse: Decodable {
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String
    let user: User

    struct User: Decodable {
        let id: String
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case user
    }
}
