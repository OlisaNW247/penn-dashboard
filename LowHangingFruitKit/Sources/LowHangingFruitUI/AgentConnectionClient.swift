import Foundation
import LowHangingFruitKit

/// Why an `agent-auth/phone` or `agent-snapshot` call failed, in the terms the
/// connection screens branch on. Anything else stays the `BackendError` it was.
enum AgentConnectionError: Error, Equatable {
    /// 404: an unknown, expired or already-decided pending id or code (the
    /// server answers all alike so ids cannot be probed).
    case notFound
    /// 409: someone decided this request in the meantime.
    case alreadyDecided
    /// 403: this caller may not do this.
    case forbidden
    /// 413: the snapshot is over the server's cap.
    case tooLarge
    /// 400: the server refused the body.
    case badRequest
    case other(BackendError)

    static func map(_ error: Error) -> AgentConnectionError {
        guard let backend = error as? BackendError else { return .other(.transport) }
        guard case .http(let status) = backend else { return .other(backend) }
        switch status {
        case 404: return .notFound
        case 409: return .alreadyDecided
        case 403: return .forbidden
        case 413: return .tooLarge
        case 400: return .badRequest
        default: return .other(backend)
        }
    }
}

/// What `lookup` answers: who is asking and the three numbers to pick from.
struct AgentPendingLookup: Decodable, Equatable, Sendable {
    let id: String
    let clientName: String
    let clientHost: String
    let scopes: [String]
    let choices: [Int]
    let expiresAt: Date
}

struct AgentConnectionSummary: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let clientName: String
    let clientHost: String?
    let scopes: [String]
    let createdAt: Date
    let lastUsedAt: Date?
}

/// The phone's side of `agent-auth/phone` and `agent-snapshot`
/// (`backend/PROTOCOL.md`, "The agent connection"). HTTP mechanics are
/// `BackendClient.post`'s. A slash in the function name is fine there: it is
/// appended to `functions/v1/`.
///
/// Nothing here logs a pending id, a typed code, a snapshot or a response
/// body; errors carry a status only. A pending id is a bearer credential for
/// the sign-in it names.
struct AgentConnectionClient: Sendable {
    let client: BackendClient

    init(client: BackendClient) {
        self.client = client
    }

    // MARK: agent-auth/phone

    func lookup(pendingID: String) async throws -> AgentPendingLookup {
        struct Request: Encodable { let action = "lookup"; let c: String }
        return try await call("agent-auth/phone", Request(c: pendingID))
    }

    func lookup(typedCode: String) async throws -> AgentPendingLookup {
        struct Request: Encodable { let action = "lookup"; let code: String }
        return try await call("agent-auth/phone", Request(code: typedCode))
    }

    /// False when the picked number was wrong: the server has denied the
    /// request.
    func approve(pendingID: String, picked: Int) async throws -> Bool {
        struct Request: Encodable { let action = "approve"; let c: String; let picked: Int }
        struct Response: Decodable { let approved: Bool }
        let response: Response = try await call("agent-auth/phone", Request(c: pendingID, picked: picked))
        return response.approved
    }

    func deny(pendingID: String) async throws {
        struct Request: Encodable { let action = "deny"; let c: String }
        struct Response: Decodable {}
        let _: Response = try await call("agent-auth/phone", Request(c: pendingID))
    }

    func listConnections() async throws -> [AgentConnectionSummary] {
        struct Request: Encodable { let action = "list" }
        struct Response: Decodable { let connections: [AgentConnectionSummary] }
        let response: Response = try await call("agent-auth/phone", Request())
        return response.connections
    }

    func revoke(connectionID: String) async throws -> Bool {
        struct Request: Encodable { let action = "revoke"; let id: String }
        struct Response: Decodable { let revoked: Bool }
        let response: Response = try await call("agent-auth/phone", Request(id: connectionID))
        return response.revoked
    }

    func revokeAll() async throws -> Int {
        struct Request: Encodable { let action = "revokeAll" }
        struct Response: Decodable { let revoked: Int }
        let response: Response = try await call("agent-auth/phone", Request())
        return response.revoked
    }

    // MARK: agent-snapshot

    func putSnapshot(_ snapshot: AgentSnapshot) async throws -> Date {
        struct Request: Encodable { let action = "put"; let snapshot: AgentSnapshot }
        struct Response: Decodable { let writtenAt: Date }
        let response: Response = try await call("agent-snapshot", Request(snapshot: snapshot))
        return response.writtenAt
    }

    func snapshotStatus() async throws -> (hasSnapshot: Bool, writtenAt: Date?, items: Int) {
        struct Request: Encodable { let action = "status" }
        struct Response: Decodable { let hasSnapshot: Bool; let writtenAt: Date?; let items: Int }
        let response: Response = try await call("agent-snapshot", Request())
        return (response.hasSnapshot, response.writtenAt, response.items)
    }

    /// Removes the snapshot and revokes every connection; answers how many.
    func deleteSnapshot() async throws -> Int {
        struct Request: Encodable { let action = "delete" }
        struct Response: Decodable { let revoked: Int }
        let response: Response = try await call("agent-snapshot", Request())
        return response.revoked
    }

    // MARK: Drafts

    /// The student's open drafts (`proposed` or `seen`), newest first. A file
    /// draft's `fileURL` is good for 120 seconds.
    func listDrafts() async throws -> [AgentDraft] {
        struct Request: Encodable { let action = "drafts" }
        struct Response: Decodable { let drafts: [AgentDraft] }
        let response: Response = try await call("agent-snapshot", Request())
        return response.drafts
    }

    /// Moves one draft. 409 (`alreadyDecided`) means it left an open state
    /// already, from another phone or an earlier report; 404 that it is gone.
    func decide(draftID: String, _ decision: AgentDraftDecision) async throws {
        struct Request: Encodable {
            let action = "draft"
            let id: String
            let status: String
            let canvas_submission_id: String?
            let attempt: Int?
            let error_class: String?

            func encode(to encoder: Encoder) throws {
                enum Keys: String, CodingKey { case action, id, status, canvas_submission_id, attempt, error_class }
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(action, forKey: .action)
                try c.encode(id, forKey: .id)
                try c.encode(status, forKey: .status)
                try c.encodeIfPresent(canvas_submission_id, forKey: .canvas_submission_id)
                try c.encodeIfPresent(attempt, forKey: .attempt)
                try c.encodeIfPresent(error_class, forKey: .error_class)
            }
        }
        struct Response: Decodable { let id: String; let status: String }
        var submissionID: String?, attempt: Int?, errorClass: String?
        switch decision {
        case let .submitted(id, a): submissionID = String(id.prefix(64)); attempt = a.map { min(max($0, 0), 1000) }
        case let .failed(e): errorClass = String(e.prefix(64))
        case .seen, .declined: break
        }
        let _: Response = try await call("agent-snapshot", Request(
            id: draftID, status: decision.status, canvas_submission_id: submissionID,
            attempt: attempt, error_class: errorClass))
    }

    private func call<T: Decodable>(_ function: String, _ body: some Encodable) async throws -> T {
        do {
            return try await client.post(function, body: body)
        } catch {
            throw AgentConnectionError.map(error)
        }
    }
}
