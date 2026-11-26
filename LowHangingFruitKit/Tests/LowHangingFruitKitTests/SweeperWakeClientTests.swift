import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Answers `sweeper-wake` calls with a scripted reply and records the bodies;
/// GoTrue paths go to `GoTrueScript`. Its own statics (not `AgentStubProtocol`'s)
/// so two suites never clobber each other.
final class WakeStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var goTrue = GoTrueScript()
    nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "{}")
    nonisolated(unsafe) static var seen: [(path: String, raw: Data)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let status: Int, body: Data
        if path.contains("/functions/v1/") {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&buffer, maxLength: buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                stream.close()
            }
            Self.seen.append((path, data))
            (status, body) = (Self.reply.status, Data(Self.reply.body.utf8))
        } else {
            let r = Self.goTrue.reply(to: request)
            (status, body) = (r.status, r.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Sweeper wake client", .serialized)
struct SweeperWakeClientTests {
    private func make(_ status: Int = 200, _ body: String = "{}") -> SweeperWakeClient {
        WakeStubProtocol.goTrue = GoTrueScript()
        WakeStubProtocol.reply = (status, body)
        WakeStubProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WakeStubProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let session = BackendSession(
            configuration: BackendTestConfiguration.configuration, urlSession: urlSession,
            persistence: MemoryIdentity().persistence)
        return SweeperWakeClient(client: BackendClient(
            configuration: BackendTestConfiguration.configuration, session: session, urlSession: urlSession))
    }

    private var lastBody: [String: Any] {
        guard let raw = WakeStubProtocol.seen.last?.raw else { return [:] }
        return (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
    }

    private let moment = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("the put body has exactly action, token, environment, moments and plan")
    func putKeys() async throws {
        let client = make(200, #"{"stored":2,"nextMoment":"2027-01-15T10:45:00Z"}"#)
        let response = try await client.put(
            token: "ab12cd", environment: "production", moments: [moment, moment.addingTimeInterval(720)], plan: "0123456789abcdef")
        #expect(WakeStubProtocol.seen.last?.path.hasSuffix("/functions/v1/sweeper-wake") == true)
        #expect(Set(lastBody.keys) == ["action", "token", "environment", "moments", "plan"])
        #expect(lastBody["action"] as? String == "put")
        #expect(lastBody["token"] as? String == "ab12cd")
        #expect(lastBody["environment"] as? String == "production")
        #expect(lastBody["plan"] as? String == "0123456789abcdef")
        let wire = try #require(lastBody["moments"] as? [String])
        #expect(wire == [SweeperWakePlan.iso(moment), SweeperWakePlan.iso(moment.addingTimeInterval(720))])
        for text in wire {
            #expect(text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$"#, options: .regularExpression) != nil)
        }
        #expect(response == SweeperWakePutResponse(stored: 2, nextMoment: "2027-01-15T10:45:00Z"))
    }

    @Test("an empty plan is still a put, with an empty list")
    func emptyPut() async throws {
        let client = make(200, #"{"stored":0,"nextMoment":null}"#)
        let response = try await client.put(token: "ab", environment: "development", moments: [], plan: "e3b0c44298fc1c14")
        #expect((lastBody["moments"] as? [Any])?.isEmpty == true)
        #expect(lastBody["environment"] as? String == "development")
        #expect(response.stored == 0 && response.nextMoment == nil)
    }

    @Test("the delete body is exactly {\"action\":\"delete\"} and answers the count")
    func deleteBody() async throws {
        let client = make(200, #"{"deleted":1}"#)
        let deleted = try await client.delete()
        #expect(deleted == 1)
        #expect(Set(lastBody.keys) == ["action"])
        #expect(lastBody["action"] as? String == "delete")
    }

    @Test("a refusal is a thrown status, with no body in the error")
    func refusal() async {
        let client = make(400, #"{"error":"forbidden_field"}"#)
        await #expect(throws: BackendError.self) {
            _ = try await client.put(token: "ab", environment: "production", moments: [], plan: "x")
        }
    }

    @Test("the environment word follows the build")
    func environment() {
        #if DEBUG
        #expect(SweeperWakeClient.currentEnvironment == "development")
        #else
        #expect(SweeperWakeClient.currentEnvironment == "production")
        #endif
    }
}
