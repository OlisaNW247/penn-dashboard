import SwiftUI
import LowHangingFruitKit
import WebKit

/// Grade Watcher's root view. Pushed onto the dashboard's `NavigationStack` —
/// either straight from the header's **Grades** button or from Settings →
/// Grades — so it's a full screen, not a card over the dashboard. It owns no
/// `NavigationStack` itself; whichever parent pushed it supplies one.
///
/// One card per class-picker-selected course (docs/grades.md Decision 4).
/// Grades need a live Canvas session cookie (§1) — unlike the dashboard's
/// cookieless ICS feed — so this view drives its own refresh rather than
/// riding the dashboard's sync loop.
struct GradeWatcherView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var store: GradeWatcherStore

    init(store: GradeWatcherStore) {
        self.store = store
    }

    private var courses: [(id: String, name: String)] {
        state.selectedCanvasCourseIDs()
            .map { (id: $0.key, name: state.courseDisplayName($0.value)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Classes the picker has switched on, regardless of whether we managed to
    /// resolve a Canvas id for them. The gap between this and `courses` is what
    /// separates "you haven't picked anything" from "we can't reach Canvas for
    /// what you picked" — see `unmatchedCoursesState`.
    private var selectedCodes: [String] { state.selectedCourseCodes() }

    private var isFirstLoad: Bool {
        store.lastRefreshed == nil && store.snapshots.isEmpty && store.isRefreshing
    }

    /// `courses` is derived from `state.canvasItems`, the same dashboard feed
    /// `ContentView` syncs on launch/activation. If this view is reached
    /// before that sync has ever completed, `canvasItems` — and therefore
    /// `courses` — is legitimately empty even though the user has classes
    /// selected (the class picker's toggles default to ON). Previously that
    /// state rendered the same "no classes selected" empty state as an
    /// actually-empty, all-off class picker, which is misleading. Distinguish
    /// "haven't synced yet" (show a loading state) from "synced, and nothing
    /// is selected/enrolled" (show the real empty state).
    private var isAwaitingCourseData: Bool {
        courses.isEmpty && state.lastSync == nil && (state.isLoading || state.isCanvasConnected)
    }

    var body: some View {
        Group {
            if isAwaitingCourseData {
                loadingState
            } else if courses.isEmpty {
                if selectedCodes.isEmpty { emptyCoursesState } else { unmatchedCoursesState }
            } else if isFirstLoad {
                loadingState
            } else {
                courseList
            }
        }
        .navigationTitle("Grade Watcher")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task { await performRefresh() }
    }

    // MARK: - States

    private var emptyCoursesState: some View {
        VStack(spacing: 4) {
            Text("No classes selected yet.")
                .font(.lhfSerif(17))
                .foregroundStyle(Color.v2DateText)
            Text("Turn on a class in Settings \u{2192} Classes to see its grades here.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2RingSub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
        .background(Color.v2Bg)
    }

    /// Shown when classes ARE selected but none resolved to a Canvas course id.
    /// Telling the user "no classes selected" here is simply false, and it sends
    /// them to a settings screen where everything already looks correct.
    private var unmatchedCoursesState: some View {
        VStack(spacing: 6) {
            Text("Can\u{2019}t reach Canvas for your classes.")
                .font(.lhfSerif(17))
                .foregroundStyle(Color.v2DateText)
                .multilineTextAlignment(.center)
            Text("\(selectedCodes.count) class\(selectedCodes.count == 1 ? " is" : "es are") switched on, but Canvas hasn\u{2019}t told us their course pages yet. Grades need a live Canvas login \u{2014} reconnect Canvas in Settings, then open Grades again.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2RingSub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
            recoveryActions
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
        .background(Color.v2Bg)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading grades\u{2026}")
                .font(.lhfSans(12))
                .foregroundStyle(Color.v2RingSub)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.v2Bg)
    }

    private var courseList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.isSessionExpired {
                    staleBanner
                } else if let message = store.error {
                    errorBanner(message)
                }

                termSummary
                lastRefreshedLine

                VStack(spacing: 12) {
                    ForEach(courses, id: \.id) { course in
                        GradeCourseCardView(
                            store: store,
                            courseID: course.id,
                            courseName: course.name
                        )
                    }
                }
                .opacity(store.isSessionExpired ? 0.7 : 1)
                .saturation(store.isSessionExpired ? 0.7 : 1)
            }
            .padding(16)
        }
        .background(Color.v2Bg)
        .refreshable { await performRefresh() }
    }

    /// The dashboard opens with a serif greeting; this gives Grades the same
    /// opening moment (docs/grades.md §11): a big serif **estimated GPA** —
    /// each class's percent stepped through `GradeScale` (standard cutoffs;
    /// professors' real cutoffs are unknowable, hence "estimated"), averaged
    /// unweighted (credit hours aren't in the data). Hidden until ≥ 2 classes
    /// have a grade, since an "average" of one course is just that course.
    @ViewBuilder
    private var termSummary: some View {
        let percents = courses.compactMap { store.breakdown(courseID: $0.id)?.currentPercent }
        if percents.count >= 2 {
            let gpa = percents.map(GradeScale.gpa(forPercent:)).reduce(0, +) / Double(percents.count)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.2f", gpa))
                    .font(.lhfSerif(34))
                    .foregroundStyle(Color.v2Ink)
                Text("estimated GPA across your \(percents.count) classes \u{00b7} standard cutoffs")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: "Estimated GPA %.2f across %d classes, using standard cutoffs", gpa, percents.count))
        }
    }

    /// `GradeWatcherStore.refresh` reports every non-expiry failure through
    /// `error` — including "no Canvas session was found", the state you land in
    /// when the app has no stored Canvas cookies. Nothing rendered it, so those
    /// runs looked identical to a successful one that simply found no grades:
    /// cards with empty bodies and no clue why. Surface it.
    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.v2DueAmber)
                Text(message)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2Ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            recoveryActions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2DueAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    /// The only real fix for a missing or dead Canvas session is logging in
    /// again — Penn SSO has to happen in the WebView, so nothing can refresh it
    /// silently. This routes back through the same connect flow Settings uses,
    /// with a plain retry beside it for the case where the session is actually
    /// fine and the fetch just failed (offline, Canvas hiccup).
    private var recoveryActions: some View {
        HStack(spacing: 16) {
            // Hidden in preview mode: `restartOnboarding()` clears
            // `isPreviewMode` and drops the tapper into Penn SSO. For an App
            // Store reviewer exploring the demo that's a one-way exit into a
            // login they cannot pass — the opposite of what this button is for.
            if !state.isPreviewMode {
                Button {
                    state.restartOnboarding()
                } label: {
                    Text("Reconnect Canvas")
                        .font(.lhfSans(12, weight: .semibold))
                        .foregroundStyle(Color.v2ToggleActiveTx)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.v2Ink))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await performRefresh() }
            } label: {
                Text(store.isRefreshing ? "Refreshing\u{2026}" : "Try again")
                    .font(.lhfSans(12, weight: .semibold))
                    .foregroundStyle(Color.v2DateText)
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
        }
    }

    private var staleBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(Color.v2DueAmber)
                Text("Showing last known grades \u{2014} your Canvas session expired.")
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2Ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            recoveryActions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2DueAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var lastRefreshedLine: some View {
        HStack(spacing: 6) {
            Text("Last refreshed \(relativeTimeString(store.lastRefreshed))")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
            }
            Spacer()
        }
    }

    // MARK: - Refresh

    /// Grades are cookie-authed (docs/grades.md §1, §7). Canvas cookies are now
    /// persisted the same way Gradescope's are (`SessionCookieStore`, captured
    /// at connect time in `CanvasLoginPane.connect()`), gathered via the shared
    /// `AutoSyncCoordinator.canvasCookies()` (persisted set folded with whatever
    /// the in-app WebView session currently holds, live values winning on
    /// overlap) so this view and the launch-time refresh agree on one
    /// implementation. If the session still comes back expired, the persisted
    /// cookies are stale — purge them so the next attempt doesn't keep retrying
    /// dead cookies, and let the existing stale banner
    /// (`GradeWatcherStore.isSessionExpired`) do the surfacing.
    private func performRefresh() async {
        let cookies = await AutoSyncCoordinator.canvasCookies()
        await state.refreshGradeWatcher(cookies: cookies)

        if store.isSessionExpired {
            let hadPersisted = !SessionCookieStore.load(service: .canvas).isEmpty
            if hadPersisted {
                SessionCookieStore.remove(service: .canvas)
            }
        }
    }
}

/// "3 minutes ago" / "Never" style relative time, matching the fairly compact
/// tone of `dueText`/`formatDue` elsewhere in the app. No existing relative-time
/// helper in the codebase, so this introduces one rather than hand-rolling
/// bucketed math a second time.
func relativeTimeString(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "never" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: now)
}
