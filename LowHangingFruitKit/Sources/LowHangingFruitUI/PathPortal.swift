import Foundation
import WebKit
import LowHangingFruitKit

/// The one client of Path@Penn: a single hidden `WKWebView` on Penn's advising
/// page (`https://courses.upenn.edu/`) that lives for the app run.
///
/// **Why the page is the client.** The audit is served by a single-page app
/// whose requests carry a 32-character token in the form body, and whose own
/// script knows how to ask for an audit, a program or the student's record
/// (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md, "Observed on 2026-11-10"). So this
/// class does not imitate those requests. It loads the page, lets the page run
/// its own sign-in popup, and then calls the page's own functions through the
/// scripts in `PathScripts`, each of which hands back an allowlisted JSON
/// string. The token, the student's id, the first name and the rendered audit
/// HTML never cross into Swift (the five binding rules of the spec's "rewrite
/// contract"), and nothing is stored in the Keychain for this feature: it
/// replaces the old session reader, native client and token store outright.
///
/// **The popup.** The page signs in with `window.open(...)` to Penn's SSO, and
/// the popup's last page calls a function on its OPENER to deliver the token.
/// So `createWebViewWith` must return a child built from the configuration
/// WebKit passes in. A child built from a fresh configuration has no opener
/// and the hand-off silently never happens; that is the wrong fix to avoid.
/// Only a popup aimed at `PathPage.authHost` is allowed at all.
///
/// **The one-submission rule** is carried over from the old reader: if the
/// popup lands on Penn's PennKey form, the saved pair is filled and submitted
/// at most once per sign-in attempt, only on a `PennKeyLoginForm` host after
/// `detectFormScript` confirms a real form is on the page. A second sighting
/// means the password was refused or Duo bounced, and resubmitting could lock
/// the PennKey account. Duo's own buttons are tapped by `DuoPromptAutoTap`
/// (its user script and handler are installed on the shared configuration, so
/// the popup gets them too).
///
/// **One PennKey, one submission budget.** "Once per attempt" alone is not a
/// budget: attempts are cheap (a student's tap starts one), so a wrong saved
/// password would be retyped on every tap and lock the account. The silent
/// Canvas renewer already has the account-level budget, kept in persisted
/// records (`lastCredentialSubmissionAtV1`, `lastFailedCredentialSubmissionAtV1`,
/// the "password rejected" latch). The portal reads and stamps those same
/// records through `CredentialBudget` and the three `onCredential…` hooks that
/// `AppState+Degree` binds, and applies the renewer's own spacings
/// (`foregroundCredentialSpacing`, `failedSubmissionSpacing`), so whoever
/// spends the budget, the other sees it. The wrong fix is a second, private
/// budget in the portal: two budgets for one account is exactly twice the
/// lock-out risk. `force` skips only the 60-second attempt throttle.
///
/// **Privacy of the log.** DEBUG only, step names and outcomes, hosts of the
/// popup's pages: never a token, an id, a name, a query string or a course.
@MainActor
final class PathPortal: NSObject, WKUIDelegate {
    enum SignIn: Sendable, Equatable {
        case ready
        case needsDuo
        case noCanvasSession
        case blocked
        case timedOut
        case throttled
        /// An automatic attempt reached Penn's form and stopped there: only
        /// the student's own tap types the PennKey.
        case needsStudentSignIn
    }

    /// How long one page script may take before the call is abandoned. The
    /// page's promise can simply never settle (a dropped request inside Penn's
    /// own script), and without a deadline the continuation never resumes and
    /// the whole feature hangs on `.reading`.
    nonisolated static let scriptTimeout: TimeInterval = 30
    /// The audit runs Penn's translator server-side and is the slow call.
    nonisolated static let auditTimeout: TimeInterval = 90
    private static let readyWait: TimeInterval = 20
    private static let signInWait: TimeInterval = 60
    private static let signInWaitAfterDuo: TimeInterval = 120
    private static let minimumAttemptInterval: TimeInterval = 60
    private static let pollNanoseconds: UInt64 = 500_000_000

    /// What the shared PennKey budget says right now (see the type's header).
    struct CredentialBudget: Sendable, Equatable {
        var lastSubmission: Date?
        var lastFailedSubmission: Date?
        var passwordRejected: Bool
        var autoLoginEnabled: Bool
        /// A live Duo trust cookie is known. False when the Duo jar has not
        /// been read yet this launch, which is the safe side.
        var duoTrustLive: Bool = false
        /// Consecutive failed submissions (typed, ended without a session).
        var failedStreak: Int = 0
    }

    /// Bound by `AppState+Degree` before every use. Unbound means the fill is
    /// refused: a portal that cannot see the budget must not spend it.
    var credentialBudget: (() -> CredentialBudget)?
    var onCredentialSubmitted: ((Date) -> Void)?
    var onCredentialFailed: ((Date) -> Void)?
    var onCredentialRejected: (() -> Void)?
    /// An attempt that typed the PennKey got its token.
    var onCredentialSucceeded: (() -> Void)?
    /// True from the top of an attempt to every way out of it; the Duo hook
    /// fires only inside it (`defer` in `performSignIn` cannot leak).
    private var attemptRunning = false
    /// Called once per attempt when the popup reaches Duo (a push is waiting).
    var onDuoReached: (() -> Void)?
    /// Why the last attempt did not type the PennKey; reset at the start of
    /// each attempt.
    private(set) var lastFillSkip: FillSkip?
    /// Set from the caller of the attempt in flight. A caller that joins an
    /// attempt already running does not upgrade it: the attempt keeps the
    /// flag it started with.
    private(set) var attemptUserInitiated = false
    /// An automatic attempt saw Penn's form; the attempt ends at once.
    private var stopForStudent = false
    /// The student's own attempt met a form it may not fill (just typed,
    /// rejected, nothing saved). It ends at once with the reason in
    /// `lastFillSkip`: sitting a minute on a form nobody will fill only
    /// delays the line that tells the student what to do.
    private var stopForSkip = false
    /// The student's own attempt met a form it may not fill; where the page can
    /// be shown it goes interactive instead of ending (`shouldGoInteractive`).
    private var formBlocked = false
    /// When this attempt first reached Duo, for the interactive rule.
    private var duoReachedAt: Date?
    /// True while the popup is handed to the UI for the student to finish by
    /// hand. The popup's web view is the same one the hidden path uses.
    private(set) var isInteractive = false
    private var interactiveShownAt: Date?
    /// The student closed the sheet: the attempt ends at its next poll.
    private var stopByStudent = false
    /// The last attempt ended because the student closed the sheet.
    private(set) var lastEndedByStudent = false
    /// Told when the interactive state turns on or off (once per change).
    var onInteractiveChanged: ((Bool) -> Void)?
    /// Once-per-attempt guards for the Duo log lines.
    private var loggedDuoPush = false
    private var loggedDuoTrust = false
    private var loggedDuoLeft = false
    /// A student's own ask is waiting on the attempt in flight, even one that
    /// started as automatic and they joined. Such an attempt keeps the typing
    /// rule it started with, but it may show the student the page: they are
    /// there, and an automatic attempt that stalled would otherwise run out
    /// its two minutes in front of them with nothing to do.
    private var studentIsWaiting = false
    /// Whether the popup's last finished page was on a Duo host.
    private var popupOnDuo = false
    /// When the popup last finished loading a page, for the stall rule.
    private var lastPopupFinishAt: Date?
    /// Told once per attempt when the popup leaves Duo for another host: Duo
    /// is done with it, so "approve the duo push" no longer describes the wait.
    var onDuoLeft: (() -> Void)?

    private var configuration: WKWebViewConfiguration?
    private var webView: WKWebView?
    private var popup: WKWebView?
    private var popupDelegate: PathPopupDelegate?
    private var mainDelegate: PathMainDelegate?

    /// The attempt in progress, if any. A second caller JOINS it and gets its
    /// answer; it used to be turned away with `.throttled`, which the callers
    /// showed as a failure while the real read was still going.
    private var inFlight: Task<SignIn, Never>?
    private var lastAttemptEndedAt: Date?
    private var duoReached = false
    /// True once this attempt has filled the form. Reset at the top of each
    /// attempt; the cross-attempt limit is the shared budget, not this flag.
    private var hasSubmittedCredentials = false
    private var bounceHandled = false
    /// The page must be loaded again before the next sign-in: its in-memory
    /// token died with the session, or its content process was killed.
    private var needsReload = false

    // MARK: Pure rules

    /// Whether the saved PennKey may be typed into Penn's form now. The same
    /// rule as `CanvasSessionRenewer.credentialSubmissionAllowed` in a
    /// foreground attempt, built on the renewer's own spacing constants (that
    /// function is main-actor isolated, so it cannot be called from here), plus
    /// the two latches: a password Penn rejected, or auto-login being off.
    ///
    /// `userInitiated` is true only for an attempt the student's own ask in the
    /// degree screen started. Then the failed-submission hour is not applied and
    /// the spacing since the last submission is `userAskCredentialSpacing`.
    /// False is the renewer's rule AND a live Duo trust cookie.
    nonisolated static func mayFillCredential(
        now: Date,
        lastSubmission: Date?,
        lastFailedSubmission: Date?,
        passwordRejected: Bool,
        autoLoginEnabled: Bool,
        userInitiated: Bool = false,
        duoTrustLive: Bool = false,
        failedStreak: Int = 0
    ) -> Bool {
        guard autoLoginEnabled, !passwordRejected else { return false }
        // An automatic attempt types the PennKey only while Duo remembers this
        // phone, because then the sign-in cannot cost a push nobody asked for
        // (an automatic read when the screen opened is how a push went out
        // unseen on 2026-11-26). Without trust it ends at the form and the
        // student's tap signs in. The wrong fix is a longer wait or a
        // notification, which still spends a push nobody asked for. (The
        // renewer's own rule is untouched.)
        guard userInitiated || duoTrustLive else { return false }
        return fillBlockedUntil(
            now: now, lastSubmission: lastSubmission, lastFailedSubmission: lastFailedSubmission,
            userInitiated: userInitiated, failedStreak: failedStreak) == nil
    }

    /// When the budget next allows a fill, or nil when it allows one now. Only
    /// the two spacings; the latches (rejected, auto-login off) are the
    /// caller's.
    nonisolated static func fillBlockedUntil(
        now: Date,
        lastSubmission: Date?,
        lastFailedSubmission: Date?,
        userInitiated: Bool,
        failedStreak: Int = 0
    ) -> Date? {
        var until: Date?
        if !userInitiated || failedStreak >= userAskFailureLimit, let lastFailedSubmission {
            let end = lastFailedSubmission.addingTimeInterval(CanvasSessionRenewer.failedSubmissionSpacing)
            if end > now { until = end }
        }
        if let lastSubmission {
            let spacing = userInitiated
                ? userAskCredentialSpacing
                : CanvasSessionRenewer.foregroundCredentialSpacing
            let end = lastSubmission.addingTimeInterval(spacing)
            if end > now {
                if let existing = until {
                    until = max(existing, end)
                } else {
                    until = end
                }
            }
        }
        return until
    }

    /// Why the last attempt did not type the saved PennKey, when it did not.
    enum FillSkip: Sendable, Equatable {
        case withinBudget(until: Date)
        case noneSaved
        case rejectedOrOff
    }

    /// Duo reached and no token this long: the page is shown to the student.
    /// A remembered device comes back in about four seconds, so it never flashes.
    nonisolated static let interactiveAfterDuo: TimeInterval = 6
    /// The popup has sat this long on a page that is not Duo, after the
    /// PennKey was typed or Duo was passed, with no token: the page is shown.
    /// Read off a phone on 2026-11-27: Duo passed by itself in seconds (a
    /// remembered device, so no push was ever sent) and the popup then sat on
    /// Penn's own page for two minutes under "approve the duo push", which
    /// named a thing the student could not do. A normal hand-off moves to the
    /// next page well inside this.
    nonisolated static let interactiveAfterStall: TimeInterval = 10
    /// How long a shown page waits for the student, from when it was shown.
    nonisolated static let interactiveWait: TimeInterval = 300
    /// The sheet exists on iOS only; on the Mac an attempt is never interactive.
    nonisolated static var interactiveSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Whether this attempt should hand its popup to the student. Never for an
    /// automatic attempt (it ends at the form), never twice, never once the
    /// token is in.
    nonisolated static func shouldGoInteractive(
        userInitiated: Bool,
        duoReachedFor: TimeInterval?,
        formBlocked: Bool,
        tokenArrived: Bool,
        alreadyInteractive: Bool,
        stalledFor: TimeInterval? = nil,
        supported: Bool = PathPortal.interactiveSupported
    ) -> Bool {
        guard supported, userInitiated, !tokenArrived, !alreadyInteractive else { return false }
        if formBlocked { return true }
        if let duoReachedFor, duoReachedFor >= interactiveAfterDuo { return true }
        if let stalledFor, stalledFor >= interactiveAfterStall { return true }
        return false
    }

    /// A student's tap in the degree screen is the consent a Duo push needs;
    /// the hour after a failed submission exists to stop pushes nobody asked
    /// for. So an ask may type again inside that hour, but never within 90
    /// seconds of the last typing. The wrong fixes would be shortening the
    /// hour for automatic attempts, or touching the Canvas renewer's own
    /// rule: this must change neither.
    nonisolated static let userAskCredentialSpacing: TimeInterval = 90

    /// After this many consecutive failed submissions the failed-submission
    /// hour applies to a student's ask too. The hour was the only cap on a
    /// wrong password whose error text Penn's page words differently than
    /// `errorTextIndicatesBadCredential` expects (it never latches as
    /// rejected), and a PennKey lockout is the worst outcome here.
    nonisolated static let userAskFailureLimit = 2

    // MARK: Sign-in

    /// Signs in (or confirms the page already is). Concurrent callers share one
    /// attempt.
    func ensureSignedIn(force: Bool = false, userInitiated: Bool = false) async -> SignIn {
        if let running = inFlight {
            // The student is now waiting on this attempt, whoever started it:
            // it may show them the page (it still may not type as theirs).
            if userInitiated { studentIsWaiting = true }
            let joined = await running.value
            // A student's ask that joined an AUTOMATIC attempt which stopped
            // at the form gets exactly one attempt of its own. No loop.
            guard userInitiated, joined == .needsStudentSignIn else { return joined }
            // The finished task may still be stored: clear it (only if it is
            // still the one joined) so this caller gets an attempt of its own,
            // not the stale result.
            if inFlight == running { inFlight = nil }
            if let again = inFlight { return await again.value }
        }
        studentIsWaiting = userInitiated
        let task = Task { @MainActor [self] in
            await self.performSignIn(force: force, userInitiated: userInitiated)
        }
        inFlight = task
        let result = await task.value
        // Only the owner clears, and only its own task: `reset()` may already
        // have replaced it.
        if inFlight == task { inFlight = nil }
        return result
    }

    /// The page's session is no good (a call failed while the page still held
    /// a token): load the home page again at the next sign-in, which drops the
    /// in-memory token. Cookies and the WebView stay.
    func invalidateSession() {
        needsReload = true
        log("session invalidated")
    }

    private func performSignIn(force: Bool, userInitiated: Bool) async -> SignIn {
        attemptRunning = true
        defer {
            attemptRunning = false
            // Every way out of an attempt clears the interactive state once.
            endInteractiveIfShown()
        }
        attemptUserInitiated = userInitiated
        lastFillSkip = nil
        stopForStudent = false
        stopForSkip = false
        formBlocked = false
        duoReachedAt = nil
        stopByStudent = false
        lastEndedByStudent = false
        interactiveShownAt = nil
        loggedDuoPush = false
        loggedDuoTrust = false
        loggedDuoLeft = false
        popupOnDuo = false
        lastPopupFinishAt = nil
        // The clock-stale set is used on purpose (the old session reader
        // did the same): `load` applies the 24-hour rule and returns nothing
        // for a day-old session, but Penn's SSO may still honour it, and when
        // it does not the saved PennKey fill is the silent renewal. Only a
        // phone with neither has nothing to start from.
        let canvasCookies = SessionCookieStore.loadIncludingClockStale(service: .canvas)
        guard !canvasCookies.isEmpty || PennKeyCredentialStore.hasCredentials else {
            return .noCanvasSession
        }
        defer { releasePopup() }

        let view = makeWebViewIfNeeded()
        await inject(canvasCookies)

        // After an invalidation the old document is still on screen until the
        // new one commits, and it still says it has a token. Mark it first and
        // do not believe a readiness answer until the mark is gone.
        var awaitingFreshPage = false
        let reloading = needsReload
        if reloading || view.url?.host?.lowercased() != PathPage.host {
            needsReload = false
            if reloading {
                awaitingFreshPage = (await run(Self.markStaleScript, name: "mark", timeout: 5)) == "ok"
            }
            log("loading home")
            view.load(URLRequest(url: PathPage.homeURL))
        }

        // Wait for the page's own globals to exist.
        let readyDeadline = Date().addingTimeInterval(Self.readyWait)
        var pageReady = false
        var tokenPresent = false
        var challengeTitle = false
        while Date() < readyDeadline {
            if Task.isCancelled || webView == nil { return .timedOut }
            if awaitingFreshPage,
               await run(Self.freshnessScript, name: "fresh", timeout: 5) == "fresh" {
                awaitingFreshPage = false
            }
            if !awaitingFreshPage, let state = await readiness() {
                challengeTitle = PathPage.looksLikeChallenge(title: state.title)
                if state.page {
                    pageReady = true
                    tokenPresent = state.token
                    break
                }
            }
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }
        guard pageReady else {
            if challengeTitle {
                log("blocked: challenge title")
                return .blocked
            }
            log("page not ready")
            return .timedOut
        }
        log("page ready")
        if tokenPresent {
            log("token present")
            return .ready
        }

        // A sign-in attempt costs the student a possible Duo push, so a new
        // one is spaced from the END of the last failed one, even when the
        // caller is a retry loop. (The stamp used to be taken at the start,
        // so by the time an attempt had failed after its 60 seconds the
        // spacing was already used up and never throttled anything.)
        // `force` is a student's own tap and skips only this.
        let startedAt = Date()
        if !force, let last = lastAttemptEndedAt,
           startedAt.timeIntervalSince(last) < Self.minimumAttemptInterval {
            return .throttled
        }
        duoReached = false
        hasSubmittedCredentials = false
        bounceHandled = false

        guard let openJSON = await run(PathScripts.openSignIn, name: "openSignIn") else {
            log("sign-in script failed")
            return concludeAttempt(.timedOut)
        }
        guard PathBridgeDecoder.opened(openJSON) else {
            log("popup not opened")
            return concludeAttempt(.timedOut)
        }
        log("popup opened")

        while true {
            if Task.isCancelled || webView == nil { return concludeAttempt(.timedOut) }
            if stopForStudent {
                log("automatic attempt stopped at the form")
                return concludeAttempt(.needsStudentSignIn)
            }
            if stopForSkip {
                log("sign-in stopped: nothing to type")
                return concludeAttempt(.timedOut)
            }
            if stopByStudent {
                log("interactive: closed")
                lastEndedByStudent = true
                return concludeAttempt(duoReached && !loggedDuoLeft ? .needsDuo : .timedOut)
            }
            // The Duo clock runs only while the popup is still ON Duo; once it
            // has left (or never went), the stall clock runs from the last page
            // the popup finished, and only after something was typed or Duo
            // was passed, so a slow first load is not a stall.
            let pollNow = Date()
            let onDuoFor: TimeInterval? = popupOnDuo
                ? duoReachedAt.map { pollNow.timeIntervalSince($0) } : nil
            let stalledFor: TimeInterval? = (!popupOnDuo && (duoReached || hasSubmittedCredentials))
                ? lastPopupFinishAt.map { pollNow.timeIntervalSince($0) } : nil
            if popup != nil, Self.shouldGoInteractive(
                userInitiated: attemptUserInitiated || studentIsWaiting,
                duoReachedFor: onDuoFor,
                formBlocked: formBlocked,
                tokenArrived: false,
                alreadyInteractive: isInteractive,
                stalledFor: stalledFor
            ) {
                goInteractive()
            }
            if isInteractive, let shown = interactiveShownAt {
                // The student is working on it: a wait of its own, from when
                // the page was shown, in place of the 60 and 120 seconds.
                if Date().timeIntervalSince(shown) >= Self.interactiveWait { break }
            } else {
                let limit = duoReached ? Self.signInWaitAfterDuo : Self.signInWait
                if Date().timeIntervalSince(startedAt) >= limit { break }
            }
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            if let state = await readiness(), state.token {
                log("token arrived")
                if duoReached { log("duo: approved") }
                if isInteractive { log("interactive: finished") }
                if hasSubmittedCredentials { onCredentialSucceeded?() }
                return .ready
            }
        }
        if duoReached, loggedDuoLeft {
            // Duo handed the popup back and the wait ran out on another page:
            // not a push nobody approved, and it must not read as one.
            log("stalled after duo")
            return concludeAttempt(.timedOut)
        }
        if duoReached {
            log("duo not approved in time")
            return concludeAttempt(.needsDuo)
        }
        log("sign-in timed out")
        return concludeAttempt(.timedOut)
    }

    private func goInteractive() {
        guard !isInteractive else { return }
        isInteractive = true
        interactiveShownAt = Date()
        log("interactive: shown")
        onInteractiveChanged?(true)
    }

    private func endInteractiveIfShown() {
        guard isInteractive else { return }
        isInteractive = false
        interactiveShownAt = nil
        onInteractiveChanged?(false)
    }

    /// The popup's web view while the student is finishing the sign-in. It is
    /// the very web view the hidden path uses (built from WebKit's own
    /// configuration, so `window.opener` still works); the UI only hosts it.
    var interactiveWebView: WKWebView? { isInteractive ? popup : nil }

    /// The student closed the sheet: the attempt ends at its next poll as a
    /// timeout would (so the failed-submission accounting is unchanged).
    func cancelInteractive() {
        guard isInteractive else { return }
        stopByStudent = true
        endInteractiveIfShown()
    }

    /// Every way an attempt ends without a token goes through here: it starts
    /// the 60-second spacing, and an attempt that typed the password and did
    /// not get a session counts against the shared failed-submission budget,
    /// exactly as a foreground renewer attempt does.
    private func concludeAttempt(_ result: SignIn) -> SignIn {
        guard result != .ready else { return result }
        // Nothing was typed and nothing failed: no failure clock, and no
        // attempt spacing against the student's own tap that follows.
        if result == .needsStudentSignIn { return result }
        let now = Date()
        lastAttemptEndedAt = now
        if hasSubmittedCredentials { onCredentialFailed?(now) }
        return result
    }

    // MARK: Reads

    func degrees() async -> [StudentDegree] {
        guard let json = await run(PathScripts.degrees, name: "degrees") else { return [] }
        let found = PathBridgeDecoder.degrees(json)
        if found.isEmpty { log("degrees: empty") }
        return found
    }

    /// The audit for one `degreeInfo`, already cut down in the page. `data` is
    /// nil on any failure, with the page's own (short) error text when it gave
    /// one.
    func auditData(degreeInfo: [String: String]) async -> (data: Data?, error: String?) {
        let arguments: [String: Any] = ["degreeInfo": degreeInfo]
        guard let json = await run(
            PathScripts.audit, name: "audit", arguments: arguments, timeout: Self.auditTimeout
        ) else {
            log("audit: no answer")
            return (nil, "no answer")
        }
        // The page's own wording is handed back to the caller and never
        // written to the debug log: it is text the page supplied.
        if let message = PathBridgeDecoder.error(json) {
            log("audit: page error")
            return (nil, message)
        }
        guard let data = PathBridgeDecoder.auditData(json) else {
            log("audit: no blocks")
            return (nil, "no blocks")
        }
        return (data, nil)
    }

    func programs() async -> [PathProgramListing] {
        guard let json = await run(PathScripts.programs, name: "programs") else { return [] }
        return PathBridgeDecoder.programs(json)
    }

    func programInfo(code: String) async -> PathProgramInfo? {
        let arguments: [String: Any] = ["code": code]
        guard let json = await run(PathScripts.programInfo, name: "programInfo", arguments: arguments) else { return nil }
        return PathBridgeDecoder.programInfo(json)
    }

    /// Course codes per term from the student's record; nil when the page did
    /// not answer, which the caller treats as "keep what you had".
    func history() async -> PathHistory? {
        guard let json = await run(PathScripts.history, name: "history") else { return nil }
        let found = PathBridgeDecoder.history(json)
        if found == nil { log("history: no answer") }
        return found
    }

    func dictionaries() async -> PathDictionaries? {
        guard let json = await run(PathScripts.dictionaries, name: "dictionaries") else { return nil }
        return PathBridgeDecoder.dictionaries(json)
    }

    // MARK: Teardown

    /// Drops both WebViews and the throttle. Called on a Canvas disconnect and
    /// a school switch. It does not purge cookies: the disconnect path owns
    /// that, and the data store is shared with the Canvas login.
    func reset() {
        releasePopup()
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
        }
        configuration?.userContentController.removeScriptMessageHandler(forName: DuoPromptAutoTap.handlerName)
        configuration?.userContentController.removeAllUserScripts()
        webView = nil
        configuration = nil
        mainDelegate = nil
        inFlight?.cancel()
        inFlight = nil
        lastAttemptEndedAt = nil
        duoReached = false
        hasSubmittedCredentials = false
        bounceHandled = false
        needsReload = false
        lastFillSkip = nil
        attemptUserInitiated = false
        formBlocked = false
        endInteractiveIfShown()
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Only the page's own sign-in popup, and only from the main view.
        guard webView === self.webView,
              let host = navigationAction.request.url?.host?.lowercased(),
              host == PathPage.authHost
        else { return nil }
        releasePopup()
        // Built from the configuration WebKit passed in, never a new one: that
        // is what keeps `window.opener` alive for the token hand-off.
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.customUserAgent = LoginUserAgent.mobileSafari
        let delegate = PathPopupDelegate(portal: self)
        child.navigationDelegate = delegate
        child.uiDelegate = self
        popup = child
        popupDelegate = delegate
        log("popup opened: \(host)")
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popup else { return }
        log("popup closed")
        releasePopup()
    }

    // MARK: Popup callbacks (from `PathPopupDelegate`)

    fileprivate func popupDidFinish(_ child: WKWebView) {
        guard child === popup else { return }
        let url = child.url
        log("popup at \(url?.host?.lowercased() ?? "(no host)")")
        lastPopupFinishAt = Date()
        if PennKeyLoginForm.isDuo(url) {
            // Arriving on Duo after a submission means a push is (or will be)
            // waiting; the deadline moves out to two minutes.
            popupOnDuo = true
            markDuoReached()
            return
        }
        popupOnDuo = false
        if attemptRunning, duoReached, !loggedDuoLeft {
            loggedDuoLeft = true
            log("duo: left")
            onDuoLeft?()
        }
        let afterSubmission = hasSubmittedCredentials || duoReached
        let isForm = PennKeyLoginForm.isLoginForm(url)
        guard isForm || afterSubmission else { return }
        Task { @MainActor [weak self, weak child] in
            guard let self, let child else { return }
            if afterSubmission { await self.describePage(child) }
            if isForm { await self.considerCredentialForm(child) }
        }
    }

    /// A navigation in the popup failed. Words only: the error's domain and
    /// code, never its URL.
    fileprivate func popupDidFail(_ child: WKWebView, error: Error) {
        guard child === popup else { return }
        let failure = error as NSError
        log("popup failed: \(failure.domain) \(failure.code)")
    }

    /// One log line about the page the popup sits on after the PennKey was
    /// typed or Duo was passed, so a stall there can be told apart next time:
    /// how many forms and buttons it has, whether it is the identity
    /// provider's hand-off form, and the letters of its title. Counts and a
    /// page title only; no field value, no address, nothing the student typed.
    /// DEBUG builds only, like the rest of this log.
    private func describePage(_ child: WKWebView) async {
        #if DEBUG
        let described: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            child.evaluateJavaScript(Self.describePageScript) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        guard child === popup, let described else { return }
        log("page: \(described)")
        #endif
    }

    private static let describePageScript = """
    (function () {
      var forms = document.forms.length;
      var handoff = document.querySelector('input[name="SAMLResponse"]') ? 1 : 0;
      var buttons = document.querySelectorAll('button, input[type="submit"], a[role="button"]').length;
      var title = (document.title || '').replace(/[^A-Za-z -]/g, '').slice(0, 48);
      return 'forms ' + forms + ' handoff ' + handoff + ' buttons ' + buttons + ' title ' + title;
    })();
    """

    /// Fills the saved PennKey into Penn's credential form, once per attempt
    /// and only inside the shared budget; and, when the form comes back after
    /// our own fill, reads why.
    private func considerCredentialForm(_ child: WKWebView) async {
        guard child === popup, !bounceHandled else { return }
        let submittedAtStart = hasSubmittedCredentials
        // WebKit's `Any?` is narrowed to `String?` inside the handler: `Any?`
        // is not `Sendable` and cannot cross the continuation.
        let detected: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            child.evaluateJavaScript(PennKeyLoginForm.detectFormScript) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        // Re-check after the await: the attempt may have ended, and another
        // sighting may have filled meanwhile (that one is not a bounce for
        // this call). Nothing may sit between these checks and the flags.
        guard child === popup, !bounceHandled, hasSubmittedCredentials == submittedAtStart,
              PennKeyLoginForm.isLoginForm(child.url)
        else { return }
        let presence = PennKeyLoginForm.presence(from: detected)
        guard presence == .form || presence == .formError else { return }
        // Once the student has the page, nothing is typed for them.
        if isInteractive { return }

        if hasSubmittedCredentials {
            // The form is back after OUR fill in this attempt. The renewer's
            // rule, exactly: only error text that names the credential counts
            // as a rejection (a Duo denial that bounces to the form does not),
            // and either way there is no second submission.
            bounceHandled = true
            let text: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                child.evaluateJavaScript(PennKeyLoginForm.errorTextScript) { value, _ in
                    continuation.resume(returning: value as? String)
                }
            }
            guard child === popup else { return }
            if PennKeyLoginForm.errorTextIndicatesBadCredential(text) {
                log("form bounce: credential error")
                onCredentialRejected?()
            } else {
                log("form bounce: no credential error")
            }
            return
        }

        guard let budget = credentialBudget?() else {
            log("credential fill skipped: budget unbound")
            if attemptUserInitiated { blockForm() } else { stopForStudent = true }
            return
        }
        let fillNow = Date()
        guard Self.mayFillCredential(
            now: fillNow,
            lastSubmission: budget.lastSubmission,
            lastFailedSubmission: budget.lastFailedSubmission,
            passwordRejected: budget.passwordRejected,
            autoLoginEnabled: budget.autoLoginEnabled,
            userInitiated: attemptUserInitiated,
            duoTrustLive: budget.duoTrustLive,
            failedStreak: budget.failedStreak
        ) else {
            // Either kind of attempt ends here instead of waiting out the
            // deadline on a form nobody will fill: an automatic one as
            // `.needsStudentSignIn`, a student's own as `.timedOut` with the
            // reason in `lastFillSkip`.
            if !attemptUserInitiated {
                stopForStudent = true
                log("credential fill skipped: automatic attempt")
                return
            }
            if budget.passwordRejected || !budget.autoLoginEnabled {
                lastFillSkip = .rejectedOrOff
            } else {
                let until = Self.fillBlockedUntil(
                    now: fillNow, lastSubmission: budget.lastSubmission,
                    lastFailedSubmission: budget.lastFailedSubmission,
                    userInitiated: attemptUserInitiated,
                    failedStreak: budget.failedStreak) ?? fillNow
                lastFillSkip = .withinBudget(until: until)
            }
            blockForm()
            log("credential fill skipped: within budget")
            return
        }
        guard let credentials = PennKeyCredentialStore.load() else {
            lastFillSkip = .noneSaved
            if attemptUserInitiated { blockForm() } else { stopForStudent = true }
            log("credential fill skipped: none saved")
            return
        }
        hasSubmittedCredentials = true
        onCredentialSubmitted?(Date())
        log("login form filled")
        child.evaluateJavaScript(
            PennKeyLoginForm.fillAndSubmitScript(username: credentials.username, password: credentials.password),
            completionHandler: nil
        )
    }

    /// A student's own attempt met a form it may not fill. Where the page can
    /// be shown it goes interactive; elsewhere it ends with the reason.
    private func blockForm() {
        if Self.interactiveSupported { formBlocked = true } else { stopForSkip = true }
    }

    fileprivate func contentProcessDied() {
        needsReload = true
        log("content process terminated")
    }

    // MARK: Plumbing

    private func makeWebViewIfNeeded() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = LoginDataStores.canvas
        // Without this the page's `window.open` is swallowed and the sign-in
        // never starts.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let duoHandler = DuoPromptMessageHandler { [weak self] event in
            switch event {
            case .push: self?.noteDuoPush()
            case .trusted: self?.noteDuoTrust()
            }
        }
        configuration.userContentController.add(duoHandler, name: DuoPromptAutoTap.handlerName)
        configuration.userContentController.addUserScript(DuoPromptAutoTap.makeUserScript())

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = false
        view.customUserAgent = LoginUserAgent.mobileSafari
        view.uiDelegate = self
        // Its only job is to hear that the content process died, so the next
        // sign-in loads the page again instead of reading a blank view.
        let delegate = PathMainDelegate(portal: self)
        view.navigationDelegate = delegate
        self.mainDelegate = delegate
        self.configuration = configuration
        self.webView = view
        return view
    }

    private func noteDuoPush() {
        if !loggedDuoPush {
            loggedDuoPush = true
            log("duo: push sent")
        }
        markDuoReached()
    }

    private func noteDuoTrust() {
        guard !loggedDuoTrust else { return }
        loggedDuoTrust = true
        log("duo: trust tapped")
    }

    private func markDuoReached() {
        // Only inside an attempt: a Duo message that lands after it ended must
        // not raise the status with nobody left to restore it.
        guard attemptRunning, !duoReached else { return }
        log("duo reached")
        duoReached = true
        duoReachedAt = Date()
        onDuoReached?()
    }

    private func releasePopup() {
        popup?.stopLoading()
        popup?.navigationDelegate = nil
        popup?.uiDelegate = nil
        popup = nil
        popupDelegate = nil
    }

    /// Present the Keychain's Canvas session first: a fresh WebView has none
    /// (WebKit drops session cookies between launches), and Penn's SSO would
    /// send the popup to the login form. Same fix as `EdSessionLauncher`.
    private func inject(_ cookies: [HTTPCookie]) async {
        for cookie in cookies {
            await LoginDataStores.canvas.httpCookieStore.setCookie(cookie)
        }
    }

    private func readiness() async -> PathBridgeDecoder.Readiness? {
        guard let json = await run(PathScripts.readiness, name: "readiness") else { return nil }
        return PathBridgeDecoder.readiness(json)
    }

    /// Runs one `PathScripts` body in the page's own world (its globals live
    /// there) and returns the JSON string it produced, or nil on any failure.
    ///
    /// The completion-handler form (two `in` labels: frame, then content
    /// world), not the `async throws` overload: that one returns `Any?`,
    /// which is not `Sendable`, and letting it cross an await is the
    /// "sending value risks causing data races" error `EdDiscussionProbe`
    /// and `CanvasSessionRenewer` already hit and document. The result is
    /// narrowed to a `String?` inside the handler, before it crosses the
    /// continuation.
    private func run(
        _ body: String,
        name: String,
        arguments: [String: Any] = [:],
        timeout: TimeInterval = PathPortal.scriptTimeout
    ) async -> String? {
        guard let view = webView else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // The page may never settle its promise, and the continuation must
            // resume exactly once whichever of the call and the timer comes
            // first; the late one is dropped by the box. A task group that
            // awaited the hung call would hang with it, which is the wrong fix.
            let box = PathOneShot(continuation)
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case let .success(value):
                    box.finish(value as? String)
                case .failure:
                    box.finish(nil)
                }
            }
            let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                if box.finish(nil) { self?.log("script timed out: \(name)") }
            }
        }
    }

    /// Two tiny page scripts of the portal's own, outside `PathScripts` on
    /// purpose: they read and write nothing but a marker on `window`.
    private static let markStaleScript = "window.__smoothStale = true; return \"ok\";"
    private static let freshnessScript = "return window.__smoothStale ? \"stale\" : \"fresh\";"

    private func log(_ line: String) {
        #if DEBUG
        DebugDegreeLog.record(line)
        #endif
    }
}

/// Watches the sign-in popup. Observe-only: it never cancels or redirects a
/// navigation, and leaves every decision to `PathPortal`.
@MainActor
private final class PathPopupDelegate: NSObject, WKNavigationDelegate {
    private weak var portal: PathPortal?

    init(portal: PathPortal) {
        self.portal = portal
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        portal?.popupDidFinish(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        portal?.popupDidFail(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        portal?.popupDidFail(webView, error: error)
    }
}

/// Resumes a continuation exactly once, from whichever thread gets there first.
/// `finish` returns true only for the call that actually resumed it.
private final class PathOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ value: String?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(returning: value)
        return true
    }
}

/// Hears that the main page's content process was killed (WebKit reclaims it
/// under memory pressure). Nothing else.
@MainActor
private final class PathMainDelegate: NSObject, WKNavigationDelegate {
    private weak var portal: PathPortal?

    init(portal: PathPortal) {
        self.portal = portal
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        portal?.contentProcessDied()
    }
}
