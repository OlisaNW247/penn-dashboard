import Foundation
import LowHangingFruitKit
#if os(iOS)
import UIKit
#endif

// MARK: – The Sweeper's server wake, phone side
//
// What this file does: tells the `sweeper-wake` function a device token, the
// whole-minute instants at which a silent push should knock (15 and 3 minutes
// before each armed ring), and a hash of that list, so the phone can run its
// own Canvas read at those times (`LHFBackgroundRefresh.runWake(.push)`).
//
// Marco's rule (2026-11-18): the alarm stays armed; the push only adds a time
// at which the phone's own read runs; only a confirmed `.submitted` read
// cancels. So a send that fails, a push that never comes or a token Apple
// refuses costs nothing but the extra read. Nothing here arms, disarms or
// edits the plan, and nothing here is reachable from a background wake: the
// pass is foreground only, called from `ContentView.settleAfterFetch`.
//
// Privacy: what leaves is a device token, the sandbox/production word, a list
// of instants and a 16-character hash. No assignment id, title, class, URL,
// grade, name or cookie (`docs/PRIVACY.md`). The token is never logged,
// printed or put in an error, and `SweeperWakeClient`'s body has exactly five
// keys, pinned by a test.

/// The yes/no decisions of the wake, pure and `nonisolated` so a test can walk
/// them without an `AppState` (CLAUDE.md, the `decidedText` trap).
enum SweeperWakeRules {
    /// At most one send per this long unless the plan or the token changed.
    nonisolated static let throttle: TimeInterval = 600

    /// A changed list sends at once; an unchanged one is re-sent only after
    /// the throttle, which refreshes a server row that expired or was lost.
    /// A clock that moved back does not freeze the pass.
    nonisolated static func shouldSend(
        now: Date, lastSent: Date?, planHash: String, lastHash: String?,
        throttle: TimeInterval = SweeperWakeRules.throttle
    ) -> Bool {
        guard let lastSent, let lastHash else { return true }
        if planHash != lastHash { return true }
        return now < lastSent || now.timeIntervalSince(lastSent) >= throttle
    }

    /// Every gate of a send. Foreground only, never fixture data, never
    /// without the flag, a token, reminders on and the Sweeper on, and only
    /// where the backend's shared tables apply (a Penn install past
    /// onboarding with a backend configured).
    nonisolated static func gatesPass(
        hasBackend: Bool, pastOnboarding: Bool, isPenn: Bool, flag: Bool,
        remindersOn: Bool, sweeperOn: Bool, hasToken: Bool, fixture: Bool, foreground: Bool
    ) -> Bool {
        hasBackend && pastOnboarding && isPenn && flag && remindersOn && sweeperOn
            && hasToken && !fixture && foreground
    }

    /// Whether the server should be told to forget this phone: it was sent a
    /// list once, the install is otherwise able to talk to it, and a switch
    /// the list depends on is now off.
    nonisolated static func shouldWithdraw(everSent: Bool, installOK: Bool, remindersOn: Bool, sweeperOn: Bool) -> Bool {
        everSent && installOK && (!remindersOn || !sweeperOn)
    }
}

extension AppState {
    nonisolated static let sweeperWakeTokenKey = "sweeperWakeTokenV1"
    nonisolated static let sweeperWakeEverSentKey = "sweeperWakeEverSentV1"

    // MARK: Availability

    /// The install facts, apart from the flag and the student's switches:
    /// a backend, past onboarding, Penn. The same three `canSyncWithLaptop`
    /// reads, without its fixture clause (a gate of its own below).
    private var sweeperWakeInstallFacts: (hasBackend: Bool, pastOnboarding: Bool, isPenn: Bool) {
        if let forced = sweeperWakeAvailabilityForTesting { return (forced, forced, forced) }
        return (BackendServices.client != nil, !needsOnboarding,
                canvasInstallation.id == CanvasInstallation.penn.id)
    }

    /// Whether this install may use the server wake at all.
    var canUseSweeperWake: Bool {
        let facts = sweeperWakeInstallFacts
        return FeatureFlags.sweeperWake && facts.hasBackend && facts.pastOnboarding && facts.isPenn
            && !isUsingFixtureData
    }

    // MARK: The device token

    /// The token iOS handed over, lowercase hex. Kept in memory and in
    /// `UserDefaults.lhf` (not the Keychain: it is not a credential, only an
    /// address Apple rotates). A changed token clears the last-sent hash so
    /// the next pass sends even inside the throttle. Anything that is not hex
    /// is ignored.
    func noteDeviceToken(_ hex: String) {
        let token = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }) else { return }
        let changed = token != loadedSweeperWakeToken()
        sweeperWakeToken = token
        sweeperWakeDefaults.set(token, forKey: Self.sweeperWakeTokenKey)
        if changed { lastSweeperWakePlanHash = nil }
    }

    /// iOS refused to register (no `aps-environment` entitlement yet, no
    /// network, a simulator). Counted, never described: the error can carry
    /// text nobody needs on a student's phone.
    func noteDeviceTokenRegistrationFailed() {
        SweeperCounts.increment(SweeperCounts.registerFailed, defaults: sweeperCountsDefaults)
        #if DEBUG
        DebugWakeLog.record(source: .foreground, outcome: "register-failed", duration: 0,
                            cancelledRequests: 0, cancelledAlarms: 0, defaults: sweeperWakeDefaults)
        #endif
    }

    private func loadedSweeperWakeToken() -> String? {
        sweeperWakeToken ?? sweeperWakeDefaults.string(forKey: Self.sweeperWakeTokenKey)
    }

    // MARK: The pass

    private var sweeperWakeTransport: SweeperWakeTransport? {
        if let seam = sweeperWakeTransportForTesting { return seam }
        guard let backend = BackendServices.client else { return nil }
        return .live(SweeperWakeClient(client: backend))
    }

    /// One send of the plan to the server. Foreground only; every failure is
    /// silent (counted). An empty plan is still a `put`, so the server's row
    /// empties when nothing is armed or every class is excluded.
    func sweeperWakePass(plan: [PlannedAlarm], remindersOn: Bool, sweeperOn: Bool,
                         force: Bool = false, now: Date = Date()) async {
        guard renewalContext == .foreground, !isSweeperWakeRunning else { return }
        // The force-quit check's handoff (`AppState+SweepHandoff.swift`) runs
        // before the server-wake flag guard below: folding the inbox has
        // nothing to do with whether the wake push is enabled. The cookie copy
        // is another matter: it is kept only while a push can actually reach
        // this phone, which is exactly when the wake's own gates pass, so the
        // handoff is told that answer and deletes the copy otherwise.
        let facts = sweeperWakeInstallFacts
        let token = loadedSweeperWakeToken()
        let reachable = SweeperWakeRules.gatesPass(
            hasBackend: facts.hasBackend, pastOnboarding: facts.pastOnboarding, isPenn: facts.isPenn,
            flag: FeatureFlags.sweeperWake, remindersOn: remindersOn, sweeperOn: sweeperOn,
            hasToken: token != nil, fixture: isUsingFixtureData, foreground: renewalContext == .foreground)
        foldSweepInbox(now: now)
        await writeSweepHandoff(plan: plan, wakeReachable: reachable, now: now)
        let everSent = sweeperWakeDefaults.bool(forKey: Self.sweeperWakeEverSentKey)

        // A build with the flag off cleans up after an earlier one.
        guard FeatureFlags.sweeperWake else {
            if everSent { await deleteSweeperWake() }
            return
        }
        let installOK = facts.hasBackend && facts.pastOnboarding && facts.isPenn && !isUsingFixtureData
        if SweeperWakeRules.shouldWithdraw(everSent: everSent, installOK: installOK,
                                           remindersOn: remindersOn, sweeperOn: sweeperOn) {
            await deleteSweeperWake()
            return
        }
        guard reachable, let token, let transport = sweeperWakeTransport
        else { return }

        let moments = SweeperWakePlan.moments(fromFireDates: plan.map(\.fireDate), now: now)
        let hash = SweeperWakePlan.planHash(moments)
        guard force || SweeperWakeRules.shouldSend(now: now, lastSent: lastSweeperWakeSentAt,
                                                   planHash: hash, lastHash: lastSweeperWakePlanHash)
        else { return }

        isSweeperWakeRunning = true
        defer { isSweeperWakeRunning = false }
        do {
            _ = try await transport.put(token, SweeperWakeClient.currentEnvironment, moments, hash)
            lastSweeperWakeSentAt = now
            lastSweeperWakePlanHash = hash
            sweeperWakeDefaults.set(true, forKey: Self.sweeperWakeEverSentKey)
            SweeperCounts.increment(SweeperCounts.momentsSent, by: moments.count, defaults: sweeperCountsDefaults)
        } catch {
            SweeperCounts.increment(SweeperCounts.putFailed, defaults: sweeperCountsDefaults)
        }
    }

    // MARK: Taking it back

    /// Asks the server to forget this phone's token and moments. Best effort:
    /// a failure leaves `sweeperWakeEverSentV1` set so the next foreground
    /// tries again. The in-memory token stays (it is still this phone's).
    func deleteSweeperWake() async {
        lastSweeperWakePlanHash = nil
        lastSweeperWakeSentAt = nil
        guard let transport = sweeperWakeTransport else { return }
        do {
            _ = try await transport.delete()
            sweeperWakeDefaults.removeObject(forKey: Self.sweeperWakeEverSentKey)
        } catch {
            SweeperCounts.increment(SweeperCounts.putFailed, defaults: sweeperCountsDefaults)
        }
    }

    /// The delete the switches and the disconnect use: only when a list was
    /// ever sent, so a phone that never used the wake makes no request (and
    /// never wakes the anonymous account for it).
    func withdrawSweeperWakeIfSent() async {
        guard sweeperWakeDefaults.bool(forKey: Self.sweeperWakeEverSentKey) else { return }
        await deleteSweeperWake()
    }
}

// MARK: – What the App target and the view layer call

/// The one-line entry points: the app delegate (App target, which can see
/// only public API) and `ContentView`.
public enum LHFSweeperWake {
    /// A device token from `didRegisterForRemoteNotificationsWithDeviceToken`.
    /// Goes to the live `AppState`; with none (a launch made by the system for
    /// the push alone, before a scene exists) it is written to the defaults so
    /// the next launch has it.
    @MainActor
    public static func noteDeviceToken(_ hex: String) {
        if let state = LiveAppStateRegistry.shared.current {
            state.noteDeviceToken(hex)
        } else {
            let token = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }) else { return }
            UserDefaults.lhf.set(token, forKey: AppState.sweeperWakeTokenKey)
        }
    }

    /// `didFailToRegisterForRemoteNotificationsWithError`: a count and one
    /// DEBUG line, never the error.
    @MainActor
    public static func noteRegistrationFailed() {
        if let state = LiveAppStateRegistry.shared.current {
            state.noteDeviceTokenRegistrationFailed()
        } else {
            SweeperCounts.increment(SweeperCounts.registerFailed)
        }
    }
}

/// Asks iOS for a device token at a foreground that qualifies. A silent push
/// needs no permission, so this never prompts. Not called from a background
/// wake.
@MainActor
enum SweeperWakeRegistrar {
    static func shouldRegister(state: AppState, scheduler: NotificationScheduler) -> Bool {
        state.renewalContext == .foreground && state.canUseSweeperWake
            && scheduler.isEnabled && scheduler.loudAlertEnabled
    }

    static func registerIfNeeded(state: AppState, scheduler: NotificationScheduler) {
        #if os(iOS)
        guard shouldRegister(state: state, scheduler: scheduler) else { return }
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
}
