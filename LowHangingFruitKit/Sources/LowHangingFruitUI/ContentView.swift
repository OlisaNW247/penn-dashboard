import SwiftUI
import LowHangingFruitKit

/// Redesigned root screen: header (wordmark + date + weekly ring), a three-way
/// segmented toggle, and a timeline/done list. All data is read through
/// `DashboardViewModel`, which layers on top of the untouched `AppState`.
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var scheduler: NotificationScheduler
    @StateObject private var vm: DashboardViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var filter: DashFilter = .thisWeek
    @State private var editing: DashItem?
    @State private var showSettings = false
    @State private var showAddSheet = false

    /// How often to silently re-sync while the dashboard is open. 5 minutes is a
    /// gentle cadence for an academic dashboard (assignments rarely change minute
    /// to minute) and is easy on the Canvas servers; an immediate sync on app
    /// activation covers the "I just opened the app" case.
    private static let autoRefreshInterval: UInt64 = 5 * 60 * 1_000_000_000

    init(previewVM: DashboardViewModel? = nil) {
        _vm = StateObject(wrappedValue: previewVM ?? DashboardViewModel())
        #if DEBUG
        // Screenshot seam: pick the initial tab from launch flags. (Settings is
        // opened from onAppear, after data loads, so it presents reliably.)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-LHFTabAll") { _filter = State(initialValue: .all) }
        else if args.contains("-LHFTabDone") { _filter = State(initialValue: .done) }
        #endif
    }

    var body: some View {
        let progress = vm.weeklyProgress()

        ZStack(alignment: .bottomTrailing) {
        VStack(spacing: 0) {
            header(progress: progress)
                .padding(.horizontal, 20)
                .padding(.top, 8)

            SegmentedToggle(selection: $filter)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ScrollView {
                listContent
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.items)
            }
        }

            addButton
        }
        .background(Color.v2Bg.ignoresSafeArea())
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-LHFDemoData") {
                // Seed AppState too, so the Settings class list has courses.
                state.loadSampleData()
                vm.loadSampleData()
                if args.contains("-LHFShowSettings") { showSettings = true }
                return
            }
            #endif
            // Reviewer/demo preview: show bundled sample data instead of binding
            // to the (empty, un-synced) real store. No network, no login.
            if state.isPreviewMode {
                vm.loadSampleData()
                return
            }
            vm.bind(to: state)
        }
        .task {
            // Silent auto-refresh loop while the dashboard is on screen.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.autoRefreshInterval)
                if Task.isCancelled { break }
                await refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await scheduler.refreshAuthStatus()
                    await refresh()
                }
            }
        }
        .sheet(item: $editing, onDismiss: rescheduleNotifications) { item in
            EditDueSheet(
                assignment: item.assignment,
                overrideDate: Binding(
                    get: { vm.items.first(where: { $0.id == item.id })?.dueOverride },
                    set: { vm.setDue(item, to: $0) }
                )
            )
        }
        .sheet(isPresented: $showSettings, onDismiss: rescheduleNotifications) {
            SettingsSheet()
                .environmentObject(state)
                .environmentObject(scheduler)
        }
        .sheet(isPresented: $showAddSheet, onDismiss: rescheduleNotifications) {
            AddAssignmentSheet()
                .environmentObject(state)
        }
    }

    /// Floating "+" to add a user-created assignment (one-off or recurring).
    private var addButton: some View {
        Button { showAddSheet = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.v2ToggleActiveTx)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.v2Ink))
                .shadow(color: Color.v2CardShadow.opacity(0.28), radius: 7, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add assignment")
        .padding(.trailing, 22)
        .padding(.bottom, 24)
    }

    /// Reschedule due-date reminders from the current (override-aware) items.
    private func rescheduleNotifications() {
        guard scheduler.isEnabled else { return }
        Task { await scheduler.reschedule(from: vm.items) }
    }

    // MARK: Header

    private func header(progress: (done: Int, total: Int)) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LHF")
                    .font(.lhfSans(11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Color.v2CourseCode)

                Text(greeting)
                    .font(.lhfSerif(27))
                    .foregroundStyle(Color.v2Ink)

                HStack(spacing: 10) {
                    Text(Self.dateText(Date()))
                        .font(.lhfSerif(15))
                        .foregroundStyle(Color.v2DateText)

                    // The only header control: a clearly-labeled Settings button.
                    // There's no manual reload — opening the app auto-refreshes.
                    Button { showSettings = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Settings")
                                .font(.lhfSans(12, weight: .semibold))
                        }
                        .foregroundStyle(Color.v2DateText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.v2Ink.opacity(0.07)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings and accounts")
                    .help("Settings & accounts")
                }
                .padding(.top, 2)
            }

            Spacer()

            ProgressRingView(done: progress.done, total: progress.total)
        }
    }

    private var greeting: String {
        state.userName.isEmpty ? "Hello" : "Hello, \(state.userName)"
    }

    /// Silent refresh: re-fetch the cookieless Canvas feed, re-sync Gradescope
    /// from its persisted session, then reload the dashboard. Runs on launch,
    /// on activation, and on the 5-minute loop — there's no manual sync button.
    private func refresh() async {
        await state.syncIfConfigured()
        await AutoSyncCoordinator.syncConnectedServices(state: state)
        vm.reload(preservingEdits: true)
        if scheduler.isEnabled { await scheduler.reschedule(from: vm.items) }
    }

    // MARK: List

    @ViewBuilder
    private var listContent: some View {
        switch filter {
        case .thisWeek: timeline(sections: vm.thisWeekSections())
        case .all:      timeline(sections: vm.allSections())
        case .done:
            DoneView(
                sections: vm.doneSections(),
                weeklyDone: vm.weeklyProgress().done,
                onUncomplete: { item in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.uncomplete(item)
                    }
                    rescheduleNotifications()
                }
            )
        }
    }

    @ViewBuilder
    private func timeline(sections: [DashSection]) -> some View {
        if sections.isEmpty {
            allDoneState
        } else {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(sections) { section in
                    TimelineSectionView(
                        section: section,
                        onComplete: { item in
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                vm.complete(item)
                            }
                            rescheduleNotifications()
                        },
                        onEdit: { item in editing = item }
                    )
                }
            }
        }
    }

    private var allDoneState: some View {
        ZStack {
            if let img = bundledImage("chill", ext: "jpg") {
                img
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .blendMode(.multiply)
                    .opacity(0.35)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                Text("Go enjoy Life")
                    .font(.lhfSerif(46))
                    .foregroundStyle(Color.v2Ink)
                Text("you're all caught up")
                    .font(.lhfSans(15))
                    .foregroundStyle(Color.v2DateText.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Date

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"   // "Tuesday, May 26"
        return f.string(from: date)
    }
}

#if DEBUG
#Preview {
    let vm = DashboardViewModel()
    vm.loadSampleData()
    return ContentView(previewVM: vm)
        .environmentObject(AppState())
        .environmentObject(NotificationScheduler())
        .frame(width: 430, height: 880)
}
#endif
