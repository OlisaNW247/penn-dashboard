import CryptoKit
import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The pure halves of the pairing and sync plumbing. The network calls
/// themselves go through `BackendClient.post`, which has its own coverage.
@Suite struct DeviceSyncClientTests {
    @Test func mapsTheStatusesTheFunctionsAnswerWith() {
        #expect(DeviceSyncError.map(BackendError.http(404)) == .pairingNotFound)
        #expect(DeviceSyncError.map(BackendError.http(403)) == .notAllowed)
        #expect(DeviceSyncError.map(BackendError.http(409)) == .conflict)
        #expect(DeviceSyncError.map(BackendError.http(413)) == .tooLarge)
    }

    @Test func everythingElseStaysTheBackendError() {
        #expect(DeviceSyncError.map(BackendError.http(500)) == .other(.http(500)))
        #expect(DeviceSyncError.map(BackendError.transport) == .other(.transport))
        #expect(DeviceSyncError.map(BackendError.unauthorized) == .other(.unauthorized))
        #expect(DeviceSyncError.map(URLError(.notConnectedToInternet)) == .other(.transport))
    }

    @Test func decodesTheGetResponseShape() throws {
        struct Response: Decodable { let blobs: [DeviceSyncBlob] }
        let json = #"{"blobs":[{"deviceId":"abc-12345","ciphertext":"AAEC","updatedAt":"2026-10-22T12:00:00.123+00:00"}]}"#
        let response = try BackendJSON.decoder().decode(Response.self, from: Data(json.utf8))
        #expect(response.blobs.count == 1)
        #expect(response.blobs[0].deviceId == "abc-12345")
        #expect(response.blobs[0].ciphertext == "AAEC")
    }

    @Test func theKeyStoreAcceptsOnlyThirtyTwoBytes() {
        #expect(SyncKeyStore.key(from: Data(count: 32)) != nil)
        #expect(SyncKeyStore.key(from: Data(count: 31)) == nil)
        #expect(SyncKeyStore.key(from: Data(count: 33)) == nil)
        #expect(SyncKeyStore.key(from: Data()) == nil)
    }
}
