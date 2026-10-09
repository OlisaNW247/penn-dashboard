import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The pure policy behind silent Canvas renewal after the 2026-10-09 sign-out
/// investigation (docs/SIGNOUT_INVESTIGATION.md, H2 and H3): which outcomes
/// may latch the session dead in which context, when a foreground refresh
/// should try again, and what the secret-free summary line looks like.
///
/// Deliberately NOT `@MainActor`. Every function under test is `nonisolated`
/// on purpose (CLAUDE.md, the `decidedText` trap), and a nonisolated suite
/// calling them is the compile-time proof they really are: marking the suite
/// would hide a regression. No `AppState` is constructed, so nothing here
/// touches the Keychain or `UserDefaults.lhf`.
@Suite("Silent renewal policy")
struct RenewalPolicyTests {
    private typealias Outcome = CanvasSessionRenewer.Outcome

    private func dead(
        _ outcome: Outcome,
        _ context: AppState.RenewalContext,
        current: Bool,
        priorLandings: Int = 0
    ) -> Bool {
        AppState.confirmedDeadAfterRenewal(
            current: current,
            outcome: outcome,
            context: context,
            priorConsecutiveLandings: priorLandings
        )
    }

    // MARK: - confirmedDeadAfterRenewal: context x outcome

    @Test("background: nothing latches except a rejected password; a renewal still clears")
    func backgroundNeverLatches() {
        for current in [false, true] {
            #expect(dead(.needsDuo, .background, current: current) == current)
            #expect(dead(.timedOut, .background, current: current) == current)
            #expect(dead(.landedOnLoginPage, .background, current: current) == current)
            // Even a second landing in a row is weak evidence in the background.
            #expect(dead(.landedOnLoginPage, .background, current: current, priorLandings: 5) == current)
            #expect(dead(.notAttempted(reason: "x"), .background, current: current) == current)
            #expect(dead(.abortedByLoginPane, .background, current: current) == current)
            #expect(dead(.renewed, .background, current: current) == false)
            #expect(dead(.passwordRejected, .background, current: current) == true)
        }
    }

    @Test("foreground: timedOut is unknown and never latches")
    func foregroundTimedOutNeverLatches() {
        #expect(dead(.timedOut, .foreground, current: false) == false)
        #expect(dead(.timedOut, .foreground, current: false, priorLandings: 3) == false)
        // It does not un-latch an existing record either.
        #expect(dead(.timedOut, .foreground, current: true) == true)
    }

    @Test("foreground: landedOnLoginPage latches only on the second consecutive landing")
    func foregroundLandingLatchesOnSecond() {
        #expect(dead(.landedOnLoginPage, .foreground, current: false, priorLandings: 0) == false)
        #expect(dead(.landedOnLoginPage, .foreground, current: false, priorLandings: 1) == true)
        #expect(dead(.landedOnLoginPage, .foreground, current: false, priorLandings: 2) == true)
    }

    @Test("foreground: needsDuo, passwordRejected latch; renewed clears; no-ops pass through")
    func foregroundOtherOutcomes() {
        for current in [false, true] {
            #expect(dead(.needsDuo, .foreground, current: current) == true)
            #expect(dead(.passwordRejected, .foreground, current: current) == true)
            #expect(dead(.renewed, .foreground, current: current) == false)
            #expect(dead(.notAttempted(reason: "x"), .foreground, current: current) == current)
            #expect(dead(.abortedByLoginPane, .foreground, current: current) == current)
        }
    }

    // MARK: - shouldRetrySilentRenewal

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 3600

    private func retry(
        confirmedDead: Bool = true,
        awaitingDuo: Bool = false,
        disabledReason: String? = nil,
        lastAttemptAgo: TimeInterval? = nil,
        lastOutcome: AppState.RenewalOutcomeKind? = nil
    ) -> Bool {
        AppState.shouldRetrySilentRenewal(
            confirmedDead: confirmedDead,
            awaitingDuo: awaitingDuo,
            disabledReason: disabledReason,
            lastAttemptAt: lastAttemptAgo.map { now.addingTimeInterval(-$0) },
            lastOutcome: lastOutcome,
            now: now,
            cooldown: hour
        )
    }

    @Test("a live session is never retried")
    func liveSessionNotRetried() {
        #expect(retry(confirmedDead: false, lastAttemptAgo: 10 * hour) == false)
    }

    @Test("awaiting Duo is never retried: it would push Duo to the phone")
    func awaitingDuoNotRetried() {
        #expect(retry(awaitingDuo: true, lastAttemptAgo: 10 * hour, lastOutcome: .needsDuo) == false)
        #expect(retry(awaitingDuo: true, lastAttemptAgo: nil) == false)
    }

    @Test("a disabled reason (rejected password) is never retried")
    func disabledReasonNotRetried() {
        #expect(retry(disabledReason: "rejected", lastAttemptAgo: 10 * hour) == false)
    }

    @Test("within the cooldown is not retried; past it is")
    func cooldownWindow() {
        #expect(retry(lastAttemptAgo: hour - 1, lastOutcome: .landedOnLoginPage) == false)
        #expect(retry(lastAttemptAgo: hour, lastOutcome: .landedOnLoginPage) == true)
        #expect(retry(lastAttemptAgo: hour + 1, lastOutcome: .landedOnLoginPage) == true)
    }

    @Test("no attempt on record means due")
    func neverAttemptedIsDue() {
        #expect(retry(lastAttemptAgo: nil) == true)
    }

    @Test("after a timeout the retry comes at 10 minutes, not an hour")
    func timedOutRetriesSooner() {
        #expect(retry(lastAttemptAgo: 5 * 60, lastOutcome: .timedOut) == false)
        #expect(retry(lastAttemptAgo: 10 * 60, lastOutcome: .timedOut) == true)
        #expect(retry(lastAttemptAgo: 11 * 60, lastOutcome: .timedOut) == true)
        // The shorter interval belongs to timeouts only.
        #expect(retry(lastAttemptAgo: 11 * 60, lastOutcome: .landedOnLoginPage) == false)
    }

    @Test("a first landing on the login form is retried even though the session is not yet latched dead")
    func landedOutcomeRetriesWithoutLatch() {
        #expect(retry(confirmedDead: false, lastAttemptAgo: hour - 1, lastOutcome: .landedOnLoginPage) == false)
        #expect(retry(confirmedDead: false, lastAttemptAgo: hour, lastOutcome: .landedOnLoginPage) == true)
        // The hard stops still win.
        #expect(retry(confirmedDead: false, awaitingDuo: true, lastAttemptAgo: 10 * hour, lastOutcome: .landedOnLoginPage) == false)
        #expect(retry(confirmedDead: false, disabledReason: "rejected", lastAttemptAgo: 10 * hour, lastOutcome: .landedOnLoginPage) == false)
        // Only a landing opens this door: a timeout or a renewal with a live session does not.
        #expect(retry(confirmedDead: false, lastAttemptAgo: 10 * hour, lastOutcome: .timedOut) == false)
        #expect(retry(confirmedDead: false, lastAttemptAgo: 10 * hour, lastOutcome: .renewed) == false)
    }

    @Test("a last attempt in the future (clock change) is not due")
    func futureAttemptNotDue() {
        #expect(retry(lastAttemptAgo: -600, lastOutcome: .timedOut) == false)
    }

    // MARK: - backgroundMayUseCredentials

    private func mayUse(_ outcome: AppState.RenewalOutcomeKind?, submittedHoursAgo: Double?) -> Bool {
        AppState.backgroundMayUseCredentials(
            lastOutcome: outcome,
            lastCredentialSubmissionAt: submittedHoursAgo.map { now.addingTimeInterval(-$0 * hour) },
            now: now
        )
    }

    @Test("once Duo has asked, the background never offers the password, however old the submission")
    func backgroundStandsDownAfterDuo() {
        #expect(mayUse(.needsDuo, submittedHoursAgo: nil) == false)
        #expect(mayUse(.needsDuo, submittedHoursAgo: 100) == false)
    }

    @Test("within six hours of the last credential submission the background does not resubmit")
    func backgroundHonoursSixHourClock() {
        #expect(mayUse(.renewed, submittedHoursAgo: 5) == false)
        #expect(mayUse(nil, submittedHoursAgo: 0.1) == false)
        #expect(mayUse(.renewed, submittedHoursAgo: 7) == true)
    }

    @Test("no history means the background may use the credentials")
    func backgroundWithNoHistory() {
        #expect(mayUse(nil, submittedHoursAgo: nil) == true)
        #expect(mayUse(.timedOut, submittedHoursAgo: nil) == true)
    }

    // MARK: - summary

    @Test("summary has outcome, minute-resolution time and context, and nothing URL-like")
    func summaryFormat() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        // 1_700_000_000 is 2023-11-14 22:13:20 UTC.
        let line = AppState.renewalSummary(kind: .needsDuo, at: now, context: .foreground, timeZone: utc)
        #expect(line == "needsDuo \u{00B7} 2023-11-14 22:13 \u{00B7} foreground")

        let kinds: [AppState.RenewalOutcomeKind] = [
            .renewed, .needsDuo, .timedOut, .landedOnLoginPage,
            .passwordRejected, .notAttempted, .abortedByLoginPane,
        ]
        for kind in kinds {
            for context in [AppState.RenewalContext.foreground, .background] {
                let text = AppState.renewalSummary(kind: kind, at: now, context: context, timeZone: utc)
                #expect(text.contains(kind.rawValue))
                #expect(text.hasSuffix(context.rawValue))
                #expect(!text.contains("http"))
                #expect(AppState.renewalOutcomeKind(fromSummary: text) == kind)
            }
        }
    }

    @Test("a summary that is not ours parses to nil")
    func unknownSummaryParsesToNil() {
        #expect(AppState.renewalOutcomeKind(fromSummary: "") == nil)
        #expect(AppState.renewalOutcomeKind(fromSummary: "weird \u{00B7} x \u{00B7} y") == nil)
    }

    @Test("every renewer outcome maps to a kind with the same name")
    func outcomeKindMapping() {
        #expect(AppState.renewalOutcomeKind(.renewed) == .renewed)
        #expect(AppState.renewalOutcomeKind(.needsDuo) == .needsDuo)
        #expect(AppState.renewalOutcomeKind(.timedOut) == .timedOut)
        #expect(AppState.renewalOutcomeKind(.landedOnLoginPage) == .landedOnLoginPage)
        #expect(AppState.renewalOutcomeKind(.passwordRejected) == .passwordRejected)
        #expect(AppState.renewalOutcomeKind(.abortedByLoginPane) == .abortedByLoginPane)
        #expect(AppState.renewalOutcomeKind(.notAttempted(reason: "x")) == .notAttempted)
    }
}
