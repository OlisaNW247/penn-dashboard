import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// How a multi-course grade refresh reports itself. The cases that matter are
/// the mixed ones: Grade Watcher fetches each selected class separately, so
/// "one class failed" and "the whole sync failed" are different events that
/// used to produce the same alarming banner — and a 401 on a single course used
/// to be reported as an expired login for all of them.
@MainActor
@Suite("Grade Watcher refresh outcome")
struct GradeWatcherRefreshOutcomeTests {
    private struct Boom: Swift.Error, LocalizedError {
        var errorDescription: String? { "the network went away" }
    }

    private func outcome(
        total: Int,
        succeeded: Int,
        expired: Bool = false,
        failure: Swift.Error? = nil
    ) -> GradeWatcherStore.RefreshOutcome {
        GradeWatcherStore.outcome(
            total: total,
            succeeded: succeeded,
            sawSessionExpired: expired,
            lastFailure: failure
        )
    }

    @Test("every class refreshing is a clean sync")
    func allSucceeded() {
        #expect(outcome(total: 4, succeeded: 4) == .init(isSessionExpired: false, error: nil))
    }

    @Test("a concluded class 401ing is not an expired session when others worked")
    func partialExpiryIsNotASessionExpiry() {
        // The CIS 3200 case: the term just ended, Canvas restricts the API for
        // that course, and the other four classes fetch perfectly well with the
        // same cookies. Claiming the session expired would dim every grade on
        // screen and push a re-login that cannot help.
        let result = outcome(total: 5, succeeded: 4, expired: true)
        #expect(!result.isSessionExpired)
        #expect(result.error?.contains("1 of 5") == true)
        #expect(result.error?.contains("class") == true)
    }

    @Test("a partial failure names the count instead of crying total failure")
    func partialFailureIsSoft() {
        let result = outcome(total: 5, succeeded: 3, failure: Boom())
        #expect(!result.isSessionExpired)
        #expect(result.error?.contains("2 of 5 classes") == true)
        // The blunt old wording must not resurface over cards that just updated.
        #expect(result.error?.contains("sync failed") != true)
    }

    @Test("nothing fetching at all with a 401 really is an expired session")
    func totalExpiry() {
        let result = outcome(total: 3, succeeded: 0, expired: true)
        #expect(result.isSessionExpired)
        #expect(result.error?.contains("session expired") == true)
    }

    @Test("a total non-auth failure reports the underlying reason")
    func totalFailure() {
        let result = outcome(total: 2, succeeded: 0, failure: Boom())
        #expect(!result.isSessionExpired)
        #expect(result.error?.contains("the network went away") == true)
    }

    @Test("a single failing class reads as singular")
    func singularWording() {
        let result = outcome(total: 2, succeeded: 1, failure: Boom())
        #expect(result.error?.contains("1 of 2 class") == true)
        #expect(result.error?.contains("classes") != true)
    }
}
