import Foundation
import LowHangingFruitKit

/// The server half of "disconnect Canvas": `delete-account` removes the
/// student's enrollment and usage rows and their anonymous account from the
/// backend, and a disconnect promises that. The call is a network request, so
/// it can fail offline, and until now a failure was reported once, on a
/// Settings line that told the student to reconnect and disconnect again,
/// while the rows sat on the server indefinitely. This remembers the request
/// until the server confirms it, and stops remembering it when the server has
/// answered in a way no retry will change (`shouldKeepRetrying`) or there is no
/// account on this phone to delete.
///
/// The record is a boolean in `UserDefaults.lhf`, device-local on purpose: it
/// is not in `CloudPrefsMirror.mirroredKeys`, because a second device deciding
/// "delete my account" because the first one once failed to would be wrong in
/// a way nobody could see. It holds no identity, token or course, only the
/// fact that a deletion was asked for.
enum PendingBackendDeletion {

    nonisolated static let defaultsKey = "backendDeletionPendingV1"

    nonisolated static func isPending(in defaults: UserDefaults = .lhf) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    nonisolated static func setPending(_ pending: Bool, in defaults: UserDefaults = .lhf) {
        if pending {
            defaults.set(true, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    enum Decision: Equatable {
        case nothingPending
        /// Ask the server again.
        case retry
        /// A deletion is on record but Canvas is connected again, so the
        /// student has reconnected since asking. Deleting now would remove the
        /// rows of the session they are using, and the identity with them.
        /// The wish was superseded; drop it without a call.
        case dropSuperseded
    }

    /// Pure, so a test can pin all three answers. The reconnect case is the
    /// one a naive "retry until it succeeds" gets wrong: a student who
    /// disconnected offline, came back online and signed in again would have
    /// the retry delete the account their fresh sync had just rebuilt.
    nonisolated static func decision(pending: Bool, canvasConnected: Bool) -> Decision {
        guard pending else { return .nothingPending }
        return canvasConnected ? .dropSuperseded : .retry
    }

    /// Whether a deletion that just failed with `error` is worth asking for
    /// again. Pure, so a test can pin the table.
    ///
    /// Retry what time or a better connection can change: no answer at all
    /// (`.transport`, or any non-backend error such as a cancelled or timed-out
    /// request), a 5xx, 408 and 429, and 401 (a token the next call refreshes).
    /// Give up on what the server has already answered for good: any other
    /// 4xx (a 403 or a 404 will say the same thing on every pass), and the
    /// two cases that are not about the network at all, `.notConfigured` (there
    /// is no server to ask) and `.decoding` (the server answered, so asking
    /// again cannot change what it said). Without this a permanent refusal was
    /// retried on every dashboard refresh, for the life of the install.
    nonisolated static func shouldKeepRetrying(after error: Error) -> Bool {
        guard let backendError = error as? BackendError else { return true }
        switch backendError {
        case .transport, .unauthorized, .quotaExceeded:
            return true
        case let .http(status):
            return status >= 500 || [401, 408, 429].contains(status)
        case .notConfigured, .decoding:
            return false
        }
    }

    enum Attempt: Equatable {
        case nothingPending
        case superseded
        case alreadyRunning
        case deleted
        /// Failed in a way worth another try; the record stays.
        case failed
        /// Failed in a way no retry will change; the record was dropped.
        case abandoned
    }
}

extension AppState {

    /// One deletion call in flight per process, whoever started it: the
    /// launch pass and the five-minute loop can both reach
    /// `startPendingBackendDeletionRetryIfNeeded()`, and so can a refresh pass
    /// that lands while the disconnect's own first call is still waiting on
    /// the network (`performBackendDeletion` takes the flag too).
    private static var backendDeletionRetryInFlight = false
    /// The retry task `startPendingBackendDeletionRetryIfNeeded` spawned, so a
    /// test can wait for it.
    private static var backendDeletionRetryTask: Task<Void, Never>?

    /// Runs the deletion and keeps the record honest. The record is written
    /// BEFORE the call and cleared only after the server confirms, rather
    /// than written in the `catch`: a request that never returns (airplane
    /// mode, a kill mid-flight, a timeout that outlives the app) has no
    /// `catch` to run in, and "the student asked and nothing confirmed it"
    /// is exactly the state to remember. A failure leaves the record in
    /// place and the course-material cache alone, as it always did, since
    /// wiping ask's memory for a request that never reached the server would
    /// only be half a deletion.
    ///
    /// Never throws and never touches the disconnect itself, which has
    /// already happened by the time this runs.
    ///
    /// `afterConfirmed` is what runs once the server has confirmed; nil means
    /// the real thing, `clearCourseKnowledge()`, which deletes the on-device
    /// course-material file. It is a parameter so a test can drive the success
    /// path without removing a file from the machine it runs on (an unsandboxed
    /// `swift test` resolves that file to the developer's own Application
    /// Support folder).
    func performBackendDeletion(
        defaults: UserDefaults = .lhf,
        afterConfirmed: (() -> Void)? = nil,
        delete: () async throws -> Void
    ) async -> Bool {
        PendingBackendDeletion.setPending(true, in: defaults)
        // Held for the length of this call, so a refresh pass that reaches
        // `retryPendingBackendDeletion` while it is still waiting on the
        // network sees one in flight instead of sending a second
        // `delete-account`. Only released if this call took it: a retry that
        // is already running keeps its own.
        let ownsFlight = !Self.backendDeletionRetryInFlight
        if ownsFlight { Self.backendDeletionRetryInFlight = true }
        defer { if ownsFlight { Self.backendDeletionRetryInFlight = false } }
        do {
            try await delete()
        } catch {
            courseKnowledgeNotice = "couldn't delete your data from lhf's server: \(error.localizedDescription)"
            // An answer no retry will change is not kept for retrying; the
            // record stays only for what time or a connection can fix.
            if !PendingBackendDeletion.shouldKeepRetrying(after: error) {
                PendingBackendDeletion.setPending(false, in: defaults)
            }
            return false
        }
        PendingBackendDeletion.setPending(false, in: defaults)
        if let afterConfirmed { afterConfirmed() } else { clearCourseKnowledge() }
        return true
    }

    /// Fires a retry in the background when one is on record. Cheap enough
    /// for the launch pass and every refresh (one defaults read), and it
    /// spawns its own task, so the dashboard never waits on it. With no
    /// backend configured there is nothing to retry and the record is left
    /// alone.
    ///
    /// **With no backend identity on this phone, the record is dropped and no
    /// call is made.** `delete-account` authenticates as the anonymous
    /// account, and `BackendSession` creates one on the first call that needs
    /// it, so asking to delete an account this phone never had would sign up a
    /// new one only to delete it. The identity is created by the first
    /// backend call (a Penn install's first sync or question); no identity
    /// means there is nothing on the server to delete.
    ///
    /// `defaults`, `hasIdentity`, `afterConfirmed` and `delete` are test
    /// seams; the app passes none of them.
    func startPendingBackendDeletionRetryIfNeeded(
        defaults: UserDefaults = .lhf,
        hasIdentity: () -> Bool = { BackendIdentityStore.load() != nil },
        afterConfirmed: (() -> Void)? = nil,
        delete: (@Sendable () async throws -> Void)? = nil
    ) {
        guard PendingBackendDeletion.isPending(in: defaults) else { return }
        guard hasIdentity() else {
            PendingBackendDeletion.setPending(false, in: defaults)
            return
        }
        let call: @Sendable () async throws -> Void
        if let delete {
            call = delete
        } else if let client = BackendServices.client {
            call = { try await client.deleteAccount() }
        } else {
            return
        }
        Self.backendDeletionRetryTask = Task { [weak self] in
            await self?.retryPendingBackendDeletion(defaults: defaults, afterConfirmed: afterConfirmed, delete: call)
        }
    }

    /// Waits for the retry `startPendingBackendDeletionRetryIfNeeded` started.
    func awaitPendingBackendDeletionRetry() async {
        await Self.backendDeletionRetryTask?.value
    }

    /// The retry itself, with the network call injected so a test can fail
    /// and then succeed it. A failure keeps the record, so the next pass
    /// tries again; there is no backoff beyond the callers' own cadence, and
    /// no cap, because the only alternative to trying again is leaving the
    /// student's rows on the server after they asked for them gone.
    /// `canvasConnected` is a test seam: `isCanvasConnected` reads the saved
    /// feed URL, which a test cannot pin without writing the Keychain.
    /// `afterConfirmed` is the same seam `performBackendDeletion` has.
    @discardableResult
    func retryPendingBackendDeletion(
        defaults: UserDefaults = .lhf,
        canvasConnected: Bool? = nil,
        afterConfirmed: (() -> Void)? = nil,
        delete: () async throws -> Void
    ) async -> PendingBackendDeletion.Attempt {
        guard !Self.backendDeletionRetryInFlight else { return .alreadyRunning }
        switch PendingBackendDeletion.decision(
            pending: PendingBackendDeletion.isPending(in: defaults),
            canvasConnected: canvasConnected ?? isCanvasConnected
        ) {
        case .nothingPending:
            return .nothingPending
        case .dropSuperseded:
            PendingBackendDeletion.setPending(false, in: defaults)
            return .superseded
        case .retry:
            break
        }
        Self.backendDeletionRetryInFlight = true
        defer { Self.backendDeletionRetryInFlight = false }
        do {
            try await delete()
        } catch {
            guard PendingBackendDeletion.shouldKeepRetrying(after: error) else {
                PendingBackendDeletion.setPending(false, in: defaults)
                return .abandoned
            }
            return .failed
        }
        PendingBackendDeletion.setPending(false, in: defaults)
        if let afterConfirmed { afterConfirmed() } else { clearCourseKnowledge() }
        return .deleted
    }
}
