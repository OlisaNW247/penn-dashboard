import Foundation
import Testing
@testable import LowHangingFruitUI

/// The push wake's body lives in `BackgroundRefresh.swift`, iOS only, so what
/// it may and may not call is pinned at the source level; the once-only
/// completion is run for real through `PushWakeRace`, which has no UIKit.
@Suite("Push wake")
struct PushWakeTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func pushBody() throws -> String {
        let code = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        return try HardeningSourceScan.body(ofFunctionDeclaredWith: "private static func runPush() async -> Bool", in: code)
    }

    @Test("the push branch reads the planner window and re-plans without a prompt")
    func pushDoes() throws {
        let body = try pushBody()
        #expect(body.contains("pollPlannerWindow(source: .push)"))
        #expect(body.contains("replan(scheduler: scheduler, state: state)"))
        let code = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        #expect(code.contains("rescheduleWithoutPrompting(from:"))
        #expect(body.contains("LiveAppStateRegistry.shared.beginWake()"))
        #expect(body.contains("defer { wake.end() }"))
        #expect(body.contains("SweeperCounts.wakesPush"))
        #expect(body.contains("SessionCookieStore.isExpired(service: .canvas)"))
        #expect(body.contains("isUsingFixtureData"))
    }

    @Test("the push branch calls none of the passes a wake must not make")
    func pushDoesNot() throws {
        let body = try pushBody()
        for forbidden in ["syncIfConfigured", "refreshCanvasGrades", "syncConnectedServices", "refreshCourseKnowledge",
                          "deviceSyncPass", "postTurnedInNotifications", "startSilentCanvasRenewal",
                          "awaitPendingSilentRenewal", "attemptSilentCanvasRenewal", "runBackgroundKeepAliveProbe",
                          "syncGradescope", "refreshEdDiscussion", "requestAuthorization", "setEnabled", "sweeperWakePass"] {
            #expect(!body.contains(forbidden), "the push wake must not call \(forbidden)")
        }
        #expect(!body.contains(".reschedule(from"))
    }

    @Test("the planner read has one body that the hour-gated callers and the push share")
    func sharedRead() throws {
        let code = try HardeningSourceScan.uiCode("AppState+LastHourPoll.swift")
        let gated = try HardeningSourceScan.body(
            ofFunctionDeclaredWith: "func pollPlannerWindowIfInsideTheHour(", in: code)
        #expect(gated.contains("LastHourPoll.insideTheHour(now: now, nextRing: nextRing)"))
        #expect(gated.contains("pollPlannerWindow(source: source, now: now)"))
        let shared = try HardeningSourceScan.body(ofFunctionDeclaredWith: "func pollPlannerWindow(source:", in: code)
        #expect(shared.contains("applyPlannerWindow("))
        #expect(!shared.contains("insideTheHour"))
    }

    @Test("the handler is the completion-handler form, bound to the 25 second race, never async")
    func delegateForm() throws {
        let app = try String(contentsOf: repoRoot().appendingPathComponent("App/LHFApp.swift"), encoding: .utf8)
        let code = HardeningSourceScan.codeOnly(app)
        #expect(code.contains("fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void"))
        #expect(code.contains("LHFBackgroundRefresh.handlePushWake(userInfo: userInfo, completion: completionHandler)"))
        #expect(!code.contains("didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async"))
        #expect(!code.contains(") async -> UIBackgroundFetchResult"))
        #expect(code.contains("@UIApplicationDelegateAdaptor(LHFAppDelegate.self)"))
        #expect(code.contains("NotificationResponseRouter.install()"))
        let refresh = try HardeningSourceScan.uiCode("BackgroundRefresh.swift")
        let handler = try HardeningSourceScan.body(ofFunctionDeclaredWith: "public static func handlePushWake(", in: refresh)
        #expect(handler.contains("PushWakeRace.run("))
        #expect(PushWakeRace.defaultTimeout == 25)
    }

    @Test("no source line puts a device token into a log, a print or an error")
    func tokenNeverLogged() throws {
        let sources = repoRoot().appendingPathComponent("LowHangingFruitKit/Sources/LowHangingFruitUI")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.contains("SweeperWake") }
        #expect(files.count >= 2)
        var scanned = files.map { sources.appendingPathComponent($0) }
        scanned.append(sources.appendingPathComponent("BackgroundRefresh.swift"))
        scanned.append(repoRoot().appendingPathComponent("App/LHFApp.swift"))
        for url in scanned {
            let code = HardeningSourceScan.codeOnly(try String(contentsOf: url, encoding: .utf8))
            for line in code.split(separator: "\n") where line.contains("print(") || line.contains("DebugWakeLog.record")
                || line.contains("NSLog") || line.contains("Logger") || line.contains("os_log") {
                let lower = line.lowercased()
                #expect(!lower.contains("token") && !lower.contains("hex"),
                        "\(url.lastPathComponent): \(line)")
            }
        }
        // And the failure note carries no error text.
        let state = try HardeningSourceScan.uiCode("AppState+SweeperWake.swift")
        let failure = try HardeningSourceScan.body(
            ofFunctionDeclaredWith: "func noteDeviceTokenRegistrationFailed()", in: state)
        #expect(!failure.contains("error") && !failure.contains("description"))
    }

    // MARK: The once-only completion

    @MainActor
    private final class Counter {
        var answers: [Bool] = []
    }

    @MainActor
    @Test("work that never finishes is answered once, as no new data, at the timeout")
    func timeoutAnswersOnce() async throws {
        let counter = Counter()
        PushWakeRace.run(
            timeout: 0.1,
            work: { try? await Task.sleep(nanoseconds: 60_000_000_000); return true },
            completion: { counter.answers.append($0) })
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(counter.answers == [false])
    }

    @MainActor
    @Test("work that finishes first answers once with its own result, and the timeout adds nothing")
    func workWins() async throws {
        let counter = Counter()
        PushWakeRace.run(timeout: 0.2, work: { true }, completion: { counter.answers.append($0) })
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(counter.answers == [true])
    }

    @MainActor
    @Test("work that finishes after the timeout does not answer a second time")
    func lateWorkIsIgnored() async throws {
        let counter = Counter()
        PushWakeRace.run(
            timeout: 0.1,
            work: { try? await Task.sleep(nanoseconds: 300_000_000); return true },
            completion: { counter.answers.append($0) })
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(counter.answers == [false])
    }
}
