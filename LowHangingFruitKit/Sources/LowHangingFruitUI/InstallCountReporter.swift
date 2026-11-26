import Foundation
import LowHangingFruitKit

/// Sends the one anonymous install count (`InstallCountRule`): the school's
/// Canvas host and `new` / `existing`, once per install, after the student has
/// really connected Canvas. It goes to the ambassador server's `/api/install`
/// (the same origin `AmbassadorClient` uses) with a content type and nothing
/// else: no id, no name, no version, no account.
///
/// It is called only from the foreground root view (`RootCore`), never from
/// `BackgroundRefresh.swift`: a background wake runs with no dashboard and no
/// update-wall verdict, and a count sent from there could come from a build
/// that is not allowed to run.
///
/// **One count per install, for the school first connected.** Disconnecting
/// Canvas or switching school deliberately does not clear the three keys
/// below. The wrong fix is re-reporting on a switch: one student would become
/// two, and the number is meant to be students.
///
/// It never throws to a caller, never shows anything and never waits on the
/// UI: a failure is only "try again after six hours" or, for a 400, "never".
@MainActor
final class InstallCountReporter {
    static let shared = InstallCountReporter()

    static let reportedKey = "installCountReportedV1"
    static let lastAttemptKey = "installCountLastAttemptAtV1"
    static let onboardedBeforeKey = "installCountOnboardedBeforeV1"

    private let baseURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private var inFlight = false

    init(baseURL: URL = AmbassadorClient.defaultBaseURL,
         session: URLSession = .shared,
         defaults: UserDefaults = .lhf) {
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
    }

    /// Writes `installCountOnboardedBeforeV1` once, at the first launch of a
    /// build that has this code: true when onboarding was already complete at
    /// that moment (an update on an existing install), false otherwise (a
    /// fresh sign-up). Later calls change nothing, because "onboarding is
    /// complete" proves an install pre-dates the build only at that one
    /// moment (the `signupBacklogSeenV1` reasoning). Call it before anything
    /// that waits on the network.
    func recordFirstLaunch(onboardingComplete: Bool) {
        guard defaults.object(forKey: Self.onboardedBeforeKey) == nil else { return }
        defaults.set(onboardingComplete, forKey: Self.onboardedBeforeKey)
    }

    /// Sends the count if the rule allows it. The inputs are passed in so a
    /// test can drive every blocker; the production call site fills them from
    /// `AppState`.
    func reportIfDue(
        featureEnabled: Bool = FeatureFlags.installCount,
        onboardingComplete: Bool,
        canvasConnected: Bool,
        usingFixtureData: Bool,
        isTestRunner: Bool = SharedDefaults.isTestRunner,
        host: String?,
        now: Date = Date()
    ) async {
        guard !inFlight else { return }
        let cleanHost = InstallCountRule.normalizedHost(host)
        let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
        guard InstallCountRule.shouldAttempt(
            featureEnabled: featureEnabled,
            onboardingComplete: onboardingComplete,
            canvasConnected: canvasConnected,
            usingFixtureData: usingFixtureData,
            isTestRunner: isTestRunner,
            alreadyReported: defaults.bool(forKey: Self.reportedKey),
            host: cleanHost,
            lastAttempt: lastAttempt,
            now: now
        ), let cleanHost else { return }

        inFlight = true
        defer { inFlight = false }
        // Stamped before the request so a crash or a kill mid-flight still
        // waits out the interval instead of retrying at the next launch.
        defaults.set(now, forKey: Self.lastAttemptKey)

        let kind = InstallCountRule.kind(
            onboardedBeforeThisBuild: defaults.bool(forKey: Self.onboardedBeforeKey))
        var request = URLRequest(url: baseURL.appendingPathComponent("api/install"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = InstallCountRule.body(host: cleanHost, kind: kind)

        var status: Int?
        do {
            let (_, response) = try await session.data(for: request)
            status = (response as? HTTPURLResponse)?.statusCode
        } catch {
            status = nil
        }
        if InstallCountRule.outcome(forStatus: status) == .done {
            defaults.set(true, forKey: Self.reportedKey)
        }
    }
}
