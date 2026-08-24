import SwiftUI
import LowHangingFruitKit
#if os(macOS)
import AppKit
#endif

/// The shipping app's `@main` scene (docs/LAPTOP_INTEGRATION_PLAN.md Tier 1).
/// Owns the single `AppState`/`NotificationScheduler` pair at the *Scene*
/// level — above any individual window — so the main `WindowGroup` and the
/// macOS menu-bar extra both read and drive the same state instead of each
/// holding a private copy. `App/LHFApp.swift` just presents `LHFScenes()`.
public struct LHFScenes: Scene {
    @StateObject private var state = AppState()
    @StateObject private var scheduler = NotificationScheduler()

    public init() {}

    public var body: some Scene {
        WindowGroup("Low Hanging Fruit", id: "main") {
            RootCore(state: state, scheduler: scheduler)
        }
#if os(macOS)
        MenuBarExtra {
            MenuBarPanel(state: state, scheduler: scheduler)
        } label: {
            MenuBarLabel(state: state, scheduler: scheduler)
        }
        .menuBarExtraStyle(.window)
#endif
    }
}

#if os(macOS)

/// The menu-bar item itself: a monochrome-safe glyph plus the near/overdue
/// count, when there is one.
///
/// **This is the label-anchored-loop trick.** A `MenuBarExtra`'s `label`
/// view is the one piece of `LHFScenes`' UI that's guaranteed to be alive for
/// the entire run of the app — the main window can be closed (macOS apps
/// don't quit when their last window does) and the popover's `content` view
/// only exists while the popover is open, but the label in the menu bar
/// itself never goes away. Anchoring the persistent 5-minute sync loop to its
/// `.task` — rather than to `ContentView`, whose window the user might close
/// — is what makes the loop actually persistent.
///
/// macOS has none of iOS's background-execution restrictions (docs/
/// BACKGROUND_REFRESH_PLAN.md documents why that guarantee is structurally
/// impossible there). A menu-bar app is simply allowed to run a task
/// forever, so this loop is legal to run indefinitely rather than needing to
/// be re-armed like `LHFBackgroundRefresh`'s `BGTaskScheduler` requests.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var scheduler: NotificationScheduler
    /// Its own `DashboardViewModel`, independent of whichever one (if any)
    /// `ContentView`'s window currently owns — the label has to keep syncing
    /// even while no window exists, so it can't borrow one. `reschedule(from:)`
    /// only needs the override-aware `items` list, so this mirrors exactly
    /// what `ContentView.refresh()` feeds it.
    @StateObject private var vm = DashboardViewModel()

    /// Same cadence as `ContentView.autoRefreshInterval` — kept as a separate
    /// constant because that one is `private` to `ContentView`. See that
    /// file's doc comment for why 5 minutes was chosen.
    private static let autoRefreshInterval: UInt64 = 5 * 60 * 1_000_000_000

    var body: some View {
        Label {
            if dueCount > 0 {
                Text("\(dueCount)")
            }
        } icon: {
            // "basket" (low-hanging fruit) is on-brand and renders as a plain
            // template glyph in the menu bar like any other status item.
            Image(systemName: "basket")
        }
        .task {
            vm.bind(to: state)
            // An immediate sync covers "the Mac just woke up / the app just
            // launched" the same way ContentView's own `.task` does before
            // its loop starts.
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.autoRefreshInterval)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    /// Near/overdue load, same pool `ContentView`'s header would imply.
    private var dueCount: Int { state.assignments.count }

    /// Mirrors `ContentView.refresh()` exactly — same calls, same order,
    /// including the scheduler drains for grade changes and "turned in"
    /// confirmations. Kept as a literal copy rather than a shared helper
    /// because `ContentView`'s version is `private` and reaches into its own
    /// `vm`; duplicating a few lines here is simpler than threading a shared
    /// entry point through both call sites for a loop this small.
    private func refresh() async {
        await state.syncIfConfigured()
        await AutoSyncCoordinator.syncConnectedServices(state: state)
        await AutoSyncCoordinator.refreshCanvasGrades(state: state)
        state.refreshCanvasSessionExpiredState()
        vm.reload(preservingEdits: true)
        if scheduler.isEnabled { await scheduler.reschedule(from: vm.items) }
        await announceGradeChanges()
        await announceTurnedIn()
    }

    /// Same drain as `ContentView.announceTurnedIn()`.
    private func announceTurnedIn() async {
        let notices = state.pendingTurnedInNotices
        guard !notices.isEmpty else { return }
        state.pendingTurnedInNotices = []
        await scheduler.postTurnedInNotifications(notices)
    }

    /// Same drain as `ContentView.announceGradeChanges()`.
    private func announceGradeChanges() async {
        let changes = state.pendingGradeChanges
        guard !changes.isEmpty else { return }
        state.pendingGradeChanges = []
        await scheduler.notifyGradeChanges(changes)
    }
}

/// The popover a click on the menu-bar item opens: a condensed "Due next"
/// list plus a way back into the full window. Reads `AppState`'s already-
/// grouped `Assignment` arrays directly rather than through a
/// `DashboardViewModel` — the popover has no per-item editing (no swipe, no
/// due-date override), so the raw model is enough.
struct MenuBarPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var scheduler: NotificationScheduler
    @Environment(\.openWindow) private var openWindow

    private static let maxRows = 5

    /// Soonest-due first, across both the near and later pools, capped at
    /// five. Undated items are excluded — there's nothing to sort them
    /// against, and this panel is specifically "due next".
    private var upcoming: [Assignment] {
        (state.assignments + state.laterAssignments)
            .filter { $0.dueAt != nil }
            .sorted { $0.dueAt! < $1.dueAt! }
            .prefix(Self.maxRows)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Due next")
                .font(.lhfSans(12, weight: .semibold))
                .foregroundStyle(Color.v2Ink)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if upcoming.isEmpty {
                Text("Nothing due \u{2014} you're all caught up.")
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.v2DateText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(upcoming) { assignment in
                        row(for: assignment)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Button("Open Low Hanging Fruit") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.plain)
                .font(.lhfSans(12, weight: .medium))
                .foregroundStyle(Color.v2Ink)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2DateText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .background(Color.v2Bg)
    }

    /// Title, course, and a book marker for non-submission calendar entries —
    /// the same convention `AssignmentCardView.content(state:now:)` uses.
    private func row(for assignment: Assignment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if assignment.kind == .event {
                        Image(systemName: "book")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color.v2CourseCode)
                    }
                    Text(state.courseDisplayName(assignment.course).uppercased())
                        .font(.lhfSans(9, weight: .medium))
                        .tracking(1.0)
                        .foregroundStyle(Color.v2CourseCode)
                }
                Text(assignment.title)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2Ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(dueText(assignment.dueAt))
                .font(.lhfSans(10, weight: .medium))
                .foregroundStyle(DueState(due: assignment.dueAt).dueTextColor)
        }
    }
}

#endif
