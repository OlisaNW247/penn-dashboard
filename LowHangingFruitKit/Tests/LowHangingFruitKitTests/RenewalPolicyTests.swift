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

    private let spacing = CanvasSessionRenewer.foregroundSpacing

    private func retry(
        expired: Bool = true,
        awaitingDuo: Bool = false,
        disabledReason: String? = nil,
        lastAttemptAgo: TimeInterval? = nil
    ) -> Bool {
        AppState.shouldRetrySilentRenewal(
            expired: expired,
            awaitingDuo: awaitingDuo,
            disabledReason: disabledReason,
            lastAttemptAt: lastAttemptAgo.map { now.addingTimeInterval(-$0) },
            now: now
        )
    }

    @Test("a live session is never retried")
    func liveSessionNotRetried() {
        #expect(retry(expired: false, lastAttemptAgo: 10 * hour) == false)
    }

    @Test("awaiting Duo is never retried: it would push Duo to the phone")
    func awaitingDuoNotRetried() {
        #expect(retry(awaitingDuo: true, lastAttemptAgo: 10 * hour) == false)
        #expect(retry(awaitingDuo: true, lastAttemptAgo: nil) == false)
    }

    @Test("a disabled reason (rejected password) is never retried")
    func disabledReasonNotRetried() {
        #expect(retry(disabledReason: "rejected", lastAttemptAgo: 10 * hour) == false)
    }

    @Test("the foreground spacing is 90 seconds, not an hour")
    func spacingWindow() {
        #expect(spacing == 90)
        #expect(retry(lastAttemptAgo: spacing - 1) == false)
        #expect(retry(lastAttemptAgo: spacing) == true)
        #expect(retry(lastAttemptAgo: spacing + 1) == true)
        // An attempt five minutes ago (yesterday's one-hour lock-out) no longer matters.
        #expect(retry(lastAttemptAgo: 5 * 60) == true)
    }

    @Test("no attempt on record means due")
    func neverAttemptedIsDue() {
        #expect(retry(lastAttemptAgo: nil) == true)
    }

    @Test("awaiting Duo retries only when the pure rule allows it")
    func awaitingDuoRetryRule() {
        func allowed(_ agoMinutes: Double?, thisProcess: Bool) -> Bool {
            AppState.awaitingDuoRetryAllowed(
                latchedAt: agoMinutes.map { now.addingTimeInterval(-$0 * 60) },
                now: now, madeForegroundAttemptThisProcess: thisProcess)
        }
        // One try per cold open, however fresh the latch.
        #expect(allowed(1, thisProcess: false))
        #expect(!allowed(1, thisProcess: true))
        // After 60 minutes, any time.
        #expect(!allowed(59, thisProcess: true))
        #expect(allowed(60, thisProcess: true))
        // A latch from an older build has no date: old enough.
        #expect(allowed(nil, thisProcess: true))
        // And the policy honours it, with every other stop still in force.
        func policy(duoRetry: Bool, disabled: String? = nil, ago: TimeInterval? = nil) -> Bool {
            AppState.shouldRetrySilentRenewal(
                expired: true, awaitingDuo: true, disabledReason: disabled,
                lastAttemptAt: ago.map { now.addingTimeInterval(-$0) }, now: now, duoRetryAllowed: duoRetry)
        }
        #expect(policy(duoRetry: true))
        #expect(!policy(duoRetry: false))
        #expect(!policy(duoRetry: true, disabled: "rejected"))
        #expect(!policy(duoRetry: true, ago: 30))
    }

    @Test("a bare clock expiry retries: no latched verdict or landing is required any more")
    func bareExpiryRetries() {
        #expect(retry(expired: true, lastAttemptAgo: 10 * hour) == true)
    }

    @Test("a last attempt in the future (clock change) is not due")
    func futureAttemptNotDue() {
        #expect(retry(lastAttemptAgo: -600) == false)
    }

    // MARK: - backgroundMayUseCredentials

    private func mayUse(duoStandDown: Bool, submittedHoursAgo: Double?) -> Bool {
        AppState.backgroundMayUseCredentials(
            duoStandDown: duoStandDown,
            lastCredentialSubmissionAt: submittedHoursAgo.map { now.addingTimeInterval(-$0 * hour) },
            now: now
        )
    }

    @Test("once Duo has asked, the background never offers the password, however old the submission")
    func backgroundStandsDownAfterDuo() {
        #expect(mayUse(duoStandDown: true, submittedHoursAgo: nil) == false)
        #expect(mayUse(duoStandDown: true, submittedHoursAgo: 100) == false)
    }

    @Test("within six hours of the last credential submission the background does not resubmit")
    func backgroundHonoursSixHourClock() {
        #expect(mayUse(duoStandDown: false, submittedHoursAgo: 5) == false)
        #expect(mayUse(duoStandDown: false, submittedHoursAgo: 0.1) == false)
        #expect(mayUse(duoStandDown: false, submittedHoursAgo: 7) == true)
    }

    @Test("no history means the background may use the credentials")
    func backgroundWithNoHistory() {
        #expect(mayUse(duoStandDown: false, submittedHoursAgo: nil) == true)
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
