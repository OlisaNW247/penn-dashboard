import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// One backend sign-in at a time (hardening plan A10, SYN-06).
//
// `BackendSession` is an actor, but every network call inside `accessToken` is
// an `await`, and an actor is re-entrant across one. Two first callers (the
// dashboard's course-material sync and an `ask` inside the same second of a
// cold launch) both found no cached token and no saved identity, and both
// signed up: two anonymous accounts, the second overwriting the first in the
// Keychain, the first orphaned with whatever it already did on the server. Two
// concurrent refreshes are worse: refresh tokens rotate, so the second one
// presents a token the first just retired, is rejected, and the session
// "recovers" by discarding the identity and signing up a new account.
//
// The stub holds each sign-up open for a third of a second so the second
// caller really does arrive while the first is in flight. `.serialized`: the
// stub's script is a process-wide static.

@Suite("Backend session: one sign-in at a time", .serialized)
struct BackendSessionSingleFlightTests {
    private func session(_ script: GoTrueScript, _ identity: MemoryIdentity) -> BackendSession {
        BackendSession(
            configuration: BackendTestConfiguration.configuration,
            urlSession: GoTrueStubProtocol.session(for: script),
            persistence: identity.persistence
        )
    }

    private func tokens(from session: BackendSession, callers: Int, forceRefresh: Bool = false) async throws -> [String] {
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<callers {
                group.addTask { try await session.accessToken(forceRefresh: forceRefresh) }
            }
            var out: [String] = []
            for try await token in group { out.append(token) }
            return out
        }
    }

    private static func outcome(_ body: () async throws -> String) async -> Result<String, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    @Test("two concurrent first callers create one account, and both get its token")
    func twoFirstCallersOneAccount() async throws {
        let script = GoTrueScript(signupDelay: 0.3)
        let identity = MemoryIdentity(.notFound)
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        let results = try await tokens(from: session, callers: 2)

        #expect(script.signups == 1)
        #expect(results == ["signup-access-1", "signup-access-1"])
        #expect(identity.saves.count == 1, "the first account is not overwritten by a second")
    }

    @Test("a crowd of concurrent first callers still signs up once")
    func manyFirstCallers() async throws {
        let script = GoTrueScript(signupDelay: 0.3)
        let identity = MemoryIdentity(.notFound)
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        let results = try await tokens(from: session, callers: 12)

        #expect(script.signups == 1)
        #expect(Set(results) == ["signup-access-1"])
        #expect(identity.saves.count == 1)
    }

    @Test("two concurrent callers with a saved identity refresh once, not twice (a rotated token cannot be presented twice)")
    func twoCallersOneRefresh() async throws {
        let script = GoTrueScript()
        let identity = MemoryIdentity(.found(BackendIdentity(userID: "u", refreshToken: "saved-refresh")))
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        let results = try await tokens(from: session, callers: 2)

        #expect(script.refreshes == 1)
        #expect(script.signups == 0)
        #expect(script.refreshTokensSeen == ["saved-refresh"])
        #expect(Set(results).count == 1)
    }

    @Test("a later call is served from the cache: nothing more is sent")
    func laterCallUsesCache() async throws {
        let script = GoTrueScript(signupDelay: 0.1)
        let identity = MemoryIdentity(.notFound)
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        _ = try await tokens(from: session, callers: 3)
        let again = try await session.accessToken()

        #expect(again == "signup-access-1")
        #expect(script.signups == 1)
        #expect(script.refreshes == 0)
    }

    @Test("a forced refresh that arrives during a running sign-in joins it")
    func forceRefreshJoins() async throws {
        let script = GoTrueScript(signupDelay: 0.3)
        let identity = MemoryIdentity(.notFound)
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        async let first = session.accessToken()
        try await Task.sleep(for: .milliseconds(50))
        async let forced = session.accessToken(forceRefresh: true)
        let (a, b) = try await (first, forced)

        #expect(a == b)
        #expect(script.signups == 1)
    }

    @Test("a failed sign-in is shared by everyone waiting on it, then cleared so the next call tries again")
    func failureIsSharedThenRetried() async throws {
        let script = GoTrueScript(signupDelay: 0.3, signupStatuses: [500, 200])
        let identity = MemoryIdentity(.notFound)
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        async let one = Self.outcome { try await session.accessToken() }
        async let two = Self.outcome { try await session.accessToken() }
        let outcomes = await [one, two]

        for outcome in outcomes {
            guard case let .failure(error) = outcome else {
                Issue.record("expected both callers to see the failure")
                continue
            }
            #expect(error as? BackendError == .http(500))
        }
        #expect(script.signups == 1, "one request, one failure, shared")
        #expect(identity.saves.isEmpty)

        let token = try await session.accessToken()
        #expect(token == "signup-access-2")
        #expect(script.signups == 2)
    }

    @Test("an identity forgotten while a sign-in is out is not saved when the account comes back")
    func forgetDuringFlight() async throws {
        let script = GoTrueScript(signupDelay: 0.4)
        let identity = MemoryIdentity(.notFound)
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        let inFlight = Task { try await session.accessToken() }
        // Wait until the sign-up request has actually reached the stub.
        for _ in 0..<200 where script.signups == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(script.signups == 1)

        await session.forgetIdentity()
        await #expect(throws: BackendError.transport) { _ = try await inFlight.value }
        #expect(identity.saves.isEmpty, "the forgotten account must not be written back")

        // And the session is not wedged: the next call starts a fresh sign-up.
        let token = try await session.accessToken()
        #expect(token == "signup-access-2")
        #expect(identity.saves.count == 1)
    }

    // The recovery path of a flight is where a stale one used to do damage: a
    // refresh that was in flight when the identity was forgotten comes back
    // 400/401, and the old catch cleared the persisted identity (by then a NEW
    // one) and signed up again, orphaning an account.

    @Test("a refresh rejected after the identity was forgotten leaves the newer identity intact")
    func forgetDuringFailingRefresh() async throws {
        let script = GoTrueScript(refreshDelay: 0.5, refreshStatuses: [400])
        let identity = MemoryIdentity(.found(BackendIdentity(userID: "old-user", refreshToken: "old-refresh")))
        let session = session(script, identity)
        defer { GoTrueStubProtocol.script = nil }

        // Flight 1: refreshing the old identity; the server will say 400 late.
        let stale = Task { try await session.accessToken() }
        for _ in 0..<200 where script.refreshes == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(script.refreshes == 1)

        // The student's data is deleted, and a NEW identity is minted before
        // flight 1's answer arrives.
        await session.forgetIdentity()
        let fresh = try await session.accessToken()
        #expect(fresh == "signup-access-1")
        let newIdentity = BackendIdentity(userID: "signup-user-1", refreshToken: "signup-refresh-1")
        #expect(identity.current == .found(newIdentity))
        #expect(identity.clears == 1, "only the forget has cleared anything so far")

        // Flight 1's 400 now lands.
        await #expect(throws: BackendError.transport) { _ = try await stale.value }

        #expect(identity.clears == 1, "the stale flight must not clear the newer identity")
        #expect(identity.current == .found(newIdentity))
        #expect(script.signups == 1, "and must not sign up a second account")
    }
}
