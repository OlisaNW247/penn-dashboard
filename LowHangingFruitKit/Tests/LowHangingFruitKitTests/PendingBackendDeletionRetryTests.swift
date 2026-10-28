import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The retry of a server-side account deletion (`AppState+BackendDeletion`)
/// had three holes an independent review found: it retried a permanent refusal
/// on every pass forever, it could sign up a fresh anonymous account just to
/// delete it, and the disconnect's own first call did not count as "in flight"
/// so a refresh landing during it could fire a second `delete-account`.
@MainActor
@Suite("Pending backend deletion retry", .serialized)
struct PendingBackendDeletionRetryTests {
    /// Puts `UserDefaults.lhf` back after each test (see `LHFDefaultsGuard`).
    private let defaultsGuard = LHFDefaultsGuard()

    private struct Offline: Error {}

    /// A call counter a `@Sendable` closure may capture.
    private final class Calls: @unchecked Sendable {
        private(set) var count = 0
        func note() { count += 1 }
    }

    private func makeState() throws -> AppState {
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        state.forceFixtureDataForTesting(false)
        return state
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "lhf.tests.pendingRetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Which failures are worth another try

    @Test("transport errors, 5xx, 401, 408 and 429 are retried; other 4xx, decoding and not-configured are not")
    func disposition() {
        let retried: [Error] = [
            BackendError.transport, BackendError.unauthorized, BackendError.quotaExceeded(resetAt: nil),
            BackendError.http(500), BackendError.http(502), BackendError.http(503), BackendError.http(504),
            BackendError.http(401), BackendError.http(408), BackendError.http(429),
            URLError(.notConnectedToInternet), Offline(),
        ]
        for error in retried {
            #expect(PendingBackendDeletion.shouldKeepRetrying(after: error), "\(error)")
        }
        let abandoned: [Error] = [
            BackendError.http(400), BackendError.http(403), BackendError.http(404), BackendError.http(409),
            BackendError.http(410), BackendError.http(422),
            BackendError.decoding, BackendError.notConfigured,
        ]
        for error in abandoned {
            #expect(!PendingBackendDeletion.shouldKeepRetrying(after: error), "\(error)")
        }
    }

    @Test("a 404 on the retry drops the record after one call, so it is not asked again on the next pass")
    func permanentRefusalIsDropped() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()
        PendingBackendDeletion.setPending(true, in: defaults)
        var calls = 0

        let first = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false) {
            calls += 1
            throw BackendError.http(404)
        }
        #expect(first == .abandoned)
        #expect(!PendingBackendDeletion.isPending(in: defaults))

        let second = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false) { calls += 1 }
        #expect(second == .nothingPending)
        #expect(calls == 1)
    }

    @Test("a 503 or a dropped connection keeps the record for the next pass")
    func transientFailureIsKept() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()
        for error in [BackendError.http(503), BackendError.transport] {
            PendingBackendDeletion.setPending(true, in: defaults)
            let attempt = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false) { throw error }
            #expect(attempt == .failed, "\(error)")
            #expect(PendingBackendDeletion.isPending(in: defaults), "\(error)")
        }
    }

    @Test("the disconnect's own first call drops the record on a permanent refusal and keeps it on a transient one")
    func firstCallFollowsTheSameRule() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()

        let refused = await state.performBackendDeletion(defaults: defaults, afterConfirmed: {}) { throw BackendError.http(403) }
        #expect(refused == false)
        #expect(!PendingBackendDeletion.isPending(in: defaults))

        let offline = await state.performBackendDeletion(defaults: defaults, afterConfirmed: {}) { throw BackendError.transport }
        #expect(offline == false)
        #expect(PendingBackendDeletion.isPending(in: defaults))
    }

    // MARK: No account, no call

    @Test("with no backend identity on the phone the record is dropped and nothing is sent")
    func noIdentityMakesNoCall() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()
        PendingBackendDeletion.setPending(true, in: defaults)
        let calls = Calls()

        state.startPendingBackendDeletionRetryIfNeeded(
            defaults: defaults, hasIdentity: { false }, afterConfirmed: {}
        ) { calls.note() }
        await state.awaitPendingBackendDeletionRetry()

        #expect(calls.count == 0)
        #expect(!PendingBackendDeletion.isPending(in: defaults))
    }

    @Test("with an identity the retry makes exactly one call and clears the record when it lands")
    func identityMakesOneCall() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()
        PendingBackendDeletion.setPending(true, in: defaults)
        let calls = Calls()

        state.startPendingBackendDeletionRetryIfNeeded(
            defaults: defaults, hasIdentity: { true }, afterConfirmed: {}
        ) { calls.note() }
        await state.awaitPendingBackendDeletionRetry()

        #expect(calls.count == 1)
        #expect(!PendingBackendDeletion.isPending(in: defaults))
    }

    @Test("nothing pending means no identity lookup and no call")
    func nothingPendingDoesNothing() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()
        let calls = Calls()
        var looked = false

        state.startPendingBackendDeletionRetryIfNeeded(
            defaults: defaults, hasIdentity: { looked = true; return true }, afterConfirmed: {}
        ) { calls.note() }

        #expect(!looked)
        #expect(calls.count == 0)
    }

    // MARK: One call in flight

    @Test("a refresh pass that lands during the disconnect's first call does not send a second delete")
    func firstCallCountsAsInFlight() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()
        var secondAttempt: PendingBackendDeletion.Attempt?
        var secondCalls = 0

        let ok = await state.performBackendDeletion(defaults: defaults, afterConfirmed: {}) {
            // The refresh pass, while the first call is still waiting on the network.
            secondAttempt = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false) {
                secondCalls += 1
            }
        }

        #expect(ok)
        #expect(secondAttempt == .alreadyRunning)
        #expect(secondCalls == 0)

        // And the flag is released afterwards, so the next pass is not blocked forever.
        PendingBackendDeletion.setPending(true, in: defaults)
        let later = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false, afterConfirmed: {}) { }
        #expect(later == .deleted)
    }

    @Test("the flag is released after a failed first call too")
    func flightFlagReleasedOnFailure() async throws {
        let state = try makeState()
        let defaults = scratchDefaults()
        _ = await state.performBackendDeletion(defaults: defaults, afterConfirmed: {}) { throw BackendError.transport }
        let next = await state.retryPendingBackendDeletion(defaults: defaults, canvasConnected: false, afterConfirmed: {}) { }
        #expect(next == .deleted)
    }
}
