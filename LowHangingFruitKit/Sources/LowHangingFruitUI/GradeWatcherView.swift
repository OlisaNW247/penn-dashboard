import SwiftUI
import LowHangingFruitKit
import WebKit

/// Grade Watcher's root view. Reachable **only** from `SettingsSheet` (a
/// `NavigationLink` push into the same `NavigationStack`) — no tab, no
/// dashboard surface (docs/grades.md §6, §8).
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
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var isFirstLoad: Bool {
        store.lastRefreshed == nil && store.snapshots.isEmpty && store.isRefreshing
    }

    var body: some View {
        Group {
            if courses.isEmpty {
                emptyCoursesState
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
                }

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

    private var staleBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Color.v2DueAmber)
            Text("Showing last known grades \u{2014} log in to Canvas to refresh.")
                .font(.lhfSans(12, weight: .medium))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2DueAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
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

    /// Grades are cookie-authed (docs/grades.md §1, §7); Canvas cookies aren't
    /// persisted anywhere in this app today (only Gradescope's are, via
    /// `SessionCookieStore` — see `AutoSyncCoordinator`), so this reads
    /// whatever Canvas cookies the in-app WebView session currently holds,
    /// same as the onboarding connect flow. When that session has lapsed,
    /// `GradeWatcherStore` surfaces `isSessionExpired` and this view goes
    /// stale rather than blank.
    private func performRefresh() async {
        let cookies = await Self.liveCanvasCookies()
        await state.refreshGradeWatcher(cookies: cookies)
    }

    private static func liveCanvasCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter {
                    $0.domain.localizedCaseInsensitiveContains("canvas")
                })
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
