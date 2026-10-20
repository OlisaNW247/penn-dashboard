import SwiftUI

/// Puts the Berserk takeover over the whole window and keeps it honest.
///
/// It listens to three things and re-decides each time:
/// - AlarmKit, while the app is active (`alertingAlarmIDs`/`alertingUpdates`
///   on the scheduler's backend), so the screen appears the moment Smooth is on
///   screen with an alarm ringing, and goes when the alarm stops;
/// - the signals the notification delegate files in `BerserkTakeoverModel`
///   (a loud buzz tapped or landing while the app is open);
/// - the scheduler's `rescheduleGeneration`, which is how it learns that the
///   dashboard has handed over a fresh item list (a signal the host could not
///   yet trace to an item waits for exactly that).
///
/// The rules are `BerserkTakeoverRules`; this file only wires them to the
/// outside world and runs the effects of a choice. It reads `AppState` and
/// never writes it: completing an item goes through the same inbox a
/// notification button uses, so `ContentView` does it exactly as it would for
/// that button.
@MainActor
struct BerserkTakeoverHost: ViewModifier {
    @ObservedObject var state: AppState
    @ObservedObject var scheduler: NotificationScheduler
    @ObservedObject private var model = BerserkTakeoverModel.shared

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    init(state: AppState, scheduler: NotificationScheduler) {
        self.state = state
        self.scheduler = scheduler
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let current = model.current {
                    BerserkTakeoverView(takeover: current, now: Date()) { choice in
                        apply(choice, to: current)
                    }
                    .transition(.opacity)
                }
            }
            .task(id: scenePhase) { await listen() }
            .onChange(of: model.pending) { _, _ in resolve() }
            .onChange(of: scheduler.rescheduleGeneration) { _, _ in resolve() }
    }

    // MARK: Listening

    /// Runs while the scene is active and is restarted (and the old run
    /// cancelled, ending the AlarmKit stream and the poll) whenever the phase
    /// changes.
    ///
    /// Resolves once up front even with no alarm backend, because a buzz
    /// tapped on a cold launch is filed before this view exists and there is
    /// no change for `onChange` to see. **And then, while anything is
    /// waiting, once a second.** A signal raised by a cold launch cannot be
    /// traced to an item until the dashboard has bound its view model, and
    /// the dashboard's first `reschedule` (what `rescheduleGeneration`
    /// counts) can be minutes away: its refresh loop sleeps five minutes
    /// before the first pass and `onChange(of: scenePhase)` does not fire
    /// for the phase the app starts in. Polling the live item list, which
    /// the dashboard registers at bind time, closes that gap without
    /// touching `ContentView`; it costs nothing while nothing waits, and a
    /// buzz that is never traced stops being polled for when it expires.
    private func listen() async {
        guard scenePhase == .active else { return }
        let backend = scheduler.activeAlarmBackend()
        if let backend, let ringing = backend.alertingAlarmIDs() {
            model.noteAlerting(ringing, at: Date())
        }
        resolve()

        // No backend (the Mac, iOS below 26): only the poll, in this task, so
        // cancelling the task ends it.
        guard let backend else {
            await pollWhileWaiting()
            return
        }
        // With a backend: the poll alongside the AlarmKit stream. Cancelling
        // this task ends the stream iteration, and the `defer` ends the poll.
        let poll = Task { await pollWhileWaiting() }
        defer { poll.cancel() }
        for await ids in backend.alertingUpdates() {
            model.noteAlerting(ids, at: Date())
            resolve(alerting: Set(ids))
        }
    }

    /// Once a second until cancelled: re-decides whenever something waits.
    private func pollWhileWaiting() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            if !model.pending.isEmpty { resolve() }
        }
    }

    // MARK: Deciding

    /// Re-decides what the screen shows, from the signals waiting, the
    /// dashboard's live items and what is ringing.
    ///
    /// When AlarmKit cannot be read (`alertingAlarmIDs` is nil) nothing is
    /// judged: a ringing alarm read as silent would be dismissed and
    /// remembered as answered. No backend at all (the Mac, iOS below 26) is
    /// a known empty set, not an unknown one.
    private func resolve(alerting: Set<UUID>? = nil) {
        let ringing: Set<UUID>?
        if let alerting {
            ringing = alerting
        } else if let backend = scheduler.activeAlarmBackend() {
            ringing = backend.alertingAlarmIDs().map { Set($0) }
        } else {
            ringing = []
        }
        guard let ringing else { return }

        let items = scheduler.itemsForPreferenceReschedule()
        if let current = model.current,
           BerserkTakeoverRules.shouldDismiss(current, alerting: ringing, items: items) {
            withAnimation { model.dismiss() }
        }
        let resolution = BerserkTakeoverRules.resolve(
            pending: model.pending,
            items: items,
            alerting: ringing,
            now: Date(),
            isUsingFixtureData: state.isUsingFixtureData,
            nameOverrides: state.courseNameOverrides)
        withAnimation { model.apply(resolution) }
    }

    // MARK: Answering

    private func apply(_ choice: BerserkTakeoverChoice, to takeover: BerserkTakeover) {
        for effect in BerserkTakeoverRules.effects(for: choice, takeover: takeover) {
            switch effect {
            case .stopAlarm(let id):
                scheduler.activeAlarmBackend()?.stopAlarm(id: id)
            case .silenceBuzzes(let assignmentID):
                scheduler.clearDeliveredLoudAlerts(forAssignmentID: assignmentID)
            case .deposit(let action):
                NotificationActionInbox.shared.deposit(action, arrivedAt: Date())
            case .openURL(let url):
                openURL(url)
            case .dismiss:
                withAnimation { model.dismiss() }
                // So a second ringing item follows the first.
                resolve()
            }
        }
    }
}

extension View {
    /// Covers the window with the Berserk takeover while an alarm rings or a
    /// loud buzz has just been tapped or has landed. Applied once, in
    /// `RootCore`.
    func berserkTakeoverHost(state: AppState, scheduler: NotificationScheduler) -> some View {
        modifier(BerserkTakeoverHost(state: state, scheduler: scheduler))
    }
}
