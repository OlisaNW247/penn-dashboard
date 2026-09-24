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
    @Environment(\.colorScheme) private var colorScheme

    @State private var filter: DashFilter = .thisWeek
    @State private var editing: DashItem?
    @State private var showAddSheet = false
    @State private var showAnnouncementFinds = false
    /// The pushed pages behind the header actions. A path rather than separate
    /// booleans keeps the screenshot seams deterministic.
    @State private var path: [DashRoute] = []

    /// Where the header's buttons lead. They push onto the dashboard's own
    /// stack, so Profile and Grades are full screens with a back button rather
    /// than cards presented over the list.
    /// `report` carries its own course identity so the stack can be restored
    /// (or, in DEBUG, seeded straight to the report for screenshots) without
    /// walking through the cards.
    ///
    enum DashRoute: Hashable {
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

    /// Lockstep sizes for the whole dashboard title. `ViewThatFits` chooses
    /// one candidate for the complete wordmark-plus-weekday group, so the two
    /// faces can never scale independently when header space gets tight.
    static let dashboardTitlePointSizes: [CGFloat] = [27, 24, 21, 18]

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
                        .padding(.top, 18)

                    syncErrorBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    if state.canvasSessionExpired {
                        canvasSessionExpiredBanner
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                    }

                    HStack(alignment: .center, spacing: 8) {
                        SegmentedToggle(selection: $filter)
                        addInlineButton
                        if !state.announcementPageItems.isEmpty {
                            announcementFindsButton
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    ScrollView {
                        listContent
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
                            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.items)
                    }
                }

                assistantButton
            }
            .background(Color.smoothPaper.ignoresSafeArea())
            .navigationDestination(for: DashRoute.self) { route in
                switch route {
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
                        userName: state.userName,
                        allowBackend: state.canvasInstallation.id == CanvasInstallation.penn.id
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
                if args.contains("-LHFShowSettings") { path = [.profile] }
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
        .sheet(isPresented: $showAnnouncementFinds) {
            AnnouncementFindsView(items: state.announcementPageItems)
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
                SmoothStarMark(size: 58)
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
                .foregroundStyle(Color.smoothTomatoInk)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.smoothTomato.opacity(0.22)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("add assignment or recurring task")
        .help("add assignment or recurring task")
    }

    private var announcementFindsButton: some View {
        Button { showAnnouncementFinds = true } label: {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.smoothAnnouncementAccent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.smoothAnnouncementFill))
                .contentShape(Circle())
                .overlay(alignment: .topTrailing) {
                    Text("\(state.announcementPageItems.count)")
                        .font(.lhfMono(8, weight: .semibold))
                        .foregroundStyle(Color.smoothPaper)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Circle().fill(Color.smoothAnnouncementAccent))
                        .offset(x: 3, y: -3)
                        .accessibilityHidden(true)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(state.announcementPageItems.count) announcements")
        .help("announcements")
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
    ///
    /// Branches on `state.autoLoginDisabledReason` — "stay signed in"
    /// (CLAUDE.md's "stay signed in" entry) tried to fix this on its own and
    /// couldn't, because the stored PennKey password was rejected. Sending
    /// that student BACK into the same login pane whose auto-fill would
    /// immediately retry the identical wrong password is pointless (worse:
    /// it's exactly the repeated-wrong-password shape this feature exists to
    /// avoid); Profile is where they actually fix it
    /// (`PennKeyCredentialsSheet` via the "update password" button).
    ///
    /// Also branches on `state.autoLoginAwaitingDuo` (checked second, so a
    /// rejection — the more actionable fact — always wins if both were
    /// somehow set): the stored password was ACCEPTED and only Duo stands
    /// between here and a live session, but the silent background path
    /// stood down rather than push Duo again unattended (see
    /// `AppState.canAutoLoginSilently`'s doc comment). Unlike the rejected
    /// case, sending this student back into the login pane is exactly right
    /// — the visible pane reads the looser `canAutoLogin`, so it fills the
    /// form and lets Duo push right there, which is the one thing a silent
    /// background attempt can never do for them.
    private var canvasSessionExpiredBanner: some View {
        let rejected = state.autoLoginDisabledReason != nil
        let awaitingDuo = !rejected && state.autoLoginAwaitingDuo
        return Button {
            if rejected {
                path.append(.profile)
            } else {
                state.restartOnboarding(for: .canvas)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(canvasSessionExpiredBannerTitle(rejected: rejected, awaitingDuo: awaitingDuo))
                        .font(.lhfSans(12, weight: .semibold))
                    Text(canvasSessionExpiredBannerSubtitle(rejected: rejected, awaitingDuo: awaitingDuo))
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
        .accessibilityLabel(
            "\(canvasSessionExpiredBannerTitle(rejected: rejected, awaitingDuo: awaitingDuo)). "
                + (rejected ? "update it in profile." : "reconnect canvas.")
        )
    }

    private func canvasSessionExpiredBannerTitle(rejected: Bool, awaitingDuo: Bool) -> String {
        if rejected { return "your stored pennkey password didn't work" }
        if awaitingDuo { return "tap to finish signing in — duo needs you" }
        return "your canvas login needs a refresh"
    }

    private func canvasSessionExpiredBannerSubtitle(rejected: Bool, awaitingDuo: Bool) -> String {
        if rejected { return "update it in profile." }
        if awaitingDuo { return "your pennkey password went through; duo needs a tap to finish." }
        return "reconnect to keep automatic submission tracking accurate."
    }

    // MARK: Header

    /// The original v5 hierarchy, with Smooth's visual identity layered on top.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    headerTitle(weekday: Self.weekdayText(Date()), pointSize: Self.dashboardTitlePointSizes[0])
                    headerTitle(weekday: Self.weekdayText(Date()), pointSize: Self.dashboardTitlePointSizes[1])
                    headerTitle(weekday: Self.weekdayText(Date()), pointSize: Self.dashboardTitlePointSizes[2])
                    headerTitle(weekday: Self.weekdayText(Date()), pointSize: Self.dashboardTitlePointSizes[3])
                }
                .layoutPriority(1)
                .frame(height: 48, alignment: .center)

                Text(Self.dateText(Date()))
                    .font(.lhfMono(14, weight: .medium))
                    .foregroundStyle(Color.smoothMuted)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                if FeatureFlags.gradeWatcher && state.canUseGradeWatcher {
                    navButton(to: .grades, icon: "chart.line.uptrend.xyaxis", title: "grades", color: .smoothGrape)
                }
                navButton(to: .profile, icon: "person.crop.circle.fill", title: "profile", color: .smoothTeal)
            }
        }
    }

    /// One indivisible title candidate. The faces keep their established
    /// italic/upright character, while both receive the exact same selected
    /// point size and the underline remains scoped to the wordmark alone.
    private func headerTitle(weekday: String, pointSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Smooth")
                .font(.lhfWordmark(pointSize))
                .overlay(alignment: .bottomLeading) {
                    SmoothSquiggle()
                        .stroke(
                            LinearGradient(
                                colors: [.smoothTomato, .smoothMarigold, .smoothGrape],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                        )
                        .frame(height: 6)
                        .offset(y: 6)
                }

            Text(" \(weekday)")
                .font(.lhfHeaderTitle(pointSize))
        }
        .foregroundStyle(Color.smoothInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private func navButton(to route: DashRoute, icon: String, title: String, color: Color) -> some View {
        NavigationLink(value: route) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
                .frame(width: 48, height: 48)
                .background(Circle().fill(color.opacity(0.18)))
                .overlay { Circle().stroke(color.opacity(0.48), lineWidth: 1.25) }
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
        // Cheap (one cookie-jar read, no network) — refreshed on the same
        // launch/activation/5-minute cadence as everything else here so
        // Settings' "stay signed in" footer and the diagnostics report never
        // show a stale read of how long Duo will keep skipping its prompt.
        await state.refreshDuoRememberSummary()
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
            chillArtwork(maxWidth: 320, opacity: 0.35)
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

    /// The source illustration is black ink on white paper. Multiply makes
    /// that paper disappear in light mode; in dark mode, invert + screen does
    /// the equivalent job and turns the drawing into quiet moonlit linework.
    @ViewBuilder
    private func chillArtwork(maxWidth: CGFloat, opacity: Double) -> some View {
        if let img = bundledImage("chill", ext: "jpg") {
            if colorScheme == .dark {
                img
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth)
                    .colorInvert()
                    .blendMode(.screen)
                    .opacity(opacity * 0.72)
                    .accessibilityHidden(true)
            } else {
                img
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth)
                    .blendMode(.multiply)
                    .opacity(opacity)
                    .accessibilityHidden(true)
            }
        }
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
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

private struct AnnouncementFindsView: View {
    let items: [Assignment]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.courseNameOverrides) private var courseNameOverrides

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if items.isEmpty {
                        Text("no announcements")
                            .font(.lhfSecondary(14))
                            .foregroundStyle(Color.smoothMuted)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 36)
                    } else {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.smoothPaper.ignoresSafeArea())
            .tint(Color.smoothAnnouncementAccent)
            .navigationTitle("announcements")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: Assignment) -> some View {
        let content = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayCourse(overrides: courseNameOverrides).uppercased())
                    .font(.lhfMono(9.5, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Color.smoothAnnouncementAccent)
                Text(item.title)
                    .font(.lhfAssignmentTitle(17))
                    .foregroundStyle(Color.smoothInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let dueAt = item.dueAt {
                    Text(dueAt.formatted(date: .abbreviated, time: .shortened).lowercased())
                        .font(.lhfMono(10))
                        .foregroundStyle(Color.smoothMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.url != nil {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.smoothMuted)
            }
        }
        .padding(14)
        .background(Color.v2DoneCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

        if let url = item.url {
            Link(destination: url) { content }
                .buttonStyle(.plain)
                .accessibilityHint("opens the original announcement")
        } else {
            content
        }
    }
}

/// A compact three-wave underline with a hand-drawn rhythm. It is drawn into
/// whatever width the overlay hands it — the rendered width of the Roobert
/// "Smooth" wordmark, scaled or not — so it always ends where the word ends
/// and never reaches the weekday.
private struct SmoothSquiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let amplitude = rect.height * 0.32
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))

        for step in 1...48 {
            let progress = CGFloat(step) / 48
            let x = rect.minX + rect.width * progress
            let y = rect.midY + sin(progress * .pi * 6) * amplitude
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }
}

private struct SmoothTodoEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.smoothLemon.opacity(0.16))
                    .frame(width: 218, height: 218)
                    .scaleEffect(appeared ? 1 : 0.78)
                    .opacity(appeared ? 1 : 0)

                if !reduceMotion {
                    ForEach(Array(Self.confetti.enumerated()), id: \.offset) { index, piece in
                        EmptyStateConfettiPiece(piece: piece)
                            .offset(appeared ? piece.destination : .zero)
                            .rotationEffect(.degrees(appeared ? piece.rotation : 0))
                            .scaleEffect(appeared ? 1 : 0.18)
                            .opacity(appeared ? piece.opacity : 0)
                            .animation(
                                .spring(response: 0.62, dampingFraction: 0.68)
                                    .delay(0.06 + (Double(index) * 0.028)),
                                value: appeared
                            )
                    }
                }

                if let img = bundledImage("chill", ext: "jpg") {
                    Group {
                        if colorScheme == .dark {
                            img
                                .resizable()
                                .scaledToFit()
                                .colorInvert()
                                .blendMode(.screen)
                                .opacity(appeared ? 0.25 : 0)
                        } else {
                            img
                                .resizable()
                                .scaledToFit()
                                .blendMode(.multiply)
                                .opacity(appeared ? 0.35 : 0)
                        }
                    }
                    .frame(maxWidth: 242)
                    .scaleEffect(appeared ? 1 : 0.86)
                    .offset(y: appeared ? -4 : 14)
                    .animation(.spring(response: 0.68, dampingFraction: 0.76), value: appeared)
                    .accessibilityHidden(true)
                }
            }

            Text("go enjoy life")
                .font(.lhfSerif(46))
                .foregroundStyle(Color.v2Ink)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(.easeOut(duration: 0.34).delay(0.12), value: appeared)

            Text("nothing due this week")
                .font(.lhfMono(10, weight: .semibold))
                .tracking(0.9)
                .foregroundStyle(Color.v2DateText)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(.easeOut(duration: 0.32).delay(0.18), value: appeared)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("nothing due this week. go enjoy life")
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                // Defer one run-loop so every piece gets a real origin frame;
                // otherwise SwiftUI may render the destination immediately.
                DispatchQueue.main.async {
                    appeared = true
                }
            }
        }
        .onDisappear { appeared = false }
    }

    private static let confetti: [EmptyStateConfetti] = [
        .init(destination: .init(width: -92, height: -68), rotation: -54, color: .smoothTomato, shape: .ticket, opacity: 0.85),
        .init(destination: .init(width: -50, height: -102), rotation: 34, color: .smoothMarigold, shape: .dash, opacity: 0.9),
        .init(destination: .init(width: 4, height: -112), rotation: -18, color: .smoothCobalt, shape: .dot, opacity: 0.8),
        .init(destination: .init(width: 62, height: -94), rotation: 58, color: .smoothGrape, shape: .ticket, opacity: 0.82),
        .init(destination: .init(width: 102, height: -48), rotation: -38, color: .smoothTeal, shape: .dash, opacity: 0.9),
        .init(destination: .init(width: 108, height: 18), rotation: 48, color: .smoothTomato, shape: .dot, opacity: 0.78),
        .init(destination: .init(width: 82, height: 72), rotation: -62, color: .smoothLemon, shape: .ticket, opacity: 0.88),
        .init(destination: .init(width: -78, height: 74), rotation: 46, color: .smoothCobalt, shape: .dash, opacity: 0.78),
        .init(destination: .init(width: -108, height: 24), rotation: -28, color: .smoothGrape, shape: .dot, opacity: 0.8),
    ]
}

/// Tiny deadline-colored paper pieces, shaped like the cards they celebrate
/// clearing. Their irregular destinations keep the burst playful, not glossy.
private struct EmptyStateConfetti {
    enum Shape { case ticket, dash, dot }
    let destination: CGSize
    let rotation: Double
    let color: Color
    let shape: Shape
    let opacity: Double
}

private struct EmptyStateConfettiPiece: View {
    let piece: EmptyStateConfetti

    var body: some View {
        Group {
            switch piece.shape {
            case .ticket:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .frame(width: 13, height: 8)
            case .dash:
                Capsule().frame(width: 13, height: 4)
            case .dot:
                Circle().frame(width: 7, height: 7)
            }
        }
        .foregroundStyle(piece.color)
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
