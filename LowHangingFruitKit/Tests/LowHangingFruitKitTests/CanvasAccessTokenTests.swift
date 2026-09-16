import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `CanvasAccessToken`, `CanvasAccessTokenPolicy`,
/// `CanvasAccessTokenMint` and `CanvasAuth` — all pure, network-free logic,
/// same as `CanvasGradesClientTests` next to it. The construction tests at
/// the bottom exist purely to prove, at compile time, that every Canvas
/// client's `init` actually accepts `accessToken:`; they don't perform
/// network I/O and don't need to (a `Sendable` struct/class constructed and
/// discarded is enough to catch a signature mismatch, which is the only
/// failure mode those tests exist to catch).
@Suite("Canvas access token")
struct CanvasAccessTokenTests {

    // MARK: - Fixtures

    private static let reference = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15, arbitrary and fixed

    private func cookie(name: String = "canvas_session", value: String = "synthetic", domain: String = "canvas.upenn.edu") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ])!
    }

    private func envelope(status: Int, body: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["status": status, "body": body])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - CanvasAccessTokenPolicy.isUsable

    @Test("nil token is never usable")
    func isUsableNil() {
        #expect(!CanvasAccessTokenPolicy.isUsable(nil, now: Self.reference))
    }

    @Test("an empty secret is never usable, even with a future expiry")
    func isUsableEmptySecret() {
        let token = CanvasAccessToken(token: "", id: "1", tokenHint: "abcd", expiresAt: Self.reference.addingTimeInterval(86_400), createdAt: Self.reference)
        #expect(!CanvasAccessTokenPolicy.isUsable(token, now: Self.reference))
    }

    @Test("a token past its expiresAt is not usable")
    func isUsableExpired() {
        let token = CanvasAccessToken(token: "secret", id: "1", tokenHint: "abcd", expiresAt: Self.reference.addingTimeInterval(-1), createdAt: Self.reference)
        #expect(!CanvasAccessTokenPolicy.isUsable(token, now: Self.reference))
    }

    @Test("a token with a future expiresAt is usable")
    func isUsableFuture() {
        let token = CanvasAccessToken(token: "secret", id: "1", tokenHint: "abcd", expiresAt: Self.reference.addingTimeInterval(86_400), createdAt: Self.reference)
        #expect(CanvasAccessTokenPolicy.isUsable(token, now: Self.reference))
    }

    @Test("a nil expiresAt means the token never expires")
    func isUsableNilExpiry() {
        let token = CanvasAccessToken(token: "secret", id: "1", tokenHint: "abcd", expiresAt: nil, createdAt: Self.reference)
        #expect(CanvasAccessTokenPolicy.isUsable(token, now: Self.reference))
    }

    // MARK: - CanvasAccessTokenPolicy.needsMint

    @Test("no existing token always needs a mint")
    func needsMintNilExisting() {
        #expect(CanvasAccessTokenPolicy.needsMint(existing: nil, now: Self.reference))
    }

    @Test("an already-expired token needs a mint")
    func needsMintExpired() {
        let token = CanvasAccessToken(token: "secret", id: "1", tokenHint: "abcd", expiresAt: Self.reference.addingTimeInterval(-1), createdAt: Self.reference)
        #expect(CanvasAccessTokenPolicy.needsMint(existing: token, now: Self.reference))
    }

    @Test("8 days before expiry is outside the renewal window")
    func needsMintEightDaysOut() {
        let token = CanvasAccessToken(token: "secret", id: "1", tokenHint: "abcd", expiresAt: Self.reference.addingTimeInterval(8 * 86_400), createdAt: Self.reference)
        #expect(!CanvasAccessTokenPolicy.needsMint(existing: token, now: Self.reference))
    }

    @Test("6 days before expiry is inside the renewal window")
    func needsMintSixDaysOut() {
        let token = CanvasAccessToken(token: "secret", id: "1", tokenHint: "abcd", expiresAt: Self.reference.addingTimeInterval(6 * 86_400), createdAt: Self.reference)
        #expect(CanvasAccessTokenPolicy.needsMint(existing: token, now: Self.reference))
    }

    @Test("a token that never expires never needs a mint")
    func needsMintNilExpiryNeverRenews() {
        let token = CanvasAccessToken(token: "secret", id: "1", tokenHint: "abcd", expiresAt: nil, createdAt: Self.reference)
        #expect(!CanvasAccessTokenPolicy.needsMint(existing: token, now: Self.reference))
    }

    // MARK: - CanvasAccessTokenPolicy.expiry

    @Test("expiry(from:) is under Canvas's 120-day ceiling, with margin")
    func expiryUnderCeiling() {
        let expiry = CanvasAccessTokenPolicy.expiry(from: Self.reference)
        let ceiling = Self.reference.addingTimeInterval(120 * 86_400)
        #expect(expiry < ceiling)
        // The margin exists specifically to survive minor clock disagreement
        // with Canvas, not to be huge — it should still be within an hour of
        // the ceiling, not days short of it.
        #expect(ceiling.timeIntervalSince(expiry) <= 3_600)
    }

    // MARK: - CanvasAccessTokenMint.requestBody

    @Test("requestBody round-trips purpose and an expires_at ending in Z")
    func requestBodyRoundTrips() throws {
        let expiresAt = Self.reference.addingTimeInterval(120 * 86_400)
        let data = CanvasAccessTokenMint.requestBody(purpose: "Smooth for Students", expiresAt: expiresAt)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let token = try #require(json["token"] as? [String: Any])
        #expect(token["purpose"] as? String == "Smooth for Students")
        let expiresString = try #require(token["expires_at"] as? String)
        #expect(expiresString.hasSuffix("Z"))
    }

    // MARK: - CanvasAccessTokenMint.script

    @Test("script contains the token endpoint, CSRF plumbing, and an escaped purpose with no raw newline")
    func scriptContainsExpectedPieces() throws {
        // A quote and a newline in the purpose exercise escaping: if
        // `script` ever stopped JSON-escaping before splicing this into the
        // JS source, this would either break the JS string literal outright
        // or (worse, silently) leave a literal newline sitting inside a
        // single-line JS string.
        let purpose = "Say \"hi\" to\nSmooth"
        let expiresAt = Self.reference
        let script = CanvasAccessTokenMint.script(purpose: purpose, expiresAt: expiresAt)

        #expect(script.contains("/api/v1/users/self/tokens"))
        #expect(script.contains("X-CSRF-Token"))
        #expect(script.contains("_csrf_token"))

        let expectedLiteral = try #require(String(data: try JSONEncoder().encode(purpose), encoding: .utf8))
        // The JSON-encoded literal itself must contain no raw newline — that's
        // what proves escaping actually happened, rather than merely that the
        // literal (however malformed) shows up somewhere in the script.
        #expect(!expectedLiteral.contains("\n"))
        #expect(script.contains(expectedLiteral))
    }

    // MARK: - CanvasAccessTokenMint.parseScriptResult

    @Test("a 200 with a while(1); XSSI prefix and a numeric id parses")
    func parseScriptResultPrefixedNumericID() throws {
        let body = "while(1);{\"token\":\"secret-abc\",\"id\":42,\"token_hint\":\"...wxyz\",\"expires_at\":\"2027-05-01T00:00:00Z\",\"purpose\":\"Smooth for Students\"}"
        let result = CanvasAccessTokenMint.parseScriptResult(envelope(status: 200, body: body), now: Self.reference)
        let token = try #require(try? result.get())
        #expect(token.token == "secret-abc")
        #expect(token.id == "42")
        #expect(token.tokenHint == "...wxyz")
        #expect(token.expiresAt != nil)
        #expect(token.createdAt == Self.reference)
    }

    @Test("a 200 with no XSSI prefix and a string id parses")
    func parseScriptResultUnprefixedStringID() throws {
        let body = "{\"token\":\"secret-xyz\",\"id\":\"99\",\"token_hint\":\"...9999\",\"expires_at\":null,\"purpose\":\"Smooth for Students\"}"
        let result = CanvasAccessTokenMint.parseScriptResult(envelope(status: 200, body: body), now: Self.reference)
        let token = try #require(try? result.get())
        #expect(token.token == "secret-xyz")
        #expect(token.id == "99")
        #expect(token.expiresAt == nil)
    }

    @Test("a 403 with an errors array surfaces the message")
    func parseScriptResult403ErrorsArray() {
        let body = "{\"errors\":[{\"message\":\"Personal access tokens have been disabled for this account.\"}]}"
        let result = CanvasAccessTokenMint.parseScriptResult(envelope(status: 403, body: body), now: Self.reference)
        switch result {
        case .success:
            Issue.record("expected a 403 to fail")
        case let .failure(failure):
            #expect(failure == .httpStatus(403, message: "Personal access tokens have been disabled for this account."))
        }
    }

    @Test("a 400 with a per-field errors dict fails with the right status")
    func parseScriptResult400ErrorsDict() {
        let body = "{\"errors\":{\"expires_at\":[\"is too far in the future\"]}}"
        let result = CanvasAccessTokenMint.parseScriptResult(envelope(status: 400, body: body), now: Self.reference)
        switch result {
        case .success:
            Issue.record("expected a 400 to fail")
        case let .failure(failure):
            // The message text is best-effort (see `errorMessage(from:)`'s
            // doc comment) — the status code is the part callers can rely on.
            guard case let .httpStatus(status, _) = failure else {
                Issue.record("expected .httpStatus, got \(failure)")
                return
            }
            #expect(status == 400)
        }
    }

    @Test("garbage input is malformed, not a crash or a false success")
    func parseScriptResultGarbage() {
        let result = CanvasAccessTokenMint.parseScriptResult("this is not json at all", now: Self.reference)
        switch result {
        case .success:
            Issue.record("expected garbage to fail")
        case let .failure(failure):
            guard case .malformed = failure else {
                Issue.record("expected .malformed, got \(failure)")
                return
            }
        }
    }

    // MARK: - CanvasAccessTokenMint.parseResponse (the raw status+body seam)

    @Test("parseResponse strips a while(1); prefix directly, without the script envelope")
    func parseResponseDirect() throws {
        let body = Data("while(1);{\"token\":\"direct-secret\",\"id\":7,\"expires_at\":\"2027-06-01T00:00:00Z\"}".utf8)
        let result = CanvasAccessTokenMint.parseResponse(status: 200, body: body, now: Self.reference)
        let token = try #require(try? result.get())
        #expect(token.token == "direct-secret")
        #expect(token.id == "7")
    }

    // MARK: - CanvasAuth.apply

    @Test("a non-empty accessToken sets Bearer and no Cookie header")
    func applyWithToken() {
        var request = URLRequest(url: URL(string: "https://canvas.upenn.edu/api/v1/courses/1")!)
        CanvasAuth.apply(to: &request, cookies: [cookie()], accessToken: "the-token")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer the-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(CanvasAuth.isBearer(request))
    }

    @Test("a nil accessToken falls back to the cookie header, with no Authorization header")
    func applyWithNilToken() {
        var request = URLRequest(url: URL(string: "https://canvas.upenn.edu/api/v1/courses/1")!)
        CanvasAuth.apply(to: &request, cookies: [cookie(name: "canvas_session", value: "synthetic-cookie")], accessToken: nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-cookie") == true)
        #expect(!CanvasAuth.isBearer(request))
    }

    @Test("an empty-string accessToken is treated the same as no token")
    func applyWithEmptyToken() {
        var request = URLRequest(url: URL(string: "https://canvas.upenn.edu/api/v1/courses/1")!)
        CanvasAuth.apply(to: &request, cookies: [cookie(name: "canvas_session", value: "synthetic-cookie")], accessToken: "")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-cookie") == true)
    }

    // MARK: - Every Canvas client accepts accessToken: (compile-level proof only)

    @Test("CanvasGradesClient can be constructed with accessToken")
    func constructsCanvasGradesClient() {
        _ = CanvasGradesClient(cookies: [], accessToken: "test-token")
    }

    @Test("CanvasAnnouncementsClient can be constructed with accessToken")
    func constructsCanvasAnnouncementsClient() {
        _ = CanvasAnnouncementsClient(cookies: [], accessToken: "test-token")
    }

    @Test("CanvasModulesClient can be constructed with accessToken")
    func constructsCanvasModulesClient() {
        _ = CanvasModulesClient(cookies: [], accessToken: "test-token")
    }

    @Test("CanvasCourseContentClient can be constructed with accessToken")
    func constructsCanvasCourseContentClient() {
        _ = CanvasCourseContentClient(cookies: [], accessToken: "test-token")
    }

    @Test("CanvasSyllabusClient can be constructed with accessToken")
    func constructsCanvasSyllabusClient() {
        _ = CanvasSyllabusClient(cookies: [], accessToken: "test-token")
    }

    // `CanvasDiscoveryClient` deliberately has no `accessToken:` parameter —
    // see its doc comment: it scrapes the Canvas web UI, which never honors
    // a bearer token, so there's nothing to test-construct here.
}
