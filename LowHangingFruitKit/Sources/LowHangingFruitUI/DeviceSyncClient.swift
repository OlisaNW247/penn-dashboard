import Foundation
import LowHangingFruitKit

/// Why a `pair` or `device-sync` call failed, in the terms the pairing and
/// sync screens branch on. Everything that is not one of the four statuses the
/// two functions answer with on purpose stays the `BackendError` it was, so a
/// dead network or an expired quota is still told apart from "that code is not
/// valid".
enum DeviceSyncError: Error, Equatable {
    /// 404 from `pair`: an unknown, malformed or expired code (the server
    /// answers all three alike so codes cannot be probed), or, for `unpair`,
    /// a device that is not this owner's.
    case pairingNotFound
    /// 403: the caller may not do this (`claim` from a device that is itself
    /// linked or from the code's own user; `device-sync` from a user with no
    /// pairing).
    case notAllowed
    /// 409: already paired.
    case conflict
    /// 413: the sealed snapshot is over the server's 2 MB cap.
    case tooLarge
    case other(BackendError)

    /// Pure, so the mapping is tested without a network.
    static func map(_ error: Error) -> DeviceSyncError {
        guard let backend = error as? BackendError else { return .other(.transport) }
        guard case .http(let status) = backend else { return .other(backend) }
        switch status {
        case 404: return .pairingNotFound
        case 403: return .notAllowed
        case 409: return .conflict
        case 413: return .tooLarge
        default: return .other(backend)
        }
    }
}

/// One device's row as `device-sync` `get` returns it. `ciphertext` is the
/// sealed snapshot in standard base64 (`SyncSnapshotCrypto.open`); this layer
/// never looks inside it.
struct DeviceSyncBlob: Decodable, Equatable, Sendable {
    let deviceId: String
    let ciphertext: String
    let updatedAt: Date
}

/// The phone's side of `pair` and `device-sync` (`backend/PROTOCOL.md`). The
/// HTTP mechanics (auth headers, the one refresh-and-retry on a 401, status to
/// `BackendError`) are `BackendClient.post`'s, reused rather than copied.
///
/// Nothing here logs a code, a key or a ciphertext, and nothing may: a pairing
/// code is a ten-minute bearer credential, and the server's whole promise is
/// that it cannot read the blobs. Errors carry a status, never a body.
struct DeviceSyncClient: Sendable {
    let client: BackendClient

    init(client: BackendClient) {
        self.client = client
    }

    // MARK: pair

    /// The phone approves a laptop's pairing code with its own token. Throws
    /// `.pairingNotFound` for a code that is not live, `.notAllowed` if this
    /// phone is itself a linked device, `.conflict` if the laptop is already
    /// paired.
    func claim(code: String) async throws {
        struct Request: Encodable { let action = "claim"; let code: String }
        struct Response: Decodable { let paired: Bool }
        let response: Response = try await call("pair", Request(code: code))
        guard response.paired else { throw DeviceSyncError.other(.decoding) }
    }

    /// Owner side: removes one device, or every device when `deviceUserId` is
    /// nil. Answers how many were removed.
    @discardableResult
    func unpair(deviceUserId: String? = nil) async throws -> Int {
        struct Request: Encodable { let action = "unpair"; let deviceUserId: String? }
        struct Response: Decodable { let unpaired: Int }
        let response: Response = try await call("pair", Request(deviceUserId: deviceUserId))
        return response.unpaired
    }

    // MARK: device-sync

    /// Uploads this phone's sealed snapshot. Answers the device id the server
    /// used (an owner's is the one sent).
    @discardableResult
    func put(deviceId: String, ciphertext: String) async throws -> String {
        struct Request: Encodable { let action = "put"; let deviceId: String; let ciphertext: String }
        struct Response: Decodable { let deviceId: String }
        let response: Response = try await call("device-sync", Request(deviceId: deviceId, ciphertext: ciphertext))
        return response.deviceId
    }

    /// Every device's latest blob for this owner, this phone's own included
    /// (the caller drops its own `deviceId` before merging).
    func get() async throws -> [DeviceSyncBlob] {
        struct Request: Encodable { let action = "get" }
        struct Response: Decodable { let blobs: [DeviceSyncBlob] }
        let response: Response = try await call("device-sync", Request())
        return response.blobs
    }

    private func call<T: Decodable>(_ function: String, _ body: some Encodable) async throws -> T {
        do {
            return try await client.post(function, body: body)
        } catch {
            throw DeviceSyncError.map(error)
        }
    }
}
