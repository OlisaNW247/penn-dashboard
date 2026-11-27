import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

private func sourceText(_ name: String) throws -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return try String(
        contentsOf: url.appendingPathComponent("Sources/LowHangingFruitUI/\(name)"), encoding: .utf8)
}

/// The text of one function, from its `func` line to the next `    func `.
private func body(of marker: String, in source: String) throws -> String {
    let start = try #require(source.range(of: marker))
    let rest = String(source[start.lowerBound...])
    let afterHead = rest.index(rest.startIndex, offsetBy: marker.count)
    let end = rest[afterHead...].range(of: "\n    func ")?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
}

@Suite("Degree sign-in: who may type the PennKey")
struct DegreeSignInFillRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func may(
        submitted: TimeInterval? = nil, failed: TimeInterval? = nil,
        rejected: Bool = false, enabled: Bool = true, user: Bool, trust: Bool
    ) -> Bool {
        PathPortal.mayFillCredential(
            now: now,
            lastSubmission: submitted.map { now.addingTimeInterval(-$0) },
            lastFailedSubmission: failed.map { now.addingTimeInterval(-$0) },
            passwordRejected: rejected, autoLoginEnabled: enabled,
            userInitiated: user, duoTrustLive: trust)
    }

    @Test("a student's own ask types unless rejected or off, trust or no trust")
    func userAsk() {
        for trust in [true, false] {
            #expect(may(user: true, trust: trust))
            #expect(!may(rejected: true, user: true, trust: trust))
            #expect(!may(enabled: false, user: true, trust: trust))
            // The failed-submission hour does not apply to an ask.
            #expect(may(submitted: 30 * 60, failed: 30 * 60, user: true, trust: trust))
            // Ninety seconds since the last typing, never less.
            #expect(PathPortal.userAskCredentialSpacing == 90)
            #expect(!may(submitted: 60, user: true, trust: trust))
            #expect(!may(submitted: 89, user: true, trust: trust))
            #expect(may(submitted: 91, user: true, trust: trust))
        }
    }

    @Test("an automatic attempt never types without Duo trust, and with it follows the old rule")
    func automatic() {
        let offsets: [TimeInterval?] = [nil, 0, 599, 600, 3599, 3600, 7200]
        for submitted in offsets {
            for failed in offsets {
                #expect(!may(submitted: submitted, failed: failed, user: false, trust: false))
                let expected = (submitted.map { $0 >= 600 } ?? true) && (failed.map { $0 >= 3600 } ?? true)
                #expect(may(submitted: submitted, failed: failed, user: false, trust: true) == expected)
            }
        }
        #expect(!may(rejected: true, user: false, trust: true))
        #expect(!may(enabled: false, user: false, trust: true))
    }
}

@Suite("Degree sign-in: the chat's failure lines")
struct DegreeAdvisorFailureLineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    private func line(_ failure: DegreeAdvisorReadFailure) -> String {
        AppState.degreeAdvisorReadFailureLine(failure, name: "management (general)", now: now, timeZone: utc)
    }

    @Test("each reason has its words")
    func lines() {
        #expect(line(.duoNotApproved) == "duo wasn't approved in time. ask again and approve the push on this phone.")
        #expect(line(.noCanvasSession) == "sign in to canvas first, then ask again.")
        #expect(line(.needsPennKey) == "penn needs your pennkey. update it in profile, then ask again.")
        #expect(line(.other) == "couldn't read path@penn's audit for management (general). ask again.")
        #expect(line(.withinBudget(until: now.addingTimeInterval(30 * 60)))
                == "path@penn sign-in can try again at 8:30 am.")
        #expect(line(.withinBudget(until: now.addingTimeInterval(60))) == "just tried. ask again in a minute.")
    }

    @Test("the reason comes from the last sign-in and the portal's skip")
    func reasons() {
        let later = now.addingTimeInterval(1800)
        #expect(AppState.degreeAdvisorReadFailure(signIn: .needsDuo, skip: nil) == .duoNotApproved)
        #expect(AppState.degreeAdvisorReadFailure(signIn: .noCanvasSession, skip: nil) == .noCanvasSession)
        #expect(AppState.degreeAdvisorReadFailure(signIn: .timedOut, skip: .withinBudget(until: later))
                == .withinBudget(until: later))
        #expect(AppState.degreeAdvisorReadFailure(signIn: .timedOut, skip: .noneSaved) == .needsPennKey)
        #expect(AppState.degreeAdvisorReadFailure(signIn: .timedOut, skip: .rejectedOrOff) == .needsPennKey)
        #expect(AppState.degreeAdvisorReadFailure(signIn: .timedOut, skip: nil) == .other)
        #expect(AppState.degreeAdvisorReadFailure(signIn: nil, skip: nil) == .other)
        #expect(AppState.degreeAdvisorReadFailure(signIn: .ready, skip: nil) == .other)
    }

    @Test("only a failure that asking again can fix offers try again")
    func retryRule() {
        #expect(DegreeAdvisorReadFailure.duoNotApproved.canRetry(now: now))
        #expect(DegreeAdvisorReadFailure.other.canRetry(now: now))
        #expect(!DegreeAdvisorReadFailure.noCanvasSession.canRetry(now: now))
        #expect(!DegreeAdvisorReadFailure.needsPennKey.canRetry(now: now))
        #expect(DegreeAdvisorReadFailure.withinBudget(until: now.addingTimeInterval(90)).canRetry(now: now))
        #expect(!DegreeAdvisorReadFailure.withinBudget(until: now.addingTimeInterval(1800)).canRetry(now: now))
    }
}

@Suite("Degree sign-in: kept what-if audits")
struct DegreeKeptWhatIfTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let goals = DegreeGoals(degree: "BS", majors: ["MGMT"])

    private func audit(goals: DegreeGoals, age: TimeInterval) -> DegreeAudit {
        DegreeAudit(goals: goals, isWhatIf: true, percentComplete: 50, degreeLabel: nil,
                    catalogYearLabel: nil, blocks: [], courses: [], fetchedAt: now.addingTimeInterval(-age))
    }

    private func scores(goals: DegreeGoals?) -> [String: DegreeOptionScore] {
        [DegreeOptions.scoreKey(degreeID: "d1", programCode: "MGMT-BS-GEN"):
            DegreeOptionScore(fraction: 0.5, open: 3, readAt: now, goals: goals)]
    }

    private func lookup(_ scores: [String: DegreeOptionScore], _ audits: [DegreeAudit]) -> DegreeAudit? {
        AppState.keptWhatIf(
            optionScores: scores, whatIfs: audits, degreeID: "d1", programCode: "MGMT-BS-GEN",
            now: now, maxAge: AppState.degreeStaleAfter)
    }

    @Test("a score, its audit and a fresh read give the kept audit")
    func hit() {
        let kept = audit(goals: goals, age: 27 * 60)
        #expect(lookup(scores(goals: goals), [audit(goals: DegreeGoals(), age: 0), kept]) == kept)
    }

    @Test("no score, no goals, no audit or an old audit give nil")
    func misses() {
        let kept = audit(goals: goals, age: 60)
        #expect(lookup([:], [kept]) == nil)
        #expect(lookup(scores(goals: nil), [kept]) == nil)
        #expect(lookup(scores(goals: goals), []) == nil)
        #expect(lookup(scores(goals: goals), [audit(goals: DegreeGoals(), age: 60)]) == nil)
        #expect(lookup(scores(goals: goals), [audit(goals: goals, age: AppState.degreeStaleAfter + 1)]) == nil)
    }

    @Test("a score written before goals were kept still decodes")
    func lenientDecode() throws {
        let json = #"{"fraction":0.5,"open":3,"readAt":0}"#
        let score = try JSONDecoder().decode(DegreeOptionScore.self, from: Data(json.utf8))
        #expect(score.goals == nil)
    }

    @Test("the notice names today, yesterday or the day")
    func notice() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func text(_ age: TimeInterval) -> String {
            AppState.degreeKeptAuditNotice(
                name: "management", readAt: now.addingTimeInterval(-age), now: now, calendar: calendar)
        }
        #expect(text(60) == "using path@penn's audit for management from today")
        #expect(text(86_400) == "using path@penn's audit for management from yesterday")
        #expect(text(3 * 86_400) == "using path@penn's audit for management from jan 12")
    }
}

@Suite("Degree sign-in: who asks, in the source")
struct DegreeSignInSourceTests {
    @Test("a student's own asks pass userInitiated true; the automatic callers do not")
    func callers() throws {
        let source = try sourceText("AppState+Degree.swift")
        let plans = try body(of: "func degreeWhatIfPlans(", in: source)
        #expect(plans.contains("signInToPath(force: true, userInitiated: true)"))
        let whatIf = try body(of: "func runWhatIf(", in: source)
        #expect(whatIf.contains("signInToPath(force: true, userInitiated: true)"))
        let programs = try body(of: "func loadDegreePrograms(", in: source)
        #expect(!programs.contains("userInitiated: true"))
        let ensure = try body(of: "func ensureAllDegreeAudits(", in: source)
        #expect(!ensure.contains("userInitiated: true"))
        let refresh = try body(of: "func refreshDegreeAudit(", in: source)
        #expect(refresh.contains("userInitiated: userInitiated"))
        let screen = try sourceText("DegreeProgressView.swift")
        #expect(screen.contains("refreshDegreeAudit(force: false)"))
        #expect(!screen.contains("refreshDegreeAudit(force: false, userInitiated: true)"))
    }

    @Test("the portal says what Duo did and never grows the forbidden words")
    func portalLog() throws {
        let portal = try sourceText("PathPortal.swift")
        for words in ["duo: push sent", "duo: trust tapped", "duo: approved"] {
            #expect(portal.contains(words))
        }
        for file in ["PathPortal.swift", "AppState+DegreeAdvisor.swift", "DegreeAdvisorView.swift"] {
            let text = try sourceText(file).lowercased()
            #expect(!text.contains("recommend"))
            #expect(!text.contains("average"))
            #expect(!text.contains("graduate"))
        }
    }
}

@Suite("Degree sign-in: the failure ceiling and stuck-status guards")
struct DegreeSignInCeilingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func may(streak: Int, failedAgo: TimeInterval?, rejected: Bool = false) -> Bool {
        PathPortal.mayFillCredential(
            now: now, lastSubmission: nil,
            lastFailedSubmission: failedAgo.map { now.addingTimeInterval(-$0) },
            passwordRejected: rejected, autoLoginEnabled: true,
            userInitiated: true, duoTrustLive: false, failedStreak: streak)
    }

    @Test("a student's ask skips the failed hour only while fewer than two failures in a row")
    func streak() {
        #expect(PathPortal.userAskFailureLimit == 2)
        #expect(may(streak: 0, failedAgo: 30 * 60))
        #expect(may(streak: 1, failedAgo: 30 * 60))
        #expect(!may(streak: 2, failedAgo: 30 * 60))
        #expect(!may(streak: 5, failedAgo: 30 * 60))
        // After the hour a streak of two may try again.
        #expect(may(streak: 2, failedAgo: 3600))
        #expect(may(streak: 2, failedAgo: nil))
        // Rejected always refuses.
        #expect(!may(streak: 0, failedAgo: nil, rejected: true))
        #expect(!may(streak: 2, failedAgo: 7200, rejected: true))
    }

    @Test("the refusal's wait ends an hour after the last failure")
    func waitEnds() {
        let until = PathPortal.fillBlockedUntil(
            now: now, lastSubmission: nil, lastFailedSubmission: now.addingTimeInterval(-1800),
            userInitiated: true, failedStreak: 2)
        #expect(until == now.addingTimeInterval(1800))
    }

    @Test("the guards are in the source")
    func source() throws {
        let portal = try sourceText("PathPortal.swift")
        #expect(portal.contains("guard attemptRunning, !duoReached"))
        // The defer grew a second line with the sign-in page (2026-11-27): it
        // still clears the flag on every way out, and now the shown page too.
        #expect(portal.contains("defer {\n            attemptRunning = false\n"))
        #expect(portal.contains("            endInteractiveIfShown()\n        }\n        attemptUserInitiated = userInitiated"))
        #expect(portal.contains("if inFlight == running { inFlight = nil }"))
        #expect(portal.contains("onCredentialSucceeded?()"))
        let state = try sourceText("AppState+Degree.swift")
        #expect(state.contains("guard degreeSignInsAwaiting > 0"))
        #expect(state.contains("degreeAskSubmitted"))
        let screen = try sourceText("DegreeProgressView.swift")
        #expect(screen.contains("selectDegree(degree.id, userInitiated: true)"))
        #expect(screen.contains("selectDegree(entry.id, userInitiated: true)"))
        #expect(try sourceText("DegreeWhatIfSheet.swift").contains("selectDegree(id, userInitiated: true)"))
    }
}

@Suite("Degree sign-in: the page shown to the student")
struct DegreeInteractiveSignInTests {
    private func go(
        user: Bool = true, duo: TimeInterval? = nil, form: Bool = false,
        token: Bool = false, already: Bool = false, supported: Bool = true
    ) -> Bool {
        PathPortal.shouldGoInteractive(
            userInitiated: user, duoReachedFor: duo, formBlocked: form,
            tokenArrived: token, alreadyInteractive: already, supported: supported)
    }

    @Test("the trigger rule")
    func rule() {
        #expect(PathPortal.interactiveAfterDuo == 6)
        #expect(PathPortal.interactiveWait == 300)
        // Automatic attempts never go interactive.
        #expect(!go(user: false, duo: 30))
        #expect(!go(user: false, form: true))
        // Duo: not under six seconds, yes from six.
        #expect(!go(duo: nil))
        #expect(!go(duo: 0))
        #expect(!go(duo: 5.9))
        #expect(go(duo: 6))
        #expect(go(duo: 40))
        // A form the app may not fill.
        #expect(go(form: true))
        // Never once the token is in, never twice, never where nothing can show it.
        #expect(!go(duo: 30, token: true))
        #expect(!go(form: true, token: true))
        #expect(!go(duo: 30, already: true))
        #expect(!go(duo: 30, supported: false))
        #expect(!go(form: true, supported: false))
    }

    @Test("a page that sits after duo or after the pennkey is shown too")
    func stall() {
        // 2026-11-27, read off a phone: Duo passed by itself and the popup sat
        // on Penn's own page for two minutes under "approve the duo push".
        #expect(PathPortal.interactiveAfterStall == 10)
        func stalled(_ seconds: TimeInterval?, user: Bool = true, token: Bool = false,
                     already: Bool = false, supported: Bool = true) -> Bool {
            PathPortal.shouldGoInteractive(
                userInitiated: user, duoReachedFor: nil, formBlocked: false,
                tokenArrived: token, alreadyInteractive: already,
                stalledFor: seconds, supported: supported)
        }
        #expect(!stalled(nil))
        #expect(!stalled(9.9))
        #expect(stalled(10))
        #expect(!stalled(60, user: false))
        #expect(!stalled(60, token: true))
        #expect(!stalled(60, already: true))
        #expect(!stalled(60, supported: false))
        let portal = try? sourceText("PathPortal.swift")
        for words in ["duo: left", "stalled after duo", "popup failed: "] {
            #expect(portal?.contains(words) == true)
        }
        #expect(AppState.degreeDuoLineDelay == 4)
    }

    @Test("a closed sheet has its own line and can be retried")
    func closedLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = AppState.degreeAdvisorReadFailure(signIn: .needsDuo, skip: nil, endedByStudent: true)
        #expect(failure == .signInNotFinished)
        #expect(AppState.degreeAdvisorReadFailureLine(
            failure, name: "x", now: now, timeZone: TimeZone(identifier: "UTC")!)
                == "sign-in wasn't finished. ask again.")
        #expect(failure.canRetry(now: now))
        #expect(AppState.degreeAdvisorReadFailure(signIn: .needsDuo, skip: nil) == .duoNotApproved)
    }

    @Test("the status words")
    func words() {
        #expect(DegreeStatus.finishSigningIn.line(now: Date()) == "finish signing in")
    }

    @Test("the sheet and its presenters are wired in the source")
    func source() throws {
        let sheet = try sourceText("PathSignInSheet.swift")
        #expect(sheet.contains("interactiveDismissDisabled"))
        // Dismantling only takes the hosted view out of its container.
        let start = try #require(sheet.range(of: "static func dismantleUIView"))
        let dismantle = String(sheet[start.lowerBound...].prefix(260))
        #expect(!dismantle.contains("stopLoading"))
        #expect(!dismantle.contains(".load("))
        #expect(dismantle.contains("hosted.removeFromSuperview()"))
        for file in ["DegreeAdvisorView.swift", "DegreeWhatIfSheet.swift", "DegreeProgressView.swift"] {
            #expect(try sourceText(file).contains("pathSignInSheet("))
        }
        #expect(sheet.contains("degreeInteractiveSignIn"))
        #expect(try sourceText("DegreeAdvisorView.swift").contains("degreeInteractiveSignIn"))
        let portal = try sourceText("PathPortal.swift")
        for words in ["interactive: shown", "interactive: finished", "interactive: closed"] {
            #expect(portal.contains(words))
        }
    }
}
