import Foundation

/// A Canvas personal access token, minted on the student's own behalf, and
/// the pure logic around it: when one is still usable, when it's due for
/// renewal, and how to ask Canvas for a new one.
///
/// Why this exists at all: every Canvas client in this Kit authenticates
/// with the session cookie `SessionCookieStore` captures during login, and a
/// Canvas session is short-lived (on the order of a day) — which is why
/// `CanvasSessionRenewer` and the sliding-session cookie-rotation plumbing on
/// every client (`refreshedCookieHandler`) exist at all: something has to
/// keep re-proving the student is still logged in. A personal access token
/// sidesteps that entirely. Canvas will hand a student up to 120 days on one
/// (`tokens_controller.rb`'s `MAXIMUM_EXPIRATION_DURATION`), created the same
/// way any third-party Canvas integration is approved: a POST from inside an
/// authenticated Canvas session, visible to the student afterward under
/// Canvas → Settings → Approved Integrations. Once minted, `Authorization:
/// Bearer <token>` replaces the whole cookie dance for every REST call this
/// Kit makes, for months at a time instead of about a day.
///
/// This is additive, not a replacement: `CanvasAuth.apply` below only sends
/// `Bearer` when a token is actually available, and every client keeps
/// working exactly as before — cookies only — when it isn't. A student who
/// never reaches whatever UI flow ends up minting a token (that flow is out
/// of scope for this change; this file only supplies the pieces it would
/// need) is unaffected.
public struct CanvasAccessToken: Codable, Equatable, Sendable {
    /// The bearer secret itself. Canvas returns this exactly once, at
    /// creation — a later `GET .../tokens` listing would show `token_hint`
    /// only — so callers must persist it (Keychain, alongside the session
    /// cookies it's meant to replace; never `UserDefaults`, per this Kit's
    /// storage-tier rule) the moment `CanvasAccessTokenMint` produces one.
    public let token: String
    /// Canvas's own numeric id for this token (stringified — see
    /// `CanvasAccessTokenMint.parseResponse`'s handling of `id`), used only
    /// if a caller ever needs to `DELETE .../tokens/:id` it. Optional because
    /// a malformed-but-still-successful response is not this type's problem
    /// to invent a value for.
    public let id: String?
    /// Canvas's `token_hint` — the last few characters, safe to show the
    /// student ("...a1b2") without echoing the secret back.
    public let tokenHint: String?
    /// When Canvas will stop honoring this token. `nil` is a real, if
    /// unusual, answer (Canvas allows a null expiration for some account
    /// types) and `isUsable` treats it as "never expires" rather than as
    /// missing data.
    public let expiresAt: Date?
    /// When this value was constructed on-device — not something Canvas
    /// sends. Kept so a caller can tell how stale a cached token's own
    /// bookkeeping is without a second clock read at the call site.
    public let createdAt: Date

    public init(token: String, id: String?, tokenHint: String?, expiresAt: Date?, createdAt: Date) {
        self.token = token
        self.id = id
        self.tokenHint = tokenHint
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

/// The lifetime/renewal rules around a `CanvasAccessToken`, kept as pure
/// functions of `(token, now)` so they're trivially testable and so nothing
/// here has to reach for a clock itself — every caller already has a `Date`
/// on hand (or `Date()` at the one real call site) and passing it in is
/// exactly the pattern `GradeCountPredictor` and the update gate use to stay
/// deterministic under test.
public enum CanvasAccessTokenPolicy {
    /// 120 days is Canvas's own ceiling (`MAXIMUM_EXPIRATION_DURATION` in
    /// `tokens_controller.rb`) for a student-only account; asking for exactly
    /// that risks a token minted a few seconds before the request reaches
    /// Canvas reading as *just* over the line if the two clocks disagree even
    /// slightly, so this asks for an hour less. The hour costs nothing — the
    /// renewal window below fires a full week before expiry regardless — and
    /// buys margin against a rejection that would otherwise look like a
    /// transient Canvas failure.
    public static let lifetime: TimeInterval = 120 * 86_400 - 3_600
    /// How long before a token's own expiry this Kit starts trying to mint a
    /// replacement. A week gives several days of retries if Canvas or the
    /// network is uncooperative before the old token actually lapses.
    public static let renewalWindow: TimeInterval = 7 * 86_400
    /// What Canvas shows the student under Settings → Approved Integrations
    /// for this token — the only place a student ever sees this string, so
    /// it names the app the way the student knows it, not a bundle id or an
    /// internal module name.
    public static let purpose = "Smooth for Students"

    /// A token is usable if it has a non-empty secret and either never
    /// expires or hasn't yet. `nil` (no token at all) is never usable.
    public static func isUsable(_ token: CanvasAccessToken?, now: Date) -> Bool {
        guard let token, !token.token.isEmpty else { return false }
        guard let expiresAt = token.expiresAt else { return true }
        return expiresAt > now
    }

    /// True when there's nothing usable to fall back on, or what exists is
    /// usable today but will stop being within `renewalWindow` — the signal
    /// a caller uses to mint a replacement *before* the old one lapses,
    /// rather than reactively after a request starts failing with 401.
    public static func needsMint(existing: CanvasAccessToken?, now: Date) -> Bool {
        guard let existing, isUsable(existing, now: now) else { return true }
        guard let expiresAt = existing.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= renewalWindow
    }

    /// The `expires_at` value to send Canvas when minting from `now`.
    public static func expiry(from now: Date) -> Date {
        now.addingTimeInterval(lifetime)
    }
}

/// Builds the request to mint a Canvas personal access token, and parses
/// whatever comes back — both for a hypothetical direct `URLSession` POST
/// (`parseResponse`) and for the more realistic path, running inside the
/// student's own authenticated login `WKWebView` via
/// `WKWebView.callAsyncJavaScript` (`script`, `parseScriptResult`).
///
/// The WebView path exists because `POST /api/v1/users/self/tokens` is a
/// *session*-authenticated endpoint guarded by Canvas's own CSRF token,
/// which only a page Canvas itself served can read out of `document.cookie`
/// and attach as `X-CSRF-Token` — a bare `URLSession` request carrying just
/// the session cookie would be missing that header and get a CSRF rejection.
/// Running the mint as JavaScript inside the login WebView, right after a
/// real login, sidesteps needing to reimplement Canvas's CSRF handshake on
/// the native side. `parseResponse` is kept anyway (as the shared tail of
/// `parseScriptResult`) because the wire shape is identical either way and a
/// direct POST is exactly what a future non-WebView mint path would want to
/// reuse.
public enum CanvasAccessTokenMint {
    /// Canvas answered, but declined. `.httpStatus` carries whatever message
    /// text could be pulled out of the `errors` body — Penn's Canvas instance
    /// is known to answer 403 for at least some student accounts (Canvas
    /// tokens are an instance-level policy toggle), and 400 is Canvas's
    /// validation response (a bad `purpose`, an `expires_at` past the
    /// 120-day ceiling). `.malformed` means the response wasn't recognizable
    /// as a Canvas tokens-endpoint reply at all — garbage body, missing
    /// envelope, a 2xx with no `token` field — and callers should treat it
    /// the same way a decoding failure elsewhere in this Kit is treated: as
    /// "couldn't tell", not as Canvas's answer.
    public enum Failure: Error, Equatable {
        case httpStatus(Int, message: String?)
        case malformed(String)
    }

    /// `yyyy-MM-dd'T'HH:mm:ss'Z'` UTC — `ISO8601DateFormatter` with
    /// `.withInternetDateTime` and no fractional-seconds option emits exactly
    /// this shape, which is what `tokens_controller.rb` expects for
    /// `expires_at` on the way in. (Parsing back out, both this file's
    /// `parseISO8601` and every other ISO-8601 reader in this Kit tolerate
    /// fractional seconds too, since what Canvas sends back is not
    /// guaranteed to match what it accepts.)
    private static func expiresAtWireString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The JSON body for `POST /api/v1/users/self/tokens`:
    /// `{"token":{"purpose":"…","expires_at":"…Z"}}`. Built with
    /// `JSONSerialization` rather than `Codable` — this is two fields with no
    /// reuse anywhere else, and a bespoke `Encodable` type would be more
    /// ceremony than the one call site here warrants.
    public static func requestBody(purpose: String, expiresAt: Date) -> Data {
        let payload: [String: Any] = [
            "token": [
                "purpose": purpose,
                "expires_at": expiresAtWireString(expiresAt),
            ],
        ]
        // `JSONSerialization.data` only throws for payloads containing a
        // non-JSON-representable value (NaN, a non-string dictionary key,
        // etc.), which this literal can never be — the force-unwrap-free
        // fallback is still an empty object rather than a crash, in case
        // that ever stops being true.
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    /// Encodes `string` as a JSON string literal (quotes included) so it can
    /// be spliced directly into the JavaScript source below as a string
    /// literal. JSON string escaping is a strict subset of what a
    /// single/double-quoted JS string literal accepts, so the result is safe
    /// JavaScript as well as valid JSON — this is what keeps an
    /// attacker-influenced or merely unlucky `purpose` (a quote, a newline, a
    /// backslash) from breaking out of the literal and injecting script,
    /// without hand-rolling JS-escaping rules that are easy to get subtly
    /// wrong.
    private static func jsonStringLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string), let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    /// JavaScript to run inside the student's own logged-in Canvas WebView
    /// via `WKWebView.callAsyncJavaScript(_:arguments:in:contentWorld:completionHandler:)`,
    /// which treats the string as the *body* of an implicit async function —
    /// so this is a sequence of statements ending in a `return`, not a
    /// standalone expression or an IIFE (an IIFE's own return value is
    /// discarded unless the call itself is returned).
    ///
    /// Deliberately takes no `arguments:` dictionary — `purpose` and
    /// `expiresAt` are baked into the script text as JSON-escaped literals
    /// instead — because `callAsyncJavaScript`'s `arguments:` values must
    /// round-trip through WebKit's JSON bridge already, so embedding them as
    /// literals costs nothing and keeps this function's signature (and its
    /// tests) about the string it produces rather than about argument
    /// marshalling.
    ///
    /// Never throws on a non-2xx Canvas response: `fetch` only rejects the
    /// promise for a network-level failure, not for an HTTP error status, so
    /// a 400 or 403 flows through the same `.then` as a 200 and comes back as
    /// data (`{"status":403,"body":"..."}`) for `parseScriptResult` to read,
    /// rather than as a JS exception `callAsyncJavaScript` would have to
    /// surface as an `Error` with no Canvas detail in it at all.
    public static func script(purpose: String, expiresAt: Date) -> String {
        let purposeLiteral = jsonStringLiteral(purpose)
        let expiresAtLiteral = jsonStringLiteral(expiresAtWireString(expiresAt))
        return """
        function lhfReadCookie(name) {
          var match = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
          return match ? decodeURIComponent(match[1]) : null;
        }
        var lhfCsrfToken = lhfReadCookie('_csrf_token') || '';
        var lhfBody = JSON.stringify({ token: { purpose: \(purposeLiteral), expires_at: \(expiresAtLiteral) } });
        return fetch('/api/v1/users/self/tokens', {
          method: 'POST',
          credentials: 'same-origin',
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'X-CSRF-Token': lhfCsrfToken
          },
          body: lhfBody
        }).then(function(response) {
          return response.text().then(function(text) {
            return JSON.stringify({ status: response.status, body: text });
          });
        });
        """
    }

    /// Parses what `script(purpose:expiresAt:)`'s promise resolves to: the
    /// `{"status":<int>,"body":<string>}` envelope `callAsyncJavaScript`
    /// hands back as a Swift `String` (it bridges a JS string result
    /// directly), then hands the inner Canvas body to `parseResponse`. Any
    /// shape other than that envelope — including a plain garbage string —
    /// is `.malformed`, since at that point nothing is known about what
    /// Canvas actually said.
    public static func parseScriptResult(_ envelope: String, now: Date) -> Result<CanvasAccessToken, Failure> {
        guard
            let envelopeData = envelope.data(using: .utf8),
            let outer = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
            let status = outer["status"] as? Int,
            let body = outer["body"] as? String,
            let bodyData = body.data(using: .utf8)
        else {
            return .failure(.malformed("script result was not the expected {status, body} envelope"))
        }
        return parseResponse(status: status, body: bodyData, now: now)
    }

    /// Parses a raw Canvas response (status + body) into a token or a
    /// `Failure` — the shared tail of `parseScriptResult`, and the seam a
    /// future direct-`URLSession` mint path would call too. Strips a leading
    /// `while(1);` XSSI prefix if present (Canvas adds it to
    /// session-authenticated JSON responses, which this always is — the mint
    /// only ever runs inside a session-authenticated WebView — so the prefix
    /// is expected here, not merely tolerated as it is for the
    /// token-authenticated clients elsewhere in this Kit).
    public static func parseResponse(status: Int, body: Data, now: Date) -> Result<CanvasAccessToken, Failure> {
        let stripped = CanvasGradesClient.stripXSSIPrefix(body)
        guard let json = try? JSONSerialization.jsonObject(with: stripped) as? [String: Any] else {
            return .failure(.malformed("Canvas response body was not a JSON object"))
        }
        guard (200..<300).contains(status) else {
            return .failure(.httpStatus(status, message: errorMessage(from: json)))
        }
        guard let token = json["token"] as? String, !token.isEmpty else {
            return .failure(.malformed("2xx response had no usable \"token\" field"))
        }
        return .success(CanvasAccessToken(
            token: token,
            id: stringifiedID(json["id"]),
            tokenHint: json["token_hint"] as? String,
            expiresAt: (json["expires_at"] as? String).flatMap(parseISO8601),
            createdAt: now
        ))
    }

    /// Canvas's `id` is a JSON number on every response seen so far, but this
    /// tolerates a string too — the same defensiveness `FlexibleID` applies
    /// elsewhere in this Kit for ids that occasionally arrive as strings on
    /// some Canvas instances.
    private static func stringifiedID(_ raw: Any?) -> String? {
        if let intValue = raw as? Int { return String(intValue) }
        if let stringValue = raw as? String { return stringValue }
        if let numberValue = raw as? NSNumber { return numberValue.stringValue }
        return nil
    }

    /// Canvas's `errors` shape differs by failure kind: a flat array of
    /// `{"message": "…"}` objects (seen on a 403 policy rejection) or a
    /// per-field dictionary of message arrays (seen on a 400 validation
    /// failure, e.g. `{"expires_at":["is too far in the future"]}`). Either
    /// way this is best-effort surfacing for a log line or an error banner,
    /// not something any caller branches on — `nil` (message not found) is a
    /// normal outcome and `Failure.httpStatus`'s status code is always the
    /// authoritative half of the pair.
    private static func errorMessage(from json: [String: Any]) -> String? {
        guard let errors = json["errors"] else { return nil }
        if let array = errors as? [[String: Any]] {
            for entry in array {
                if let message = entry["message"] as? String { return message }
            }
            return nil
        }
        if let dict = errors as? [String: Any] {
            for (field, value) in dict {
                if let strings = value as? [String], let first = strings.first {
                    return "\(field): \(first)"
                }
                if let string = value as? String {
                    return "\(field): \(string)"
                }
            }
            return nil
        }
        return errors as? String
    }

    /// Same tolerant-of-fractional-seconds ISO-8601 parse every other Canvas
    /// client in this Kit does for a date that arrives as a string (see
    /// `CanvasGradesClient.parseDate`) — built locally rather than cached,
    /// since `ISO8601DateFormatter` isn't `Sendable`.
    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// Attaches whichever credential a Canvas request should carry, in exactly
/// one of two mutually exclusive forms — never both, and never a caller
/// choosing between the two branches by hand.
///
/// This is a static function taking `cookies` and `accessToken` as plain
/// parameters, not a singleton or a process-wide "current credential"
/// provider that every client would reach out to independently. That shape
/// was considered and rejected: this repo already has two known,
/// pre-existing test flakes (`CourseContentDashboardTests` racing another
/// suite over shared `UserDefaults`, `SessionCookieStoreTests` racing
/// something process-wide over the Keychain — see CLAUDE.md's "Two known
/// flakes") and both have the identical shape of hidden shared state read
/// from more than one place at once. A global token provider would be a
/// third instance of exactly that bug pattern, and every client already
/// takes `cookies` as an explicit constructor parameter for the same reason
/// — so `accessToken` is threaded the same way, and `CanvasAuth.apply` stays
/// a pure function of its arguments with nothing to race.
public enum CanvasAuth {
    /// When `accessToken` is present and non-empty, sets `Authorization:
    /// Bearer <token>` and attaches no `Cookie` header at all — a request
    /// should never carry both a bearer token and a session cookie, since a
    /// token-authenticated request has no session to speak of and Canvas
    /// would have no reason to see one. Otherwise falls back to exactly what
    /// every client did before this file existed: the cookie header loop
    /// via `HTTPCookie.requestHeaderFields(with:)`.
    public static func apply(to request: inout URLRequest, cookies: [HTTPCookie], accessToken: String?) {
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            return
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    /// Whether `request` is carrying a bearer token rather than (or as well
    /// as — this only checks for the header's presence) cookies. Exposed for
    /// tests and for any future diagnostics surface that wants to say which
    /// credential kind a request used, the way `via=fragment` does for
    /// assignment-id sourcing elsewhere in this Kit.
    public static func isBearer(_ request: URLRequest) -> Bool {
        (request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer ")
    }
}
