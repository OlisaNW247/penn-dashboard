import Foundation
import LowHangingFruitKit

/// Fetches and holds Canvas grade snapshots for the class-picker-**selected**
/// courses only (docs/grades.md Decision 4 — a course hidden from the
/// dashboard is also hidden from Grade Watcher). Mirrors the cookie-session
/// posture of `AutoSyncCoordinator` / `AppState.syncGradescope`: on failure we
/// keep the last snapshot and surface a distinct "session expired" state
/// rather than clearing anything, since grades should look stale, not broken
/// (docs/grades.md §7).
///
/// This is intentionally thin — the UI (cards, manual weight editing) is
/// CP4's job. CP3 only makes real per-course data reachable.
@MainActor
final class GradeWatcherStore: ObservableObject {
    /// Latest snapshot per Canvas course id. Kept across a failed refresh so a
    /// lapsed session degrades to "stale," never to blank.
    @Published private(set) var snapshots: [String: CourseGradeSnapshot] = [:]
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSessionExpired = false
    @Published var error: String?

    /// Refreshes grades for exactly the courses the caller passes in — this
    /// store never decides course selection itself. Pass
    /// `AppState.selectedCanvasCourseIDs()` to honor the class picker.
    func refresh(courseIDs: [String: String], cookies: [HTTPCookie], now: Date = Date()) async {
        guard !isRefreshing else { return }
        guard !cookies.isEmpty else {
            error = "No Canvas session was found yet. Finish logging in to Canvas, then try again."
            return
        }
        guard !courseIDs.isEmpty else { return }

        isRefreshing = true
        error = nil
        defer { isRefreshing = false }

        let client = CanvasGradesClient(cookies: cookies)
        var sawSessionExpired = false
        var lastFailure: Swift.Error?
        var fetchedAny = false

        for courseID in courseIDs.keys.sorted() {
            do {
                let snapshot = try await client.fetchSnapshot(courseID: courseID, now: now)
                snapshots[courseID] = snapshot
                fetchedAny = true
            } catch CanvasGradesClient.Error.sessionExpired {
                sawSessionExpired = true
            } catch {
                lastFailure = error
            }
        }

        isSessionExpired = sawSessionExpired
        if fetchedAny {
            lastRefreshed = now
        }

        if sawSessionExpired {
            error = "Your Canvas session expired — grades are showing the last refresh until you reconnect."
        } else if let lastFailure {
            error = "Grade Watcher sync failed: \(lastFailure.localizedDescription)"
        }
    }

    /// Runs `GradeEngine.compute()` over the stored snapshot for one course,
    /// or nil if that course hasn't been fetched yet.
    func breakdown(
        courseID: String,
        manualWeights: [String: Double] = [:],
        dropLowestOverrides: [String: Int] = [:],
        now: Date = Date()
    ) -> GradeBreakdown? {
        guard let snapshot = snapshots[courseID] else { return nil }
        return GradeEngine.compute(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: snapshot.categories,
            manualWeights: manualWeights,
            dropLowestOverrides: dropLowestOverrides,
            now: now
        ))
    }
}
