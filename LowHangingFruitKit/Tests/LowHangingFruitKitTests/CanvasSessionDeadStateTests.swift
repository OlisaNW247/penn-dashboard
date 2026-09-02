import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for the pure decision functions behind the sticky
/// `AppState.canvasSessionConfirmedDead` fix: a Canvas session that dies
/// server-side while a persisted Keychain cookie still looks fresh by
/// `SessionCookieStore.isExpired`'s client-side clock check used to produce
/// no reconnect banner and no recovery path at all, because
/// `canvasSessionExpired` was recomputed ONLY from that client-side check.
/// `confirmedDeadAfterRenewal` and `renewalProvedSessionAlive` are the pure
/// halves of the fix — pulled out specifically so this is testable without
/// constructing an `AppState`, touching WebKit, or touching `UserDefaults`.
@MainActor
@Suite("Canvas session dead state")
struct CanvasSessionDeadStateTests {
    // MARK: - confirmedDeadAfterRenewal(current:outcome:)

    @Test("timedOut confirms the session dead")
    func timedOutConfirmsDead() {
        #expect(AppState.confirmedDeadAfterRenewal(current: false, outcome: .timedOut) == true)
        #expect(AppState.confirmedDeadAfterRenewal(current: true, outcome: .timedOut) == true)
    }

    @Test("landedOnLoginPage confirms the session dead")
    func landedOnLoginPageConfirmsDead() {
        #expect(AppState.confirmedDeadAfterRenewal(current: false, outcome: .landedOnLoginPage) == true)
        #expect(AppState.confirmedDeadAfterRenewal(current: true, outcome: .landedOnLoginPage) == true)
    }

    @Test("renewed clears the confirmed-dead record from either starting state")
    func renewedClearsDead() {
        #expect(AppState.confirmedDeadAfterRenewal(current: true, outcome: .renewed) == false)
        #expect(AppState.confirmedDeadAfterRenewal(current: false, outcome: .renewed) == false)
    }

    @Test("notAttempted proves nothing and leaves current unchanged")
    func notAttemptedLeavesCurrentUnchanged() {
        #expect(AppState.confirmedDeadAfterRenewal(current: true, outcome: .notAttempted(reason: "within the 1h cooldown")) == true)
        #expect(AppState.confirmedDeadAfterRenewal(current: false, outcome: .notAttempted(reason: "within the 1h cooldown")) == false)
    }

    @Test("abortedByLoginPane proves nothing and leaves current unchanged")
    func abortedByLoginPaneLeavesCurrentUnchanged() {
        #expect(AppState.confirmedDeadAfterRenewal(current: true, outcome: .abortedByLoginPane) == true)
        #expect(AppState.confirmedDeadAfterRenewal(current: false, outcome: .abortedByLoginPane) == false)
    }

    // MARK: - renewalProvedSessionAlive(lastRefreshedBefore:lastRefreshedAfter:)

    private let someDate = Date(timeIntervalSince1970: 1_700_000_000)
    private var laterDate: Date { someDate.addingTimeInterval(60) }

    @Test("nil before and after is not proof of a live session")
    func nilToNilIsNotProof() {
        #expect(AppState.renewalProvedSessionAlive(lastRefreshedBefore: nil, lastRefreshedAfter: nil) == false)
    }

    @Test("nil to a date is proof of a live session — a course fetched for the first time")
    func nilToDateIsProof() {
        #expect(AppState.renewalProvedSessionAlive(lastRefreshedBefore: nil, lastRefreshedAfter: someDate) == true)
    }

    @Test("an unchanged date is not proof — nothing actually fetched this refresh")
    func sameDateIsNotProof() {
        #expect(AppState.renewalProvedSessionAlive(lastRefreshedBefore: someDate, lastRefreshedAfter: someDate) == false)
    }

    @Test("an advanced date is proof — a course fetched this refresh")
    func advancedDateIsProof() {
        #expect(AppState.renewalProvedSessionAlive(lastRefreshedBefore: someDate, lastRefreshedAfter: laterDate) == true)
    }
}
