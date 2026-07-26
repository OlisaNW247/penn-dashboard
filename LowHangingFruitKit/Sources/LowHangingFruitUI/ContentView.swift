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
    @State private var showAddSheet = false
    /// The pushed pages behind the header's two buttons. A path rather than two
    /// booleans so the screenshot flag can open Settings directly.
    @State private var path: [DashRoute] = []

    /// Where the header's buttons lead. Both are pushes onto the dashboard's own
    /// stack, so Settings and Grades are full screens with a back button rather
    /// than cards presented over the list.
    /// `report` carries its own course identity so the stack can be restored
    /// (or, in DEBUG, seeded straight to the report for screenshots) without
    /// walking through the cards.
    enum DashRoute: Hashable {
        case settings
        case grades
        case report(courseID: String, courseName: String)
    }

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
        NavigationStack(path: $path) {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    header
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
            .navigationDestination(for: DashRoute.self) { route in
                switch route {
                case .settings:
                    SettingsPage()
                        .environmentObject(state)
                        .environmentObject(scheduler)
                case .grades:
                    GradeWatcherView(store: state.gradeWatcher)
                        .environmentObject(state)
                case let .report(courseID, courseName):
                    GradeReportView(store: state.gradeWatcher, courseID: courseID, courseName: courseName)
                        .environmentObject(state)
                }
            }
        }
        // Class renames live in AppState but are read by the cards, which are
        // deliberately AppState-free so they still render in previews.
        .environment(\.courseNameOverrides, state.courseNameOverrides)
        .onAppear {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-LHFDemoData") {
                // Seed AppState too, so the Settings class list has courses.
                state.loadSampleData()
                vm.loadSampleData()
                state.gradeWatcher.loadPreviewSnapshots(SampleData.gradeSnapshots())
                if args.contains("-LHFShowSettings") { path = [.settings] }
                if args.contains("-LHFShowGrades") { path = [.grades] }
                if args.contains("-LHFShowReport") {
                    // Deepest screenshot target: Grades → the full report for
                    // the richest fixture course.
                    let course = SampleData.previewCourseIDsByID
                        .sorted { $0.key < $1.key }
                        .first
                    if let course {
                        path = [.grades, .report(courseID: course.key, courseName: course.value)]
                    }
                }
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
        .sheet(isPresented: $showAddSheet, onDismiss: rescheduleNotifications) {
            AddAssignmentSheet()
                .environmentObject(state)
        }
        // Settings is a push now, so there's no sheet-dismiss hook to hang this
        // on: returning to the dashboard is the moment class toggles, deletions
        // and renames need to be reflected in the list and in reminders.
        .onChange(of: path) { _, newPath in
            guard newPath.isEmpty else { return }
            vm.reload(preservingEdits: true)
            rescheduleNotifications()
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

    /// Wordmark, greeting and date on the left; the two destinations stacked on
    /// the right, where the weekly ring used to sit. There's no manual reload —
    /// opening the app auto-refreshes — so these are the only header controls.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LHF")
                    .font(.lhfSans(11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(Color.v2CourseCode)

                Text(greeting)
                    .font(.lhfSerif(27))
                    .foregroundStyle(Color.v2Ink)

                Text(Self.dateText(Date()))
                    .font(.lhfSerif(15))
                    .foregroundStyle(Color.v2DateText)
                    .padding(.top, 2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                navButton(to: .grades, icon: "chart.line.uptrend.xyaxis", title: "Grades")
                navButton(to: .settings, icon: "gearshape.fill", title: "Settings")
            }
            .padding(.top, 2)
        }
    }

    /// Matching circular icons, side by side, so neither destination reads as
    /// secondary to the other; Settings sits in the corner. Labels live in the
    /// accessibility layer only.
    private func navButton(to route: DashRoute, icon: String, title: String) -> some View {
        NavigationLink(value: route) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.v2DateText)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.v2Ink.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
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
        await AutoSyncCoordinator.refreshCanvasGrades(state: state)
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
