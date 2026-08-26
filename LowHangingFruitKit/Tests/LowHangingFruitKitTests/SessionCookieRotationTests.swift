import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Pins down the sliding-session cookie-rotation fix: Canvas re-mints the
/// session cookie on every authenticated response, and the explicit-Cookie-
/// header fetch style (docs/CANVAS_LOGIN_HARDENING.md item 2c) means
/// URLSession discards those renewals unless the app captures and persists
/// them itself.
///
/// Both halves tested here are pure/no-I/O by design, exactly like
/// `CanvasGradesClient.decodeSnapshot` and `SessionCookieStoreTests`'
/// existing style note: `CanvasGradesClient.responseCookies(from:requestURL:)`
/// never touches the network, and `SessionCookieStore.merged(existing:fresh:)`
/// never touches the Keychain — so unlike the rest of `SessionCookieStoreTests`
/// this suite doesn't need `.serialized` or Keychain clear/restore hygiene.
@Suite("Session cookie rotation")
struct SessionCookieRotationTests {

    // MARK: - SessionCookieStore.merged(existing:fresh:) — pure merge logic

    private func cookie(name: String, value: String, domain: String, path: String = "/", expiresDate: Date? = nil) -> HTTPCookie {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if let expiresDate { props[.expires] = expiresDate }
        return HTTPCookie(properties: props)!
    }

    @Test("An incoming cookie replaces a stored cookie with the same (name, domain, path)")
    func replacesByKey() {
        let existing = [cookie(name: "canvas_session", value: "synthetic-old", domain: "canvas.upenn.edu")]
        let fresh = [cookie(name: "canvas_session", value: "synthetic-rotated-1", domain: "canvas.upenn.edu")]

        let merged = SessionCookieStore.merged(existing: existing, fresh: fresh)

        #expect(merged.count == 1)
        #expect(merged.first?.value == "synthetic-rotated-1")
    }

    @Test("Unrelated cookies are preserved across a merge")
    func unrelatedCookiesPreserved() {
        let existing = [
            cookie(name: "canvas_session", value: "synthetic-old", domain: "canvas.upenn.edu"),
            cookie(name: "_csrf_token", value: "synthetic-csrf", domain: "canvas.upenn.edu"),
        ]
        let fresh = [cookie(name: "canvas_session", value: "synthetic-rotated-1", domain: "canvas.upenn.edu")]

        let merged = SessionCookieStore.merged(existing: existing, fresh: fresh)

        #expect(merged.count == 2)
        #expect(merged.contains { $0.name == "_csrf_token" && $0.value == "synthetic-csrf" })
        #expect(merged.contains { $0.name == "canvas_session" && $0.value == "synthetic-rotated-1" })
    }

    @Test("An incoming cookie with a past expiresDate drops the stored cookie instead of replacing it")
    func pastExpiryIncomingCookieDrops() {
        let existing = [cookie(name: "canvas_session", value: "synthetic-old", domain: "canvas.upenn.edu")]
        let past = Date().addingTimeInterval(-3600)
        let fresh = [cookie(name: "canvas_session", value: "synthetic-deleted", domain: "canvas.upenn.edu", expiresDate: past)]

        let merged = SessionCookieStore.merged(existing: existing, fresh: fresh)

        #expect(!merged.contains { $0.name == "canvas_session" })
    }

    @Test("Empty fresh input leaves the existing set unchanged")
    func emptyFreshInputIsUnchanged() {
        let existing = [cookie(name: "canvas_session", value: "synthetic-old", domain: "canvas.upenn.edu")]

        let merged = SessionCookieStore.merged(existing: existing, fresh: [])

        #expect(merged.count == 1)
        #expect(merged.first?.value == "synthetic-old")
    }

    // MARK: - CanvasGradesClient.responseCookies(from:requestURL:)

    private let requestURL = URL(string: "https://canvas.upenn.edu/api/v1/courses/12345/assignment_groups")!

    @Test("A response carrying a Set-Cookie header yields the parsed cookie")
    func responseWithSetCookieYieldsCookie() {
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "canvas_session=synthetic-rotated-2; Path=/; Secure; HttpOnly"]
        )!

        let cookies = CanvasGradesClient.responseCookies(from: response, requestURL: requestURL)

        #expect(cookies.contains { $0.name == "canvas_session" && $0.value == "synthetic-rotated-2" })
    }

    @Test("A response with no Set-Cookie header yields no cookies")
    func responseWithoutSetCookieYieldsEmpty() {
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!

        let cookies = CanvasGradesClient.responseCookies(from: response, requestURL: requestURL)

        #expect(cookies.isEmpty)
    }

    @Test("A Set-Cookie header scoped to a different domain than the request URL still parses without crashing")
    func setCookieOnDifferentDomainDoesNotCrash() {
        // `HTTPCookie.cookies(withResponseHeaderFields:for:)` scopes the
        // resulting cookies by `requestURL`'s host regardless of any
        // `Domain=` attribute in the header — this just asserts the seam
        // never crashes on that input and produces a sensible (non-nil,
        // still-parsed) cookie.
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "canvas_session=synthetic-rotated-3; Domain=evil.example.com; Path=/"]
        )!

        let cookies = CanvasGradesClient.responseCookies(from: response, requestURL: requestURL)

        #expect(cookies.contains { $0.name == "canvas_session" })
    }
}
