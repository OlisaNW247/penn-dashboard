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

/// Where `BackendSession` keeps its anonymous identity, as three closures so a
/// test can hand it an in-memory store, or one that refuses to answer, without
/// touching the Keychain. The live value is `BackendIdentityStore`.
struct BackendIdentityPersistence: Sendable {
    var read: @Sendable () -> KeychainRead<BackendIdentity>
    var save: @Sendable (BackendIdentity) -> Void
    var clear: @Sendable () -> Void

    static let keychain = BackendIdentityPersistence(
        read: { BackendIdentityStore.read() },
        save: { BackendIdentityStore.save($0) },
        clear: { BackendIdentityStore.clear() }
    )
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
    private let persistence: BackendIdentityPersistence

    /// `nil` until the first successful sign-up or refresh. There is
    /// deliberately no persisted access token — only the refresh token in
    /// `BackendIdentityStore` survives a relaunch; a short-lived access
    /// token that happened to still be valid across a cold launch would
    /// save exactly one network round trip at the cost of a second place a
    /// credential could leak (state restoration, a crash log of `self`).
    private var cachedToken: String?
    private var cachedTokenExpiresAt: Date?

    /// The one mint or refresh that is running, if any. Every caller that
    /// needs a token while it runs awaits it instead of starting its own.
    ///
    /// **Why an actor is not enough.** The actor serialises the synchronous
    /// stretches of `accessToken`, but every network call in it is an `await`,
    /// and an actor is re-entrant across an `await`: while the first caller is
    /// suspended inside `signUpAnonymously`, a second one enters, finds no
    /// cached token and no saved identity (the first has not saved it yet),
    /// and signs up too. Two anonymous accounts exist, the second overwrites
    /// the first in the Keychain, and the first is orphaned with whatever it
    /// already did on the server. A cold launch does exactly this: the
    /// dashboard's course-material sync and an `ask` both want a token inside
    /// the same second. The wrong fix is a lock around `accessToken` (a
    /// blocked caller would hold the actor, and an `await` cannot sit inside
    /// an `NSLock`); a task handle everyone awaits is the single-flight.
    private var inFlight: Task<String, Error>?

    /// Bumped by `forgetIdentity()`. A mint that began under an older epoch
    /// belongs to an identity that has since been thrown away, and must not
    /// save it or cache its token.
    private var epoch = 0

    init(
        configuration: BackendConfiguration,
        urlSession: URLSession = .shared,
        persistence: BackendIdentityPersistence = .keychain
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.persistence = persistence
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
    ///
    /// **One sign-in at a time** (`inFlight`). A caller that arrives while a
    /// mint or refresh is running joins it and gets the same token, or the
    /// same error; a failure clears the flight, so the next call tries again.
    /// A joiner passing `forceRefresh` is satisfied by the running flight too:
    /// whatever it returns was minted after the token that was just rejected.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let token = cachedToken,
           let expiresAt = cachedTokenExpiresAt,
           expiresAt.timeIntervalSinceNow > 60 {
            return token
        }

        if let inFlight { return try await inFlight.value }

        let startedAt = epoch
        // A `Task` made inside an actor method runs on the actor, so the body
        // below may touch actor state directly. It cannot start before this
        // method suspends at `task.value`, which is after `inFlight` is set.
        let task = Task { () throws -> String in
            defer {
                // `forgetIdentity()` may have dropped this flight already and
                // a newer one may be running; leave that one alone.
                if self.epoch == startedAt { self.inFlight = nil }
            }
            return try await self.mintOrRefresh(epoch: startedAt)
        }
        inFlight = task
        return try await task.value
    }

    /// The body of one flight: read the saved identity and refresh it, or sign
    /// up when there is none.
    private func mintOrRefresh(epoch startedAt: Int) async throws -> String {
        // A flight can be handed an epoch that is already stale: it was
        // scheduled, then `forgetIdentity()` ran before it first executed. It
        // belongs to an identity that is gone and must not read, refresh or
        // sign up on its behalf.
        guard epoch == startedAt else { throw BackendError.transport }

        // Three answers, because "no identity" means "create a new anonymous
        // account" and "the Keychain would not say" must never mean that. A
        // locked or refusing Keychain (before first unlock, a background wake
        // right after a reboot) used to read as nil here, so the very next ask
        // or sync signed up a second account while the first one's refresh
        // token was sitting unread in the Keychain, orphaning its quota and
        // its rows. On `unavailable` this call fails as the backend being
        // unreachable (`ask` then answers on-device and a sync waits for the
        // next loop) and the next call reads again, so a Keychain that comes
        // back is used. Nothing is cached about it.
        let saved: BackendIdentity
        switch persistence.read() {
        case let .found(found):
            saved = found
        case .notFound:
            return try await signUpAnonymously(epoch: startedAt)
        case .unavailable:
            throw BackendError.transport
        }

        do {
            return try await refresh(with: saved, epoch: startedAt)
        } catch BackendError.http(400), BackendError.http(401) {
            // Checked before anything below touches the Keychain. This rejection
            // may be the answer to a refresh that was in flight when the
            // identity was forgotten, and a newer identity may have been
            // minted and saved since. Clearing here would wipe that one and the
            // sign-up after it would orphan an account, so a stale flight stops
            // at its own failure.
            guard epoch == startedAt else { throw BackendError.transport }
            // The refresh token itself is no longer good — expired,
            // revoked, or the row was deleted server-side. There is no
            // partial-credit retry here: the identity is discarded outright
            // and a brand new anonymous identity takes its place, exactly
            // as `backend/PROTOCOL.md`'s anonymous-sign-in model intends
            // (there is no student-facing "log back in" to offer instead).
            persistence.clear()
            return try await signUpAnonymously(epoch: startedAt)
        }
    }

    /// Drops the in-memory token and the persisted identity. Called after a
    /// successful `delete-account` call (`BackendClient.deleteAccount()`) so
    /// the very next `ask` after that starts a brand new anonymous identity
    /// rather than one the server just told us it deleted.
    ///
    /// Also drops any flight that is still running: it was minting (or
    /// refreshing) the identity being forgotten, and when it lands it must not
    /// write that identity back (`performAuth` checks the epoch).
    func forgetIdentity() {
        epoch += 1
        inFlight = nil
        cachedToken = nil
        cachedTokenExpiresAt = nil
        persistence.clear()
    }

    // MARK: - GoTrue calls

    private func signUpAnonymously(epoch startedAt: Int) async throws -> String {
        var request = authRequest(path: "auth/v1/signup")
        // Anonymous sign-in per `backend/PROTOCOL.md`: an empty JSON object,
        // not an absent body — GoTrue's anonymous-signup endpoint requires a
        // `Content-Type: application/json` request with a parseable (if
        // empty) JSON body.
        request.httpBody = Data("{}".utf8)
        return try await performAuth(request, epoch: startedAt)
    }

    private func refresh(with identity: BackendIdentity, epoch startedAt: Int) async throws -> String {
        var request = authRequest(
            path: "auth/v1/token",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")]
        )
        request.httpBody = try? JSONEncoder().encode(RefreshRequestBody(refreshToken: identity.refreshToken))
        return try await performAuth(request, epoch: startedAt)
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
    private func performAuth(_ request: URLRequest, epoch startedAt: Int) async throws -> String {
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

        // The identity was forgotten while this request was out: the account
        // it just created or rotated is the one the student asked to delete,
        // so it is neither saved nor cached.
        guard epoch == startedAt else { throw BackendError.transport }

        persistence.save(BackendIdentity(userID: decoded.user.id, refreshToken: decoded.refreshToken))
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
