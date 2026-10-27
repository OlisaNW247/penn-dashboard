import Foundation
import LowHangingFruitKit

/// The server half of "disconnect Canvas": `delete-account` removes the
/// student's enrollment and usage rows and their anonymous account from the
/// backend, and a disconnect promises that. The call is a network request, so
/// it can fail offline, and until now a failure was reported once, on a
/// Settings line that told the student to reconnect and disconnect again,
/// while the rows sat on the server indefinitely. This remembers the request
/// until the server confirms it.
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

    enum Attempt: Equatable {
        case nothingPending
        case superseded
        case alreadyRunning
        case deleted
        case failed
    }
}

extension AppState {

    /// One in-flight retry per process: the launch pass and the five-minute
    /// loop can both reach `startPendingBackendDeletionRetryIfNeeded()`.
    private static var backendDeletionRetryInFlight = false

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
        do {
            try await delete()
        } catch {
            courseKnowledgeNotice = "couldn't delete your data from lhf's server: \(error.localizedDescription)"
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
    func startPendingBackendDeletionRetryIfNeeded() {
        guard PendingBackendDeletion.isPending(), let client = BackendServices.client else { return }
        Task { [weak self] in
            await self?.retryPendingBackendDeletion { try await client.deleteAccount() }
        }
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
            return .failed
        }
        PendingBackendDeletion.setPending(false, in: defaults)
        if let afterConfirmed { afterConfirmed() } else { clearCourseKnowledge() }
        return .deleted
    }
}
