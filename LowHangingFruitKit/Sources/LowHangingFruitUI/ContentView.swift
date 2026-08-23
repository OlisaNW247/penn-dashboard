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

                    syncErrorBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    if state.canvasSessionExpired {
                        canvasSessionExpiredBanner
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                    }

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
        // `CourseProfileReport` isn't `Identifiable`, so this is
        // `.sheet(isPresented:)` driven off a Binding over `pendingCourseNudge`
        // rather than `.sheet(item:)`. Swipe-to-dismiss drives the setter with
        // `false` and only calls `dismissCourseNudge()` (ask again next
        // launch); the sheet's own two buttons call `resolveCourseNudge`
        // first, which writes a durable decision and clears the pending nudge
        // itself — the setter below then sees that as "already nil" and is a
        // no-op, not a second dismiss.
        .sheet(isPresented: courseNudgeBinding) {
            if let report = state.pendingCourseNudge {
                CourseNudgeSheet(
                    report: report,
                    onInclude: { state.resolveCourseNudge(report, include: true) },
                    onSkip: { state.resolveCourseNudge(report, include: false) }
                )
            }
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

    /// Drives the course-nudge sheet's presentation off `pendingCourseNudge`
    /// (see the `.sheet` comment above for the dismiss-vs-resolve distinction).
    private var courseNudgeBinding: Binding<Bool> {
        Binding(
            get: { state.pendingCourseNudge != nil },
            set: { isPresented in
                if !isPresented { state.dismissCourseNudge() }
            }
        )
    }

    // MARK: Canvas session banner

    /// Plain-language reconnect nudge (docs/CANVAS_LOGIN_HARDENING.md item
    /// 3d) — shown only when `state.canvasSessionExpired`, which is
    /// deliberately distinct from "Canvas isn't connected": a feed-only
    /// (paste-link) user, or one whose feed still syncs fine, never sees
    /// this. It's specifically about the cookie-authed login session behind
    /// automatic submission tracking and Canvas Scan going stale.
    private var canvasSessionExpiredBanner: some View {
        Button {
            state.restartOnboarding()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Canvas login needs a refresh")
                        .font(.lhfSans(12, weight: .semibold))
                    Text("Reconnect to keep automatic submission tracking accurate.")
                        .font(.lhfSans(11))
                        .foregroundStyle(Color.v2DateText)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.v2DateText)
            }
            .foregroundStyle(Color.v2Ink)
            .padding(12)
            .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Your Canvas login needs a refresh. Reconnect Canvas.")
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
                if FeatureFlags.gradeWatcher && state.canUseGradeWatcher {
                    navButton(to: .grades, icon: "chart.line.uptrend.xyaxis", title: "Grades")
                }
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
        state.refreshCanvasSessionExpiredState()
        vm.reload(preservingEdits: true)
        if scheduler.isEnabled { await scheduler.reschedule(from: vm.items) }
        await announceGradeChanges()
    }

    /// Drains any grades the refresh found had changed and posts them. Done
    /// after `reschedule` on purpose: that call clears pending requests, and
    /// draining afterwards keeps the ordering obvious even though grade
    /// notifications are delivered immediately rather than queued.
    private func announceGradeChanges() async {
        let changes = state.pendingGradeChanges
        guard !changes.isEmpty else { return }
        state.pendingGradeChanges = []
        await scheduler.notifyGradeChanges(changes)
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

    /// What the dashboard should show when there are no timeline sections to
    /// render. Distinguishes "still loading" and "sync failed" from a genuine
    /// "all caught up" — the old code always showed the celebratory empty state,
    /// so a student who opened the app mid-sync (or after a failed sync) with
    /// pending work was falsely told they were done.
    private enum DashboardStatus: Equatable {
        case loading
        case error(String)
        case caughtUp
    }

    /// Only meaningful when the visible tab has no sections. Uses the whole
    /// `vm.items` pool (not the filtered sections) so a background refresh can't
    /// flip an already-populated screen back to a spinner: once we have ANY real
    /// item, an empty "this week" genuinely means caught up for the week.
    private var emptyStateStatus: DashboardStatus {
        if !vm.items.isEmpty { return .caughtUp }
        if state.isLoading || state.isGradescopeLoading { return .loading }
        if let error = state.error { return .error(error) }
        // Connected but the first sync hasn't landed yet: treat as loading, not
        // "all caught up", so the very first frame after launch isn't a false
        // celebration before `refresh()` sets `isLoading`.
        if state.isCanvasConnected && state.lastSync == nil { return .loading }
        return .caughtUp
    }

    @ViewBuilder
    private func timeline(sections: [DashSection]) -> some View {
        if sections.isEmpty {
            switch emptyStateStatus {
            case .loading:            loadingState
            case let .error(message): errorState(message)
            case .caughtUp:           allDoneState
            }
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

    /// Shown in place of the "all caught up" art while the first sync is still in
    /// flight, so an empty screen doesn't read as "you're done".
    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading your assignments…")
                .font(.lhfSans(15))
                .foregroundStyle(Color.v2DateText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading your assignments")
    }

    /// Full-screen failure state, shown only when a sync failed AND there's
    /// nothing cached to fall back on. When we do have items, the slimmer
    /// `syncErrorBanner` surfaces the error without hiding the list.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.v2SpineRed)
            Text("Couldn't sync")
                .font(.lhfSerif(30))
                .foregroundStyle(Color.v2Ink)
            Text(message)
                .font(.lhfSans(14))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Button { Task { await refresh() } } label: {
                Text("Try again")
                    .font(.lhfSans(15, weight: .semibold))
                    .foregroundStyle(Color.v2ToggleActiveTx)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.v2Ink))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    /// A slim, dismissible notice shown above the list when a refresh failed but
    /// we still have (possibly stale) data to show. Makes sync failures visible
    /// on the dashboard itself — previously they only surfaced in Settings.
    @ViewBuilder
    private var syncErrorBanner: some View {
        if !vm.items.isEmpty, let error = state.error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.v2SpineRed)
                    .padding(.top, 1)
                Text(error)
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.v2Ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Retry") { Task { await refresh() } }
                    .font(.lhfSans(13, weight: .semibold))
                    .foregroundStyle(Color.v2SpineRed)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.v2SpineRed.opacity(0.10))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sync failed. \(error). Double-tap to retry.")
            .accessibilityAddTraits(.isButton)
        }
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
