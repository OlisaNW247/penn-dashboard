import Foundation
import LowHangingFruitKit

// MARK: – The last-hour planner read, applied
//
// While a Sweeper alarm is within the hour of ringing, one small Canvas
// request (the planner, `CanvasStructuredSourcesClient.fetchPlannerWindow`)
// is asked every minute whether the work was handed in. This file is the
// applier. It is deliberately narrower than `applyStructuredSources`:
//
//  - it applies a CONFIRMED submitted read and nothing else. A planner
//    `submitted` flag or a Planner tick adds the card's ledger ids to
//    `structuredCompletedItemIDs` (additive, the same set the full run
//    writes) and cancels the alarm. It never touches dismissals, section
//    dates, module rows or completion overrides: a one-page window is silent
//    about all of those, and silence must never drop anything.
//  - an `.unsubmitted` or `.unknown` read changes nothing. The alarm was
//    armed days ago and only a confirmed submission takes it back (Marco,
//    2026-11-18).
//  - an incomplete answer (rate limit, 401, a cut-off page) applies nothing
//    at all, not even its submitted items, so a half-read page can never be
//    mistaken for the truth. It is counted (`SweeperCounts.readsUnknown`).
//  - it never calls `markCompleted` or writes a completion as the student's
//    own: the set it adds to is the Canvas-derived one, which
//    `isCompleted` consults beside the ledger (CLAUDE.md → Traps, "Canvas-
//    derived completions, dismissals and dates are not student edits").

extension AppState {
    /// Applies one planner window read. Returns the reads that were made: the
    /// real verdicts for a complete answer, and every item as `.unknown` for
    /// an incomplete one (so a caller can see that something was read and
    /// nothing was believed).
    @discardableResult
    func applyPlannerWindow(_ result: PlannerWindowResult, now: Date = Date()) -> [SubmissionRead] {
        guard FeatureFlags.structuredCanvasSources, !isUsingFixtureData else { return [] }
        let reads = SubmissionRead.verdicts(fromPlanner: result.items, readAt: now)
        guard result.completed, !result.rateLimited, !result.sessionExpired else {
            SweeperCounts.increment(SweeperCounts.readsUnknown, defaults: sweeperCountsDefaults)
            return reads.map {
                SubmissionRead(assignmentID: $0.assignmentID, readAt: now, source: .planner, verdict: .unknown)
            }
        }

        let submitted = reads.filter(\.cancels)
        guard !submitted.isEmpty else { return reads }

        // Resolve each Canvas assignment id to ledger ids the way
        // `applyStructuredSources` does: feed rows and module rows alike.
        let ledger: [Assignment] = assignmentStore.map {
            $0.assignments(source: .canvas) + $0.assignments(source: .canvasModules)
        } ?? (canvasItems + moduleReadingItems)
        var newlyCompleted = Set<String>()
        var canvasIDsForNewlyCompleted = Set<String>()
        for read in submitted {
            let ledgerIDs = ledger.filter { $0.canvasAssignmentID == read.assignmentID }.map(\.id)
            let fresh = Set(ledgerIDs)
                .subtracting(structuredCompletedItemIDs)
                .subtracting(structuredCompletionOverrides)
            guard !fresh.isEmpty else { continue }
            newlyCompleted.formUnion(fresh)
            canvasIDsForNewlyCompleted.insert(read.assignmentID)
        }
        guard !newlyCompleted.isEmpty else { return reads }

        structuredCompletedItemIDs.formUnion(newlyCompleted)
        saveStructuredState()
        rebuildDashboardItems(now: now)
        noteSubmittedIDs(newlyCompleted.union(canvasIDsForNewlyCompleted), source: .poll)
        return reads
    }

    /// The planner read itself, with the saved session. Nil only when there is
    /// nothing at all to ask with (no live WebKit cookie, no persisted one, no
    /// token), or under fixture data; the caller then records an unknown read.
    /// The persisted store alone must not decide: `SessionCookieStore.load`
    /// applies the 24-hour clock rule and the live-session gate, so a day after
    /// the last save it reads empty while the WebKit login store still holds a
    /// live session every other Canvas read uses (2026-11-21: nine unknown
    /// reads in 46 minutes on Marco's phone with a live session, a real
    /// submission never seen). So the live-merged cookies come first and the
    /// guard is the grades fetch's rule. The wrong fixes: dropping the guard
    /// (an empty jar sends a request Canvas answers 401, a noisy planner-level
    /// unknown) or widening `hasCanvasCredentials`, which has other callers with
    /// other meanings. A test seam replaces the network.
    func fetchPlannerWindowForPoll(start: Date, end: Date) async -> PlannerWindowResult? {
        guard FeatureFlags.structuredCanvasSources, !isUsingFixtureData else { return nil }
        if let seam = plannerWindowFetchForTesting { return await seam(start, end) }
        let cookies = await AutoSyncCoordinator.canvasCookies(forHost: canvasInstallation.host)
        guard !cookies.isEmpty || hasCanvasCredentials else { return nil }
        let client = CanvasStructuredSourcesClient(
            baseURL: canvasBaseURL, cookies: cookies, accessToken: canvasAccessTokenBearer)
        return await client.fetchPlannerWindow(start: start, end: end)
    }

    /// One planner read, when and only when an alarm is within the hour. The
    /// one method the launch, the foreground, the background wake and the
    /// poller's tick all call, so "inside the hour" is decided in one place.
    /// It never calls the grades fetch and is not subject to its 15-minute
    /// throttle (`canvasGradesMinInterval`) by construction. `nextRing` is the
    /// soonest Sweeper ring (`NotificationScheduler.nextSweep`), which the
    /// callers own because the scheduler is the view layer's. Returns whether
    /// a read was made. Foreground and wake callers only; a failure is a
    /// counted unknown, never an error.
    @discardableResult
    func pollPlannerWindowIfInsideTheHour(nextRing: Date?, source: WakeSource, now: Date = Date()) async -> Bool {
        guard LastHourPoll.insideTheHour(now: now, nextRing: nextRing) else { return false }
        return await pollPlannerWindow(source: source, now: now)
    }

    /// The read itself, with no hour check: the one body both the hour-gated
    /// callers above and a server wake share, so the counting and the DEBUG
    /// line exist once. A push wake calls it directly because the server only
    /// sends inside the window (`docs/SERVER_SWEEPER_DESIGN_2026-11-17.md` §4),
    /// and the phone's own idea of "the next ring" may be missing in a cold
    /// process that has not built a dashboard.
    @discardableResult
    func pollPlannerWindow(source: WakeSource, now: Date = Date()) async -> Bool {
        let window = LastHourPoll.window(now: now)
        guard let result = await fetchPlannerWindowForPoll(start: window.start, end: window.end) else {
            SweeperCounts.increment(SweeperCounts.readsUnknown, defaults: sweeperCountsDefaults)
            #if DEBUG
            DebugWakeLog.record(source: source, outcome: "planner no-session",
                                duration: Date().timeIntervalSince(now), cancelledRequests: 0, cancelledAlarms: 0)
            #endif
            return false
        }
        applyPlannerWindow(result, now: Date())
        SweeperCounts.increment(SweeperCounts.polls, defaults: sweeperCountsDefaults)
        lastPlannerWindowResult = result
        #if DEBUG
        DebugWakeLog.record(source: source, outcome: result.completed ? "planner ok" : "planner unknown",
                            duration: Date().timeIntervalSince(now), cancelledRequests: 0, cancelledAlarms: 0)
        #endif
        return true
    }
}
