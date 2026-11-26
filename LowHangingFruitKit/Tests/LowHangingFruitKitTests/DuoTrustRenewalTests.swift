import Foundation
import Testing
import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Renewing Duo's remembered-device trust before it lapses. The rule is pure
/// (`AppState.shouldRenewDuoTrust`); the forced start URL is the renewer's
/// own pure helper.
@Suite("Duo trust renewal")
struct DuoTrustRenewalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    private func rule(
        trust: TimeInterval? = 4 * 24 * 3600,
        expired: Bool = false,
        awaiting: Bool = false,
        disabled: String? = nil,
        lastAttempt: TimeInterval? = nil,
        lastCredential: TimeInterval? = nil,
        lastFailed: TimeInterval? = nil,
        silent: Bool = true,
        inFlight: Bool = false,
        pane: Bool = false,
        penn: Bool = true
    ) -> Bool {
        AppState.shouldRenewDuoTrust(
            trustExpiry: trust.map { now.addingTimeInterval($0) },
            now: now,
            sessionExpired: expired,
            awaitingDuo: awaiting,
            disabledReason: disabled,
            lastTrustRenewalAttemptAt: lastAttempt.map { now.addingTimeInterval($0) },
            lastCredentialSubmissionAt: lastCredential.map { now.addingTimeInterval($0) },
            lastFailedCredentialSubmissionAt: lastFailed.map { now.addingTimeInterval($0) },
            renewalInFlight: inFlight,
            loginPaneActive: pane,
            isPenn: penn,
            canAutoLoginSilently: silent
        )
    }

    @Test("four days from lapsing, everything healthy: renew")
    func due() { #expect(rule()) }

    @Test("trust already gone or never read: never (it would push for nothing)")
    func trustGone() {
        #expect(!rule(trust: nil))
        #expect(!rule(trust: -60))
        #expect(!rule(trust: 0))
    }

    @Test("trust still far away: not yet")
    func farAway() {
        #expect(!rule(trust: 20 * day))
        #expect(rule(trust: 5 * day))
        #expect(!rule(trust: 5 * day + 1))
    }

    @Test("each guard blocks")
    func guards() {
        #expect(!rule(expired: true))
        #expect(!rule(awaiting: true))
        #expect(!rule(disabled: "rejected"))
        #expect(!rule(inFlight: true))
        #expect(!rule(pane: true))
        #expect(!rule(penn: false))
    }

    @Test("attempts are a week apart, and a clock in the future blocks")
    func spacing() {
        #expect(!rule(lastAttempt: -2 * day))
        #expect(rule(lastAttempt: -8 * day))
        #expect(!rule(lastAttempt: 3600))
    }

    @Test("a password typed minutes ago blocks; ten minutes on does not")
    func credentialSpacing() {
        #expect(!rule(lastCredential: -3 * 60))
        #expect(rule(lastCredential: -11 * 60))
    }

    @Test("a failed password waits an hour: 30 minutes no, 61 minutes yes")
    func failedSpacing() {
        #expect(!rule(lastFailed: -30 * 60))
        #expect(rule(lastFailed: -61 * 60))
    }

    @Test("a due trust still waits on a dead session or a Duo wait; no silent sign-in, no renewal")
    func dueButBlocked() {
        #expect(rule())
        #expect(!rule(expired: true))
        #expect(!rule(awaiting: true))
        #expect(!rule(silent: false))
    }

    private func cookie(_ name: String, daysAhead: Double) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: "x", .domain: ".duosecurity.com", .path: "/",
            .expires: now.addingTimeInterval(daysAhead * day)
        ])!
    }

    @Test("only the remembered-device cookie sets the trust expiry")
    func trustCookieOnly() {
        let jar = [cookie("browsertrust|TESTID", daysAhead: 30), cookie("other|TESTID", daysAhead: 365)]
        #expect(AppState.duoTrustExpiry(cookies: jar, now: now) == now.addingTimeInterval(30 * day))
        #expect(AppState.duoTrustExpiry(cookies: [cookie("other|TESTID", daysAhead: 365)], now: now) == nil)
        let both = [cookie("browsertrust|OLD", daysAhead: -2), cookie("browsertrust|NEW", daysAhead: 12)]
        #expect(AppState.duoTrustExpiry(cookies: both, now: now) == now.addingTimeInterval(12 * day))
    }

    @Test("a forced attempt that reaches Duo or the login page latches nothing")
    @MainActor
    func forcedLatchesNothing() {
        for outcome in [CanvasSessionRenewer.Outcome.needsDuo, .landedOnLoginPage] {
            let state = AppState()
            state.disablePersistenceForTesting()
            let expiredBefore = state.canvasSessionExpired
            let awaitingBefore = state.autoLoginAwaitingDuo
            state.noteRenewalOutcomeForTesting(outcome, forced: true)
            #expect(state.autoLoginAwaitingDuo == awaitingBefore)
            #expect(state.canvasSessionExpired == expiredBefore)
            #expect(!state.backgroundDuoStandDown)
            #expect(state.silentRenewalConsecutiveLandings == 0)
            #expect(state.credentiallessLandings == 0)
            #expect(state.lastSilentRenewalAttemptOutcome == nil)
            #expect(state.lastSilentRenewalSummary != nil)
        }
    }

    @Test("a forced start the gate refuses leaves the attempt key unset")
    @MainActor
    func refusedStartLeavesKey() async {
        UserDefaults.lhf.removeObject(forKey: AppState.duoTrustRenewalAttemptAtKey)
        let state = AppState()
        state.disablePersistenceForTesting()
        state.startSilentCanvasRenewal(forceReauthentication: true)
        await state.awaitPendingSilentRenewal()
        #expect(UserDefaults.lhf.object(forKey: AppState.duoTrustRenewalAttemptAtKey) == nil)
    }

    @Test("a forced attempt never spends the once-per-open Duo retry grant")
    func forcedKeepsGrant() throws {
        let code = try HardeningSourceScan.uiCode("AppState.swift")
        #expect(code.contains("if isForegroundAttempt && !forceReauthentication { madeForegroundRenewalThisProcess = true }"))
    }

    @Test("the forced start URL carries force_login=1, the plain one is the origin")
    func startURL() {
        let penn = CanvasInstallation.penn
        let plain = CanvasSessionRenewer.startURL(for: penn, forceReauthentication: false)
        #expect(plain == penn.baseURL)
        let forced = CanvasSessionRenewer.startURL(for: penn, forceReauthentication: true)
        let comps = URLComponents(url: forced, resolvingAgainstBaseURL: false)
        #expect(comps?.host == "canvas.upenn.edu")
        #expect(comps?.path == "/login/saml")
        #expect(comps?.queryItems?.filter { $0.name == "force_login" }.map(\.value) == ["1"])
        #expect(!(plain.query ?? "").contains("force_login"))
    }

    @Test("the dashboard refresh asks for the renewal right after the ordinary retry")
    func wiring() throws {
        let code = try HardeningSourceScan.uiCode("ContentView.swift")
        let retry = try #require(code.range(of: "state.retrySilentRenewalIfDue()"))
        let renew = try #require(code.range(of: "state.renewDuoTrustIfDue()"))
        #expect(retry.upperBound <= renew.lowerBound)
        let app = try HardeningSourceScan.uiCode("AppState.swift")
        #expect(app.contains("startSilentCanvasRenewal(forceReauthentication: true)"))
        #expect(app.contains("duoTrustRenewalAttemptAtV1"))
        #expect(app.contains("-LHFRenewDuoTrustNow"))
        #expect(app.contains("defaults.removeObject(forKey: Self.duoTrustRenewalAttemptAtKey)"))
    }
}
