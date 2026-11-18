import Foundation
import LowHangingFruitKit

/// What `sweeper-wake` answers to a `put`.
struct SweeperWakePutResponse: Decodable, Equatable, Sendable {
    let stored: Int
    /// The server's next moment, ISO 8601, or nil when it holds none.
    let nextMoment: String?
}

/// The request bodies, with exactly the keys the server allows: it refuses any
/// other with `forbidden_field`, and a test pins the encoded key set. Nothing
/// about an assignment, a class or the student is here, and nothing may be
/// added (docs/PRIVACY.md → the Sweeper wake).
struct SweeperWakePutRequest: Encodable, Equatable, Sendable {
    let action = "put"
    let token: String
    let environment: String
    let moments: [String]
    let plan: String

    enum CodingKeys: String, CodingKey { case action, token, environment, moments, plan }
}

struct SweeperWakeDeleteRequest: Encodable, Equatable, Sendable {
    let action = "delete"
    enum CodingKeys: String, CodingKey { case action }
}

private struct SweeperWakeDeleteResponse: Decodable { let deleted: Int }

/// The phone's side of the `sweeper-wake` function (`backend/PROTOCOL.md`).
/// The HTTP mechanics are `BackendClient.post`'s. This layer never logs a
/// token, and errors carry a status and never a body.
struct SweeperWakeClient: Sendable {
    let client: BackendClient

    init(client: BackendClient) { self.client = client }

    /// The environment the build registers with: a development-signed (Debug)
    /// build gets a sandbox token, anything else a production one. Apple
    /// refuses a token sent to the other gateway.
    static var currentEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    func put(token: String, environment: String, moments: [Date], plan: String) async throws -> SweeperWakePutResponse {
        let body = SweeperWakePutRequest(
            token: token, environment: environment,
            moments: moments.map(SweeperWakePlan.iso), plan: plan)
        return try await client.post("sweeper-wake", body: body)
    }

    @discardableResult
    func delete() async throws -> Int {
        let response: SweeperWakeDeleteResponse = try await client.post("sweeper-wake", body: SweeperWakeDeleteRequest())
        return response.deleted
    }
}

/// The two calls as a seam, so a pass test drives `sweeperWakePass` without a
/// network.
struct SweeperWakeTransport: Sendable {
    var put: @Sendable (_ token: String, _ environment: String, _ moments: [Date], _ plan: String) async throws -> Int
    var delete: @Sendable () async throws -> Int

    static func live(_ client: SweeperWakeClient) -> SweeperWakeTransport {
        SweeperWakeTransport(
            put: { token, environment, moments, plan in
                try await client.put(token: token, environment: environment, moments: moments, plan: plan).stored
            },
            delete: { try await client.delete() })
    }
}
