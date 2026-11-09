import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree Works tokens")
struct DegreeWorksTokensTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func jwt(_ payload: String) -> String {
        "\(b64url(#"{"alg":"none"}"#)).\(b64url(payload)).sig"
    }

    private func cookie(_ name: String, _ value: String, domain: String = "degreeworks.example.invalid") -> HTTPCookie? {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/"])
    }

    @Test("subject and expiry read from the payload, with exp as a number or a numeric string")
    func claims() {
        let number = jwt(#"{"sub":"S0001","exp":1800003600}"#)
        #expect(JWTClaims.subject(number) == "S0001")
        #expect(JWTClaims.expiry(number) == Date(timeIntervalSince1970: 1_800_003_600))
        let string = jwt(#"{"sub":"S0002","exp":"1800003600"}"#)
        #expect(JWTClaims.expiry(string) == Date(timeIntervalSince1970: 1_800_003_600))
        #expect(JWTClaims.payload(number)?["sub"] as? String == "S0001")
    }

    @Test("payloads that need base64 padding, and garbage, are handled")
    func padding() {
        // A 1-char and a 2-char remainder both occur across these lengths.
        for sub in ["a", "ab", "abc", "abcd", "abcde"] {
            #expect(JWTClaims.subject(jwt(#"{"sub":"\#(sub)"}"#)) == sub)
        }
        #expect(JWTClaims.payload("not-a-jwt") == nil)
        #expect(JWTClaims.payload("a.!!!.c") == nil)
        #expect(JWTClaims.subject("a.b") == nil)
        #expect(JWTClaims.expiry(jwt(#"{"sub":"x"}"#)) == nil)
    }

    @Test("usable with more than a minute left, or with no exp at all")
    func usable() {
        let fresh = DegreeWorksTokens(authToken: jwt(#"{"sub":"s","exp":1800003600}"#), refreshToken: nil)
        #expect(fresh.isUsable(now: Self.now))
        let nearly = DegreeWorksTokens(authToken: jwt(#"{"sub":"s","exp":1800000030}"#), refreshToken: nil)
        #expect(!nearly.isUsable(now: Self.now))
        let expired = DegreeWorksTokens(authToken: jwt(#"{"sub":"s","exp":1700000000}"#), refreshToken: nil)
        #expect(!expired.isUsable(now: Self.now))
        let noExp = DegreeWorksTokens(authToken: jwt(#"{"sub":"s"}"#), refreshToken: nil)
        #expect(noExp.isUsable(now: Self.now))
        #expect(fresh.studentID == "s")
    }

    @Test("from(cookies:) picks exact names on any domain; the auth cookie is required")
    func pickUp() throws {
        let cookies = [
            cookie("OTHER", "x"),
            cookie("X-AUTH-TOKEN-OLD", "wrong"),
            cookie("X-AUTH-TOKEN", "first", domain: "a.example.invalid"),
            cookie("X-AUTH-TOKEN", "second", domain: "b.example.invalid"),
            cookie("REFRESH_TOKEN", "refresh"),
        ].compactMap { $0 }
        let tokens = try #require(DegreeWorksTokens.from(cookies: cookies))
        #expect(tokens.authToken == "first")
        #expect(tokens.refreshToken == "refresh")
        #expect(tokens.cookieHeader == "X-AUTH-TOKEN=first; REFRESH_TOKEN=refresh")
        #expect(DegreeWorksTokens.from(cookies: [cookie("REFRESH_TOKEN", "r")].compactMap { $0 }) == nil)
        let authOnly = try #require(DegreeWorksTokens.from(cookies: [cookie("X-AUTH-TOKEN", "t")].compactMap { $0 }))
        #expect(authOnly.refreshToken == nil)
        #expect(authOnly.cookieHeader == "X-AUTH-TOKEN=t")
    }

    @Test("a Bearer prefix is stripped from either cookie")
    func bearer() throws {
        let cookies = [cookie("X-AUTH-TOKEN", "Bearer+abc"), cookie("REFRESH_TOKEN", "Bearer rst")].compactMap { $0 }
        let tokens = try #require(DegreeWorksTokens.from(cookies: cookies))
        #expect(tokens.authToken == "abc")
        #expect(tokens.refreshToken == "rst")
    }

    @Test("description is redacted")
    func redacted() {
        let tokens = DegreeWorksTokens(authToken: "SECRET-AUTH", refreshToken: "SECRET-REFRESH")
        #expect(tokens.description == "DegreeWorksTokens(auth: present, refresh: present)")
        #expect(!"\(tokens)".contains("SECRET"))
        #expect(DegreeWorksTokens(authToken: "a", refreshToken: nil).description == "DegreeWorksTokens(auth: present, refresh: absent)")
    }
}
