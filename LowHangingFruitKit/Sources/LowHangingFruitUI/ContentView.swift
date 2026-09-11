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
    ///
    /// `.settings` survives v4's tab bar even though the gear no longer pushes
    /// it. It is what the `-LHFShowSettings` screenshot seam drives, and
    /// keeping it means the App Store capture script keeps producing the same
    /// frame it always did — now with the tab bar underneath it.
    enum DashRoute: Hashable {
        case settings
        case profile
        case grades
        case report(courseID: String, courseName: String)
        case assistant
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

                    HStack(spacing: 10) {
                        SegmentedToggle(selection: $filter)
                        addInlineButton
                    }
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

                assistantButton
            }
            .background(Color.smoothPaper.ignoresSafeArea())
            .navigationDestination(for: DashRoute.self) { route in
                switch route {
                case .settings:
                    SettingsPage()
                        .environmentObject(state)
                        .environmentObject(scheduler)
                case .profile:
                    ProfileView()
                        .environmentObject(state)
                        .environmentObject(scheduler)
                case .assistant:
                    // Built at push time, not held on AppState: the document
                    // is a snapshot of what the student has right now, and
                    // rebuilding it per visit is cheap next to keeping a
                    // second copy of the ledger permanently in memory.
                    AssistantView(
                        courseCodes: state.allCourseCodes(),
                        contextDocument: state.assistantContextDocument(),
                        knowledge: state.assistantKnowledge,
                        work: state.assistantWorkItems(),
                        userName: state.userName
                    )
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
                if args.contains("-LHFShowProfile") { path = [.profile] }
                if args.contains("-LHFShowGrades") { path = [.grades] }
                if args.contains("-LHFShowAssistant") { path = [.assistant] }
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
        // The one-ask "include this class's readings?" popup that used to
        // live here (`CourseNudgeSheet`, driven off `pendingCourseNudge`)
        // was removed 2026-08-27 (docs/decisions.md): readings now import
        // automatically for every class unless the student has explicitly
        // excluded it via Settings' "Courses & content" toggle, so there is
        // nothing left to ask about at this point in the flow.
        // Settings is a push now, so there's no sheet-dismiss hook to hang this
        // on: returning to the dashboard is the moment class toggles, deletions
        // and renames need to be reflected in the list and in reminders.
        .onChange(of: path) { _, newPath in
            guard newPath.isEmpty else { return }
            vm.reload(preservingEdits: true)
            rescheduleNotifications()
        }
    }

    private var assistantButton: some View {
        NavigationLink(value: DashRoute.assistant) {
            ZStack {
                Circle()
                    .fill(Color.smoothPaper)
                    .overlay { Circle().stroke(Color.smoothInk, lineWidth: 2) }
                PersimmonMark(size: 34)
                    .frame(width: 34, height: 34)
            }
            .frame(width: 60, height: 60)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ask about your classes")
        .padding(.trailing, 22)
        .padding(.bottom, 24)
    }

    /// Opens the existing add sheet, whose weekly-repeat toggle creates a
    /// recurring task without changing the dashboard's data flow.
    private var addInlineButton: some View {
        Button { showAddSheet = true } label: {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.smoothLemon))
                .overlay { Circle().stroke(Color.smoothInk, lineWidth: 2) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("add assignment or recurring task")
        .help("add assignment or recurring task")
    }

    /// Reschedule due-date reminders from the current (override-aware) items.
    private func rescheduleNotifications() {
        guard scheduler.isEnabled else { return }
        Task { await scheduler.reschedule(from: vm.items) }
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
            state.restartOnboarding(for: .canvas)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("your canvas login needs a refresh")
                        .font(.lhfSans(12, weight: .semibold))
                    Text("reconnect to keep automatic submission tracking accurate.")
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
        .accessibilityLabel("your canvas login needs a refresh. reconnect canvas.")
    }

    // MARK: Header

    /// The original v5 hierarchy, with Smooth's visual identity layered on top.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("Smooth")
                        .font(.lhfWordmark(27))
                    Text(" \(Self.weekdayText(Date()))")
                        .font(.lhfSerif(27))
                }
                    .foregroundStyle(Color.smoothInk)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)

                Text(Self.dateText(Date()))
                    .font(.lhfSecondary(15, weight: .medium))
                    .foregroundStyle(Color.smoothMuted)
                    .padding(.top, 2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                if FeatureFlags.gradeWatcher && state.canUseGradeWatcher {
                    navButton(to: .grades, icon: "chart.line.uptrend.xyaxis", title: "grades")
                }
                navButton(to: .profile, icon: "person.crop.circle.fill", title: "profile")
                navButton(to: .settings, icon: "gearshape.fill", title: "settings")
            }
            .padding(.top, 2)
        }
    }

    private func navButton(to route: DashRoute, icon: String, title: String) -> some View {
        NavigationLink(value: route) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.smoothSurface))
                .overlay { Circle().stroke(Color.smoothInk, lineWidth: 2) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
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
        await announceTurnedIn()
    }

    /// Drains "Turned in ✓" confirmations the same way grade changes drain —
    /// after `reschedule`, via the view-owned scheduler, so `AppState` stays
    /// free of notification plumbing (see `pendingTurnedInNotices`).
    private func announceTurnedIn() async {
        let notices = state.pendingTurnedInNotices
        guard !notices.isEmpty else { return }
        state.pendingTurnedInNotices = []
        await scheduler.postTurnedInNotifications(notices)
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
        case .thisWeek: timeline(sections: vm.todoSections(), showsTodoEmptyState: true)
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
    private func timeline(sections: [DashSection], showsTodoEmptyState: Bool = false) -> some View {
        if sections.isEmpty {
            switch emptyStateStatus {
            case .loading:            loadingState
            case let .error(message): errorState(message)
            case .caughtUp:
                // A first-time install can have `awaitingCanvasCheck`
                // non-empty (see `AppState`'s doc comment on that property)
                // while every other bucket is genuinely empty — nothing
                // caught up yet, everything held pending a Canvas check.
                // `allDoneState`'s "you're all caught up" would be exactly
                // the false celebration this whole feature exists to
                // prevent, so this case takes priority over it here.
                if state.awaitingCanvasCheck.isEmpty {
                    if showsTodoEmptyState {
                        todoEmptyState
                    } else {
                        allDoneState
                    }
                } else {
                    awaitingCanvasCheckNotice
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                // Some items can be visible while others from a different,
                // not-yet-checked course are still held — the one-line notice
                // sits above the real sections rather than replacing them.
                if !state.awaitingCanvasCheck.isEmpty {
                    awaitingCanvasCheckNotice
                }
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

    /// The first-launch submission hold's on-screen half — see
    /// `AppState.awaitingCanvasCheck`'s doc comment for the underlying rule.
    /// Doubles as a small one-line notice above populated sections and as the
    /// whole empty-state content when nothing else has cleared the hold yet,
    /// which is why it carries `loadingState`'s `ProgressView` rather than
    /// inventing its own look for either spot.
    private var awaitingCanvasCheckNotice: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("checking canvas for what you've turned in…")
                .font(.lhfSans(13))
                .foregroundStyle(Color.v2DateText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
                Text("go enjoy life")
                    .font(.lhfSerif(46))
                    .foregroundStyle(Color.v2Ink)
                Text("you're all caught up")
                    .font(.lhfSecondary(15))
                    .foregroundStyle(Color.v2DateText.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var todoEmptyState: some View {
        SmoothTodoEmptyState()
    }

    /// Shown in place of the "all caught up" art while the first sync is still in
    /// flight, so an empty screen doesn't read as "you're done".
    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("loading your assignments…")
                .font(.lhfSecondary(15))
                .foregroundStyle(Color.v2DateText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("loading your assignments")
    }

    /// Full-screen failure state, shown only when a sync failed AND there's
    /// nothing cached to fall back on. When we do have items, the slimmer
    /// `syncErrorBanner` surfaces the error without hiding the list.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.v2SpineRed)
            Text("couldn't sync")
                .font(.lhfSerif(30))
                .foregroundStyle(Color.v2Ink)
            Text(message)
                .font(.lhfSecondary(14))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Button { Task { await refresh() } } label: {
                Text("try again")
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
                Button("retry") { Task { await refresh() } }
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
            .accessibilityLabel("sync failed. \(error). double-tap to retry.")
            .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: Date

    private static func weekdayText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    private static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE MMM d"
        return f.string(from: date)
    }
}

private struct SmoothTodoEmptyState: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.smoothLemon.opacity(0.16))
                .frame(width: 250, height: 250)
                .scaleEffect(appeared ? 1 : 0.72)
                .opacity(appeared ? 1 : 0)

            if let img = bundledImage("chill", ext: "jpg") {
                img
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .blendMode(.multiply)
                    .opacity(appeared ? 0.35 : 0)
                    .scaleEffect(appeared ? 1 : 0.9)
                    .offset(y: appeared ? -4 : 12)
                    .accessibilityHidden(true)
            }

            Text("go enjoy life")
                .font(.lhfSerif(46))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("go enjoy life")
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) {
                    appeared = true
                }
            }
        }
        .onDisappear { appeared = false }
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
