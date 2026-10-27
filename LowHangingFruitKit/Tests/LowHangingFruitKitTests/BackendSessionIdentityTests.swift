import Foundation
import Security
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// `BackendSession` and a Keychain that will not answer (hardening plan A5).
//
// "No saved identity" means sign up for a new anonymous account. A Keychain
// that merely refused to read (locked before first unlock, a background wake
// right after a reboot) used to look the same, so the next ask or sync minted
// a second account while the first one's refresh token sat unread, orphaning
// its quota and its rows. The identity now comes back as found, not found, or
// unavailable, and only "not found" signs up.
//
// `.serialized`: the stub's script is a process-wide static.

@Suite("Backend identity: an unreadable Keychain never mints an account", .serialized)
struct BackendIdentityUnavailableTests {
    private func session(_ script: GoTrueScript, _ identity: MemoryIdentity) -> BackendSession {
        BackendSession(
            configuration: BackendTestConfiguration.configuration,
            urlSession: GoTrueStubProtocol.session(for: script),
            persistence: identity.persistence
        )
    }

    private let saved = BackendIdentity(userID: "saved-user", refreshToken: "saved-refresh")

    @Test("an unavailable read fails the call as unreachable: no sign-up, no refresh, nothing saved or cleared")
    func unavailableDoesNotMint() async {
        let script = GoTrueScript()
        let identity = MemoryIdentity(.unavailable(errSecInteractionNotAllowed))
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        await #expect(throws: BackendError.transport) {
            _ = try await session.accessToken()
        }
        #expect(script.signups == 0)
        #expect(script.refreshes == 0)
        #expect(identity.saves.isEmpty)
        #expect(identity.clears == 0)
    }

    @Test("repeated calls against a refusing Keychain still never sign up")
    func repeatedUnavailableCalls() async {
        let script = GoTrueScript()
        let identity = MemoryIdentity(.unavailable(errSecAuthFailed))
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        for _ in 0..<4 {
            _ = try? await session.accessToken()
        }
        #expect(script.signups == 0)
    }

    @Test("a Keychain that comes back is used: the next call refreshes the saved identity instead of signing up")
    func recoveredKeychainRefreshes() async throws {
        let script = GoTrueScript()
        let identity = MemoryIdentity(.unavailable(errSecInteractionNotAllowed))
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        _ = try? await session.accessToken()
        identity.current = .found(saved)
        let token = try await session.accessToken()

        #expect(token == "refresh-access-1")
        #expect(script.signups == 0)
        #expect(script.refreshTokensSeen == ["saved-refresh"])
    }

    @Test("nothing saved signs up exactly once and saves the new identity")
    func notFoundSignsUp() async throws {
        let script = GoTrueScript()
        let identity = MemoryIdentity(.notFound)
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        let token = try await session.accessToken()

        #expect(token == "signup-access-1")
        #expect(script.signups == 1)
        #expect(identity.saves == [BackendIdentity(userID: "signup-user-1", refreshToken: "signup-refresh-1")])
    }

    @Test("a saved identity is refreshed, never replaced by a sign-up")
    func foundRefreshes() async throws {
        let script = GoTrueScript()
        let identity = MemoryIdentity(.found(saved))
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        _ = try await session.accessToken()

        #expect(script.signups == 0)
        #expect(script.refreshTokensSeen == ["saved-refresh"])
        // The rotated refresh token replaced the old one.
        #expect(identity.saves.last?.refreshToken == "refresh-refresh-1")
    }

    @Test("a refresh the server rejects as invalid still discards the identity and signs up, as before")
    func rejectedRefreshStillReplacesIdentity() async throws {
        for status in [400, 401] {
            let script = GoTrueScript(refreshStatuses: [status])
            let identity = MemoryIdentity(.found(saved))
            let session = session(script, identity)
            defer { GoTrueStubProtocol.script = nil }

            let token = try await session.accessToken()

            #expect(token == "signup-access-1")
            #expect(script.signups == 1)
            #expect(identity.clears == 1)
        }
    }
}
