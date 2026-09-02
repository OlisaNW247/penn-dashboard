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

    /// Whether the "you're not fully connected" banner has been dismissed
    /// THIS launch. Deliberately plain `@State`, not persisted to
    /// `UserDefaults` anywhere: the whole point of the banner is that a
    /// student can otherwise use the app for weeks without noticing half
    /// their work is missing, so it should come back and remind them again
    /// next time they open the app rather than being silenced forever by one
    /// tap. A relaunch resetting it to `false` is that behavior, for free —
    /// persisting it would require a second flag to deliberately re-arm it
    /// later, for no benefit over just not persisting it in the first place.
    @State private var connectionNoticeDismissed = false

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

                    if showsConnectionNotice {
                        connectionNoticeBanner
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
            .background(Color.v2Bg.ignoresSafeArea())
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
                    AssistantView(courseCodes: state.allCourseCodes())
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

    /// The floating action is the persimmon, and it opens `ask`.
    ///
    /// This corner used to hold a "+" that created a manual assignment. The
    /// swap is a real trade and worth being honest about: creating work is a
    /// thing every student does, and it has been demoted to the filter row
    /// (see `addInlineButton`). What it buys is that the app's single most
    /// prominent control is now its most distinctive feature rather than its
    /// most ordinary one — every to-do app on the phone has a "+" bottom
    /// right, and none of them has this.
    ///
    /// The mark is deliberately not sitting on an ink-filled circle like the
    /// old "+" did. A persimmon reversed out on near-black loses the one
    /// thing that makes it recognisable, which is that it is orange. It gets
    /// a raised paper disc instead, so it reads as fruit against the greige.
    private var assistantButton: some View {
        NavigationLink(value: DashRoute.assistant) {
            ZStack {
                Circle()
                    .fill(Color.v2Card)
                    .shadow(color: Color.v2CardShadow.opacity(0.26), radius: 8, y: 3)
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

    /// The new home for "add assignment": trailing the filter row.
    ///
    /// Of the places it could have gone this is the only one that keeps every
    /// property the floating button had. It is always on screen and never
    /// scrolls away; it is one tap, from anywhere in the list; and it now sits
    /// directly above the list it adds to, which the bottom-right corner never
    /// did. The alternatives both lost something — a fourth icon in the header
    /// crowds the greeting off narrow phones and puts "create" in with
    /// navigation, and a ghost row at the end of the list is only reachable
    /// after scrolling past everything, which is precisely backwards for the
    /// student who has just realised something is missing.
    ///
    /// The cost is reach: this is no longer in the thumb zone. That is the
    /// price of giving the corner to `ask`, and it lands on the rarer action.
    private var addInlineButton: some View {
        Button { showAddSheet = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.v2DateText)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.v2Ink.opacity(0.07)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("add assignment")
        .help("add assignment")
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
            state.restartOnboarding()
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

    // MARK: Connection notice banner

    /// Whether either data-source gap this feature warns about is currently
    /// open AND the student hasn't already dismissed the notice this launch.
    /// Deliberately one flag covering two independent conditions
    /// (`needsGradescopeConnection`, `canvasIsLinkOnly`) rather than two
    /// separate banners: a student who is missing both Canvas's cookie
    /// session and Gradescope entirely should see one clear "you're not
    /// fully connected" card, not a stack of two nags competing for the same
    /// slot above the segmented toggle.
    private var showsConnectionNotice: Bool {
        !connectionNoticeDismissed && (state.needsGradescopeConnection || state.canvasIsLinkOnly)
    }

    /// Lowercase, matching `canvasSessionExpiredBanner`'s voice, and chosen
    /// per which gap(s) are actually open so a student missing only one
    /// source isn't told to "connect both."
    private var connectionNoticeTitle: String {
        if state.needsGradescopeConnection && state.canvasIsLinkOnly {
            return "canvas and gradescope aren't fully connected"
        } else if state.canvasIsLinkOnly {
            return "canvas is connected by link only"
        } else {
            return "gradescope isn't connected"
        }
    }

    private var connectionNoticeSubtitle: String {
        if state.needsGradescopeConnection && state.canvasIsLinkOnly {
            return "you're seeing calendar items only. connect both to see everything you owe."
        } else if state.canvasIsLinkOnly {
            return "log in to canvas for grades and automatic submission tracking."
        } else {
            return "connect it to see gradescope work alongside canvas."
        }
    }

    /// Warns a student who is quietly missing a whole data source — a
    /// Gradescope connection that was never made, or a Canvas connection
    /// that's only a pasted calendar link with no cookie session behind it
    /// (see `AppState.needsGradescopeConnection` and `.canvasIsLinkOnly`) —
    /// so they don't spend weeks treating a partial dashboard as complete.
    ///
    /// The main tap target and the dismiss control are SIBLING `Button`s
    /// inside one `HStack`, not one nested inside the other's label. A
    /// control placed inside another control's label is not reliably
    /// tappable in SwiftUI — `.buttonStyle(.plain)` on the outer button
    /// narrows the outer hit target to its label's bounds, but that does not
    /// guarantee the inner button gets first refusal on a tap that lands on
    /// it, and the failure mode (a dismiss button that silently swallows or
    /// loses the tap) is worse than not having one, since the student was
    /// told they could dismiss the banner and then can't. What still makes
    /// this read as one card is the shared background/padding/corner radius
    /// applied to the outer `HStack` that contains both buttons, not a
    /// single button wrapping everything — matching `canvasSessionExpiredBanner`'s
    /// fonts, colors, corner radius (11) and padding (12).
    ///
    /// The dismiss button carries an explicit 44×44pt frame before its
    /// `.contentShape`, per Apple's minimum tappable-target guidance; the
    /// 11pt `xmark` glyph alone would offer a target a few points on a side.
    /// That frame makes this card a few points taller than
    /// `canvasSessionExpiredBanner`, which has no such control — an accepted,
    /// deliberate cost, since correct tap routing on a control whose entire
    /// job is "let the student make this go away" matters more than an exact
    /// height match between the two banners.
    private var connectionNoticeBanner: some View {
        HStack(spacing: 10) {
            Button {
                state.restartOnboarding()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionNoticeTitle)
                            .font(.lhfSans(12, weight: .semibold))
                        Text(connectionNoticeSubtitle)
                            .font(.lhfSans(11))
                            .foregroundStyle(Color.v2DateText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.v2DateText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(connectionNoticeTitle). \(connectionNoticeSubtitle)")

            Button {
                connectionNoticeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.v2DateText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("dismiss")
        }
        .foregroundStyle(Color.v2Ink)
        .padding(12)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: Header

    /// Wordmark, greeting and date on the left; the destinations on the right,
    /// where the weekly ring used to sit. There's no manual reload button:
    /// opening the app auto-refreshes, so these are the only header controls.
    ///
    /// v4 briefly made profile and settings tabs. They are pushed routes again,
    /// off one stack, which is what the gear had always been. The tab bar cost
    /// a permanent strip of screen on a list that wants the height, and put two
    /// screens a student visits at the start of a semester next to the one they
    /// open every day.
    ///
    /// One stack also means one Settings. When the gear pushed while a Settings
    /// tab existed, the app could hold two live independent copies, each with
    /// its own scroll position and half-typed rename, which is the "back button
    /// went to the wrong screen" bug pre-built.
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
                    navButton(to: .grades, icon: "chart.line.uptrend.xyaxis", title: "grades")
                }
                navButton(to: .profile, icon: "person.crop.circle.fill", title: "profile")
                navButton(to: .settings, icon: "gearshape.fill", title: "settings")
            }
            .padding(.top, 2)
        }
    }

    /// Matching circular icons in the top right. Every one is a push onto the
    /// dashboard's own stack, so profile and settings are full screens with a
    /// back button. Labels live in the accessibility layer only.
    private func navButton(to route: DashRoute, icon: String, title: String) -> some View {
        NavigationLink(value: route) {
            headerIcon(icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }


    private func headerIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.v2DateText)
            .frame(width: 48, height: 48)
            .background(Circle().fill(Color.v2Ink.opacity(0.07)))
            .contentShape(Circle())
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
                Text("go enjoy life")
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
            Text("loading your assignments…")
                .font(.lhfSans(15))
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
                .font(.lhfSans(14))
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
