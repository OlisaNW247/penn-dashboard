import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// Shared stubs for the `BackendSession` suites: a scripted GoTrue behind a
// `URLProtocol`, and an in-memory identity store behind
// `BackendIdentityPersistence`. Neither touches the network or the Keychain.
// `BackendSession` takes both as initializer arguments for exactly this.

/// A scripted GoTrue. Counts every sign-up and refresh it serves and replies
/// after `signupDelay`, so a test can hold a first sign-up in flight while a
/// second caller arrives.
final class GoTrueScript: @unchecked Sendable {
    private let lock = NSLock()
    private var _signups = 0
    private var _refreshes = 0
    private var _refreshTokensSeen: [String] = []
    private var _refreshStatuses: [Int]

    let signupDelay: TimeInterval

    /// - Parameter refreshStatuses: statuses for successive refresh calls (the
    ///   last repeats); 200 serves a token.
    init(signupDelay: TimeInterval = 0, refreshStatuses: [Int] = [200]) {
        self.signupDelay = signupDelay
        self._refreshStatuses = refreshStatuses
    }

    var signups: Int { lock.withLock { _signups } }
    var refreshes: Int { lock.withLock { _refreshes } }
    var refreshTokensSeen: [String] { lock.withLock { _refreshTokensSeen } }

    func reply(to request: URLRequest) -> (status: Int, body: Data, delay: TimeInterval) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/auth/v1/signup") {
            let n = lock.withLock { () -> Int in _signups += 1; return _signups }
            return (200, Self.goTrueBody(n: n, prefix: "signup"), signupDelay)
        }
        if path.hasSuffix("/auth/v1/token") {
            let body = Self.bodyData(of: request)
            let seen = (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["refresh_token"] ?? ""
            let (n, status) = lock.withLock { () -> (Int, Int) in
                _refreshes += 1
                _refreshTokensSeen.append(seen)
                let status = _refreshStatuses.count > 1 ? _refreshStatuses.removeFirst() : (_refreshStatuses.first ?? 200)
                return (_refreshes, status)
            }
            if status == 200 { return (200, Self.goTrueBody(n: n, prefix: "refresh"), 0) }
            return (status, Data("{}".utf8), 0)
        }
        return (404, Data("{}".utf8), 0)
    }

    private static func goTrueBody(n: Int, prefix: String) -> Data {
        let json: [String: Any] = [
            "access_token": "\(prefix)-access-\(n)",
            "expires_in": 3600,
            "refresh_token": "\(prefix)-refresh-\(n)",
            "user": ["id": "\(prefix)-user-\(n)"],
        ]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    /// `URLSession` hands a request body to a protocol as a stream.
    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class GoTrueStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var script: GoTrueScript?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let script = Self.script else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let reply = script.reply(to: request)
        let respond = { [self] in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}

    static func session(for script: GoTrueScript) -> URLSession {
        Self.script = script
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoTrueStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// An in-memory `BackendIdentityPersistence`, with a scriptable read.
final class MemoryIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var _read: KeychainRead<BackendIdentity>
    private var _saves: [BackendIdentity] = []
    private var _clears = 0

    init(_ read: KeychainRead<BackendIdentity> = .notFound) { self._read = read }

    var current: KeychainRead<BackendIdentity> {
        get { lock.withLock { _read } }
        set { lock.withLock { _read = newValue } }
    }
    var saves: [BackendIdentity] { lock.withLock { _saves } }
    var clears: Int { lock.withLock { _clears } }

    /// A real store would answer `found` with what was last saved; so does this.
    var persistence: BackendIdentityPersistence {
        BackendIdentityPersistence(
            read: { [self] in current },
            save: { [self] identity in
                lock.withLock { _saves.append(identity); _read = .found(identity) }
            },
            clear: { [self] in
                lock.withLock { _clears += 1; _read = .notFound }
            }
        )
    }
}

enum BackendTestConfiguration {
    static let configuration = BackendConfiguration(
        url: URL(string: "https://backend.stub.invalid")!,
        anonKey: "anon-key-for-tests"
    )
}
