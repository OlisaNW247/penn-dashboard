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
        // The whole message is the tally -- there is no noun left to assert
        // on, so the exact string is the specific expectation.
        #expect(result.error == "couldn\u{2019}t refresh 1 of 5")
    }

    @Test("a partial failure names the count instead of crying total failure")
    func partialFailureIsSoft() {
        let result = outcome(total: 5, succeeded: 3, failure: Boom())
        #expect(!result.isSessionExpired)
        #expect(result.error == "couldn\u{2019}t refresh 2 of 5")
        // The blunt old wording must not resurface over cards that just updated.
        #expect(result.error?.contains("sync failed") != true)
    }

    @Test("nothing fetching at all with a 401 really is an expired session")
    func totalExpiry() {
        let result = outcome(total: 3, succeeded: 0, expired: true)
        #expect(result.isSessionExpired)
        #expect(result.error?.contains("session expired") == true)
    }

    @Test("a total non-auth failure says so in plain words and never prints the system error")
    func totalFailure() {
        let result = outcome(total: 2, succeeded: 0, failure: Boom())
        #expect(!result.isSessionExpired)
        #expect(result.error == "couldn\u{2019}t load grades")
        // This used to assert the opposite (the underlying reason was
        // appended). `localizedDescription` is system text a student cannot
        // act on, so it must not reach the screen.
        #expect(result.error?.contains("the network went away") != true)
        #expect(result.error?.contains("sync failed") != true)
    }

    @Test("a total failure with no error at all reads the same")
    func totalFailureWithoutAnError() {
        let result = outcome(total: 2, succeeded: 0, failure: nil)
        #expect(!result.isSessionExpired)
        #expect(result.error == "couldn\u{2019}t load grades")
        #expect(result.error?.contains("unknown error") != true)
    }

    // Replaces `singularWording`, whose whole purpose was that "1 of 2 class"
    // never read "1 of 2 classes". The message no longer carries a noun, so
    // that distinction cannot go wrong; what the shorter copy guarantees is
    // that it is exactly the tally for every count and names nothing else.
    @Test("a partial failure is exactly the tally for any count, with no noun")
    func tallyHasNoNoun() {
        for (total, succeeded) in [(2, 1), (5, 4), (5, 3), (9, 1)] {
            let failed = total - succeeded
            let result = outcome(total: total, succeeded: succeeded, failure: Boom())
            #expect(result.error == "couldn\u{2019}t refresh \(failed) of \(total)")
            #expect(result.error?.contains("class") != true)
            #expect(result.error?.contains("last grades") != true)
        }
    }

    @Test("no Canvas session at all tells the student to reconnect, in four words")
    func noSavedSessionMessage() async {
        let store = GradeWatcherStore(historyStore: nil)
        await store.refresh(courseIDs: ["1": "PHYS 0151"], cookies: [])
        #expect(store.error == "reconnect canvas for grades")
        #expect(!store.isSessionExpired)
        #expect(!store.isRefreshing)
    }
}
