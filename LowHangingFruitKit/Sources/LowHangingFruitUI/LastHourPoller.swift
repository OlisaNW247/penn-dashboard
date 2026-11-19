import Foundation
import LowHangingFruitKit

/// Runs the last-hour poll while the dashboard is on screen: once a minute,
/// and only while a Sweeper alarm is within an hour of ringing, ask Canvas's
/// planner whether the work has been handed in (`LastHourPoll.cadence` decides
/// every tick, so a student with no alarm near costs Canvas nothing).
///
/// **Foreground only, and owned by `ContentView`** beside the 5-minute loop:
/// started when the scene is active, stopped on `.background` only.
/// A `Task` created from the main actor and sleeping in this class never
/// reaches a system-queue closure, which is the shape of the background-
/// refresh crash (CLAUDE.md → Traps); the background wake has its own single
/// read (`pollPlannerWindowIfInsideTheHour(source: .bg)`).
///
/// **It never calls the grades fetch** and so is not under its 15-minute
/// throttle: it makes one planner request, nothing chained to it.
///
/// **Back-off.** A 403 rate-limit answer, or fewer than `lowBucket` requests
/// remaining in Canvas's bucket, stops the polling for `backOff` (five
/// minutes, the ordinary refresh tick) and counts it. No session to ask with
/// does the same without the count. The alarm is unaffected by any of it:
/// it stays armed, and only a confirmed `.submitted` read ever cancels it.
@MainActor
final class LastHourPoller {
    static let lowBucket: Double = 100
    static let backOff: TimeInterval = 5 * 60

    private let clock: () -> Date
    private let sleeper: (TimeInterval) async -> Void
    private let countsDefaults: UserDefaults
    /// DEBUG trace sink: one fixed-vocabulary word per line, never an id,
    /// title or URL. The default writes `DebugWakeLog` (to `.lhf`) in DEBUG
    /// only; a test injects a capture, as it injects `countsDefaults`.
    private let log: (String) -> Void
    private var lastTickWord: String?
    private var task: Task<Void, Never>?
    private(set) var lastPoll: Date?
    private(set) var backedOffUntil: Date?

    init(
        clock: @escaping () -> Date = { Date() },
        countsDefaults: UserDefaults = .lhf,
        log: ((String) -> Void)? = nil,
        sleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.clock = clock
        self.countsDefaults = countsDefaults
        self.sleeper = sleep
        if let log {
            self.log = log
        } else {
            self.log = { word in
                #if DEBUG
                DebugWakeLog.record(source: .poll, outcome: word, duration: 0,
                                    cancelledRequests: 0, cancelledAlarms: 0, defaults: countsDefaults)
                #endif
            }
        }
    }

    var isRunning: Bool { task != nil }

    /// The app's wiring: the next ring from the scheduler's own rule (the same
    /// one the Sweeper page's card uses) and a read through `AppState`.
    func start(state: AppState, scheduler: NotificationScheduler, vm: DashboardViewModel,
               reason: StartReason = .task) {
        start(
            reason: reason,
            nextRing: { [weak scheduler, weak vm] in
                guard let scheduler, let vm else { return nil }
                return scheduler.nextSweep(in: vm.items)?.ringAt
            },
            poll: { [weak state] ring in
                guard let state else { return nil }
                let did = await state.pollPlannerWindowIfInsideTheHour(nextRing: ring, source: .poll)
                return did ? state.lastPlannerWindowResult : nil
            })
    }

    /// The loop, with its inputs injected. Starting twice keeps the first.
    func start(
        reason: StartReason = .task,
        nextRing: @escaping @MainActor () -> Date?,
        poll: @escaping @MainActor (Date?) async -> PlannerWindowResult?
    ) {
        guard task == nil else { return }
        log("poller start \(reason.rawValue)")
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let decision = await self.tick(nextRing: nextRing(), poll: poll)
                let now = self.clock()
                var wait: TimeInterval = 60
                if case let .wait(until) = decision { wait = max(1, until.timeIntervalSince(now)) }
                await self.sleeper(min(wait, 60))
            }
        }
    }

    /// Fixed vocabularies for the trace (DebugWakeLog rule): why a poller
    /// started or stopped, so the next trace says which caller revived it.
    enum StartReason: String { case active, task, settle }
    enum StopReason: String { case background, inactive, other }

    func stop(reason: StopReason = .other) {
        if task != nil { log("poller stop \(reason.rawValue)") }
        task?.cancel()
        task = nil
    }

    /// One step: ask the cadence, and poll if it says so. Returns the decision
    /// it acted on, so a test can walk a clock through it.
    @discardableResult
    func tick(nextRing: Date?, poll: @MainActor (Date?) async -> PlannerWindowResult?) async -> PollDecision {
        let now = clock()
        let decision = LastHourPoll.cadence(
            now: now, nextRing: nextRing, lastPoll: lastPoll, backedOffUntil: backedOffUntil)
        let word: String
        if let nextRing {
            if nextRing <= now { word = "tick past-ring" }
            else if nextRing.timeIntervalSince(now) > 3600 { word = "tick far-ring" }
            // Inside the hour, waiting for the minute and polling are one
            // state for the trace: the poll itself writes "planner ok", and
            // two alternating words would fill the 50-line log in half an hour.
            else { word = "tick poll" }
        } else { word = "tick nil-ring" }
        if word != lastTickWord { lastTickWord = word; log(word) }
        guard case .poll = decision else { return decision }
        lastPoll = now
        guard let result = await poll(nextRing) else {
            // Nothing to ask with (no saved session): wait out the back-off
            // rather than ask again next minute.
            backedOffUntil = now.addingTimeInterval(Self.backOff)
            return decision
        }
        if result.rateLimited || (result.remaining.map { $0 < Self.lowBucket } ?? false) {
            backedOffUntil = now.addingTimeInterval(Self.backOff)
            SweeperCounts.increment(SweeperCounts.pollsBackedOff, defaults: countsDefaults)
        }
        return decision
    }
}
