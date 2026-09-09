import Foundation
import LowHangingFruitKit

/// One call to one of LHF's Supabase Edge Functions: attaches the auth
/// headers `backend/PROTOCOL.md` requires, retries exactly once on a stale
/// token, and turns every non-2xx response into a `BackendError` the caller
/// can show something sensible about instead of a raw status code or a
/// crash.
///
/// Every method here is a thin wrapper over `post(_:body:)` or
/// `askStream(_:)` — the wire shapes it encodes and decodes
/// (`SyncManifestRequest`, `AskRequest`, `ExtractAnnouncementRequest`, …)
/// live in `LowHangingFruitKit/Models/BackendWire.swift` and are the
/// authoritative contract; this file's job is only the HTTP mechanics
/// around them, never their shape.
struct BackendClient: Sendable {
    let configuration: BackendConfiguration
    let session: BackendSession
    let urlSession: URLSession

    init(configuration: BackendConfiguration, session: BackendSession, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
        self.urlSession = urlSession
    }

    // MARK: - sync

    func syncManifest(_ request: SyncManifestRequest) async throws -> SyncManifestResponse {
        try await post("sync", body: request)
    }

    func syncUpload(_ request: SyncUploadRequest) async throws -> SyncUploadResponse {
        try await post("sync", body: request)
    }

    // MARK: - extract-profile

    /// Fire-and-forget from the caller's point of view — `backend/
    /// PROTOCOL.md` has the client "POST `extract-profile` for
    /// `profileStale` without awaiting", so nothing downstream needs the
    /// `{ "updated": [courseID] }` body back. The response is still decoded
    /// (into a private, throwaway shape) rather than ignored outright, so a
    /// malformed response still surfaces as a thrown error instead of
    /// silently looking like success.
    func extractProfile(courseIDs: [String]) async throws {
        struct IgnoredResponse: Decodable {}
        let _: IgnoredResponse = try await post("extract-profile", body: ExtractProfileRequest(courseIDs: courseIDs))
    }

    // MARK: - discover-websites

    /// Same fire-and-forget shape as `extractProfile`: triggers the
    /// server's crawl of a course's linked external website and never waits
    /// on the result — a crawl can take tens of seconds, and nothing on
    /// this phone needs it to finish before the sync that kicked it off can
    /// consider itself done.
    func discoverWebsites(courseIDs: [String]) async throws {
        struct IgnoredResponse: Decodable {}
        let _: IgnoredResponse = try await post("discover-websites", body: DiscoverWebsitesRequest(courseIDs: courseIDs))
    }

    // MARK: - extract-announcement

    func extractAnnouncement(_ request: ExtractAnnouncementRequest) async throws -> ExtractAnnouncementResponse {
        try await post("extract-announcement", body: request)
    }

    // MARK: - delete-account

    /// Deletes the caller's server-side rows and auth user
    /// (`backend/PROTOCOL.md`), then forgets the identity on-device so the
    /// very next backend call starts a fresh anonymous sign-up rather than
    /// refreshing a token the server just invalidated.
    func deleteAccount() async throws {
        struct EmptyRequest: Encodable {}
        struct DeleteAccountResponse: Decodable { let deleted: Bool }
        let _: DeleteAccountResponse = try await post("delete-account", body: EmptyRequest())
        await session.forgetIdentity()
    }

    // MARK: - ask

    /// Opens the streamed `ask` response and hands back the raw byte stream
    /// once the initial HTTP status is known good — everything after that
    /// (parsing `data:` lines into `AskStreamEvent`s, splitting off the
    /// `<sources>` block) is `BackendAssistantResponder`'s job, not this
    /// client's; this method's only responsibility is the same
    /// auth-attach/401-retry/status-check dance every other call here does,
    /// applied to `bytes(for:)` instead of `data(for:)`.
    func askStream(_ request: AskRequest) async throws -> URLSession.AsyncBytes {
        let bodyData: Data
        do {
            bodyData = try BackendJSON.encoder().encode(request)
        } catch {
            throw BackendError.decoding
        }
        return try await askStream(bodyData: bodyData, forceRefresh: false)
    }

    private func askStream(bodyData: Data, forceRefresh: Bool) async throws -> URLSession.AsyncBytes {
        let accessToken = try await session.accessToken(forceRefresh: forceRefresh)
        var request = URLRequest(url: configuration.url.appendingPathComponent("functions/v1/ask"))
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await urlSession.bytes(for: request)
        } catch {
            throw BackendError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.transport }

        if http.statusCode == 401 {
            guard !forceRefresh else { throw BackendError.unauthorized }
            return try await askStream(bodyData: bodyData, forceRefresh: true)
        }
        if http.statusCode == 429 {
            throw BackendError.quotaExceeded(resetAt: await Self.resetAt(fromErrorBody: bytes))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(http.statusCode)
        }
        return bytes
    }

    /// A 429 on `ask` arrives as plain JSON, not an event stream — the same
    /// `{ "error": "quota_exceeded", "resetAt": ISO8601 }` shape `post(_:
    /// body:)` decodes from `data(for:)` directly. `bytes(for:)` never hands
    /// back that `Data` in one piece, so this drains the (small, one-shot)
    /// error body line by line to reassemble it. Best-effort only: any
    /// failure to read or parse it just means `resetAt` comes back `nil` —
    /// the caller already knows it hit a quota either way from the thrown
    /// `.quotaExceeded` case, and a missing reset date degrades to "come
    /// back later" instead of a crash or a retry loop.
    private static func resetAt(fromErrorBody bytes: URLSession.AsyncBytes) async -> Date? {
        var collected = ""
        do {
            for try await line in bytes.lines {
                collected += line
            }
        } catch {
            return nil
        }
        guard let data = collected.data(using: .utf8) else { return nil }
        return decodeResetAt(from: data)
    }

    // MARK: - Function calls

    /// The one seam every function call in this file goes through:
    /// attaches `Authorization`/`apikey`/`Content-Type`, retries exactly
    /// once with a forced token refresh on a 401 (a token that expired
    /// between `BackendSession.accessToken()` returning it and the request
    /// actually landing, or one the server revoked out from under the
    /// cache), and maps every other non-2xx status to a `BackendError`
    /// rather than letting a caller inspect raw `HTTPURLResponse`s.
    ///
    /// `body: some Encodable` rather than a second generic parameter: every
    /// call site passes a concrete wire-request struct and never needs to
    /// name its type, so the lighter-weight opaque-parameter spelling reads
    /// the same as the generic `<Body: Encodable>` it desugars to.
    private func post<T: Decodable>(_ function: String, body: some Encodable) async throws -> T {
        let bodyData: Data
        do {
            bodyData = try BackendJSON.encoder().encode(body)
        } catch {
            throw BackendError.decoding
        }
        return try await send(function: function, bodyData: bodyData, forceRefresh: false)
    }

    private func send<T: Decodable>(function: String, bodyData: Data, forceRefresh: Bool) async throws -> T {
        let accessToken = try await session.accessToken(forceRefresh: forceRefresh)
        var request = URLRequest(url: configuration.url.appendingPathComponent("functions/v1/\(function)"))
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw BackendError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.transport }

        if http.statusCode == 401 {
            guard !forceRefresh else { throw BackendError.unauthorized }
            return try await send(function: function, bodyData: bodyData, forceRefresh: true)
        }
        if http.statusCode == 429 {
            throw BackendError.quotaExceeded(resetAt: Self.decodeResetAt(from: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.http(http.statusCode)
        }
        do {
            return try BackendJSON.decoder().decode(T.self, from: data)
        } catch {
            // `BackendError.decoding` carries no detail by design (callers
            // only ever branch on the case), but a decode failure on a
            // response the server considered valid is exactly the bug a
            // device diagnostics report needs to name: the coding path and
            // debug description say WHICH field of WHICH type disagreed
            // with the wire, and never contain a value from the body. Kept
            // on the main actor as a plain slot rather than threaded
            // through the error so the wire contract stays untouched.
            let detail = "\(function): \(Self.describe(error)) (\(data.count) bytes)"
            await MainActor.run { BackendDiagnostics.lastDecodingFailure = detail }
            throw BackendError.decoding
        }
    }

    /// A one-line, value-free rendering of a `DecodingError`: the case, the
    /// coding path, and the decoder's own debug description (which names
    /// types and keys, not data). Anything else falls back to its type name.
    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: type(of: error)) }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "keyNotFound \(key.stringValue) at [\(path(context))]"
        case .typeMismatch(let type, let context):
            return "typeMismatch \(type) at [\(path(context))]: \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "valueNotFound \(type) at [\(path(context))]"
        case .dataCorrupted(let context):
            return "dataCorrupted at [\(path(context))]: \(context.debugDescription)"
        @unknown default:
            return "decodingError"
        }
    }

    /// Parses `{ "error": "quota_exceeded", "resetAt": ISO8601 }`
    /// (`backend/PROTOCOL.md`'s 429 body) for the one field this client
    /// cares about. The double-formatter fallback (fractional seconds, then
    /// plain) mirrors `ClaudeAnnouncementExtractor.parseISO8601` — the same
    /// two shapes a Postgres/Supabase timestamp can render as depending on
    /// whether it carries sub-second precision.
    private static func decodeResetAt(from data: Data) -> Date? {
        struct QuotaErrorBody: Decodable { let resetAt: String? }
        guard let body = try? JSONDecoder().decode(QuotaErrorBody.self, from: data),
              let raw = body.resetAt
        else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// Every place in the app that wants to talk to LHF's backend goes through
/// this, never through `BackendClient(...)` directly — which is what makes
/// "no backend configured" a single, obvious `nil` check at every call site
/// instead of each one re-deriving it from `BackendConfiguration.current`.
///
/// `nil` means fully on-device: no configuration was pasted into
/// `BackendConfiguration.production` yet, a `-LHFBackendURL` override wasn't
/// supplied, or this process is a test runner
/// (`SharedDefaults.isTestRunner`). That is the state every test in this
/// package runs in, and the state any build runs in before
/// `BackendConfiguration.production` is filled in — both are meant to work
/// completely normally, answering `ask` from `OnDeviceAssistantResponder`
/// and skipping sync/announcement-extraction calls to the backend entirely.
///
/// A `static let` is both thread-safe (its initializer runs exactly once,
/// the same guarantee `UserDefaults.lhf` relies on) and lazy (it only
/// resolves `BackendConfiguration.current` the first time anything asks),
/// so there's no explicit caching or "have we checked yet" flag to get
/// wrong.
enum BackendServices {
    static let client: BackendClient? = {
        guard let configuration = BackendConfiguration.current else { return nil }
        return BackendClient(configuration: configuration, session: BackendSession(configuration: configuration))
    }()
}


/// Diagnostic-only slots the backend client fills for the diagnostics
/// report. Main-actor isolated so `BackendClient` (a `Sendable` struct that
/// runs off the main actor) can write them without a lock; read only by
/// `AppState`'s diagnostics lines.
@MainActor
enum BackendDiagnostics {
    /// The most recent response the client could not decode — function
    /// name, coding path, decoder message, byte count. Never body content.
    static var lastDecodingFailure: String?
}
