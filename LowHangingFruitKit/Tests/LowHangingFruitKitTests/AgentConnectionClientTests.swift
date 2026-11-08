import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Answers function calls with a scripted reply and records them; GoTrue paths
/// go to `GoTrueScript`. Process-wide statics, so the suite is serialized.
final class AgentStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var goTrue = GoTrueScript()
    nonisolated(unsafe) static var reply: (status: Int, body: String) = (200, "{}")
    nonisolated(unsafe) static var seen: [(path: String, body: [String: Any])] = []

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
            let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            Self.seen.append((path, object))
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

@Suite("Agent connection client", .serialized)
struct AgentConnectionClientTests {
    private func make(_ status: Int = 200, _ body: String = "{}") -> AgentConnectionClient {
        AgentStubProtocol.goTrue = GoTrueScript()
        AgentStubProtocol.reply = (status, body)
        AgentStubProtocol.seen = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentStubProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let session = BackendSession(
            configuration: BackendTestConfiguration.configuration, urlSession: urlSession,
            persistence: MemoryIdentity().persistence)
        return AgentConnectionClient(client: BackendClient(
            configuration: BackendTestConfiguration.configuration, session: session, urlSession: urlSession))
    }

    private var lastBody: [String: Any] { AgentStubProtocol.seen.last?.body ?? [:] }
    private var lastPath: String { AgentStubProtocol.seen.last?.path ?? "" }

    @Test func mapsStatuses() {
        #expect(AgentConnectionError.map(BackendError.http(404)) == .notFound)
        #expect(AgentConnectionError.map(BackendError.http(409)) == .alreadyDecided)
        #expect(AgentConnectionError.map(BackendError.http(403)) == .forbidden)
        #expect(AgentConnectionError.map(BackendError.http(413)) == .tooLarge)
        #expect(AgentConnectionError.map(BackendError.http(400)) == .badRequest)
        #expect(AgentConnectionError.map(BackendError.http(500)) == .other(.http(500)))
        #expect(AgentConnectionError.map(BackendError.unauthorized) == .other(.unauthorized))
        #expect(AgentConnectionError.map(URLError(.notConnectedToInternet)) == .other(.transport))
    }

    private let lookupJSON = #"{"id":"p1","clientName":"Claude","clientHost":"claude.ai","scopes":["read","draft"],"choices":[12,48,7],"expiresAt":"2026-11-08T12:05:00.123Z"}"#

    @Test func lookupByIDAndCode() async throws {
        let client = make(200, lookupJSON)
        let found = try await client.lookup(pendingID: "abcdEFGH12")
        #expect(lastPath.hasSuffix("/functions/v1/agent-auth/phone"))
        #expect(lastBody["action"] as? String == "lookup")
        #expect(lastBody["c"] as? String == "abcdEFGH12")
        #expect(lastBody["code"] == nil)
        #expect(found.clientName == "Claude" && found.choices == [12, 48, 7] && found.scopes == ["read", "draft"])
        _ = try await client.lookup(typedCode: "BCDFGHJK")
        #expect(lastBody["code"] as? String == "BCDFGHJK")
        #expect(lastBody["c"] == nil)
    }

    @Test func approveAndDeny() async throws {
        var client = make(200, #"{"approved":true,"clientName":"Claude"}"#)
        #expect(try await client.approve(pendingID: "p", picked: 48) == true)
        #expect(lastBody["action"] as? String == "approve")
        #expect(lastBody["c"] as? String == "p")
        #expect(lastBody["picked"] as? Int == 48)
        client = make(200, #"{"approved":false,"reason":"match"}"#)
        #expect(try await client.approve(pendingID: "p", picked: 1) == false)
        client = make(200, #"{"denied":true}"#)
        try await client.deny(pendingID: "p")
        #expect(lastBody["action"] as? String == "deny")
        #expect(lastBody["c"] as? String == "p")
    }

    @Test func approveConflictMaps() async {
        let client = make(409, #"{"error":"already_decided"}"#)
        await #expect(throws: AgentConnectionError.alreadyDecided) {
            _ = try await client.approve(pendingID: "p", picked: 1)
        }
    }

    @Test func listRevokeRevokeAll() async throws {
        var client = make(200, #"{"connections":[{"id":"c1","clientName":"Claude","clientHost":null,"scopes":["read"],"createdAt":"2026-11-08T12:00:00+00:00","lastUsedAt":null}]}"#)
        let list = try await client.listConnections()
        #expect(lastBody["action"] as? String == "list")
        #expect(list.count == 1 && list[0].id == "c1" && list[0].clientHost == nil && list[0].lastUsedAt == nil)
        client = make(200, #"{"revoked":true}"#)
        #expect(try await client.revoke(connectionID: "c1") == true)
        #expect(lastBody["action"] as? String == "revoke")
        #expect(lastBody["id"] as? String == "c1")
        client = make(200, #"{"revoked":3}"#)
        #expect(try await client.revokeAll() == 3)
        #expect(lastBody["action"] as? String == "revokeAll")
    }

    @Test func putStatusDelete() async throws {
        var client = make(200, #"{"writtenAt":"2026-11-08T12:00:00.500Z","items":1}"#)
        let snapshot = AgentSnapshot(courses: [], workList: [
            .init(id: "a", course: "X", title: "t", kind: .quiz, dueAt: nil, done: false,
                  noSubmission: false, url: nil, source: "canvas")], manual: [])
        let written = try await client.putSnapshot(snapshot)
        #expect(lastPath.hasSuffix("/functions/v1/agent-snapshot"))
        #expect(lastBody["action"] as? String == "put")
        let sent = try #require(lastBody["snapshot"] as? [String: Any])
        #expect(Set(sent.keys) == ["courses", "workList", "manual"])
        let item = try #require((sent["workList"] as? [[String: Any]])?.first)
        #expect(item["dueAt"] is NSNull && item["url"] is NSNull)
        #expect(written == Date(timeIntervalSince1970: 1_794_139_200.5))

        client = make(200, #"{"hasSnapshot":true,"writtenAt":"2026-11-08T12:00:00.500Z","items":7}"#)
        let status = try await client.snapshotStatus()
        #expect(lastBody["action"] as? String == "status")
        #expect(status.hasSnapshot && status.items == 7 && status.writtenAt != nil)
        client = make(200, #"{"hasSnapshot":false,"writtenAt":null,"items":0}"#)
        #expect(try await client.snapshotStatus().writtenAt == nil)

        client = make(200, #"{"deleted":true,"revoked":2}"#)
        #expect(try await client.deleteSnapshot() == 2)
        #expect(lastBody["action"] as? String == "delete")
    }
}
