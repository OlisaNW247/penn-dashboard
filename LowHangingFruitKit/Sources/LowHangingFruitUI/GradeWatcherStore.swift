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

    /// Manual category-weight overrides (CP4 UI), keyed courseID -> categoryID
    /// -> percent. This is the ONLY fallback when Canvas has no weights
    /// (docs/grades.md §6), so it's always editable regardless of course mode.
    /// Persisted the same way as `AppState.manualAssignments` — JSON-encoded
    /// into UserDefaults — since these are small, non-secret UI preferences,
    /// not session credentials (unlike `SessionCookieStore`, which is Keychain).
    @Published private(set) var manualWeights: [String: [String: Double]] = [:]
    private static let manualWeightsKey = "gradeWatcherManualWeights"

    init() {
        self.manualWeights = Self.loadManualWeights()
    }

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

    /// Convenience overload the UI uses: reads this course's persisted manual
    /// weight overrides (if any) and feeds them into the engine automatically,
    /// so views don't have to thread `manualWeights(courseID:)` through by hand.
    func breakdown(courseID: String, now: Date = Date()) -> GradeBreakdown? {
        breakdown(courseID: courseID, manualWeights: manualWeights(courseID: courseID), now: now)
    }

    // MARK: - Manual weight overrides (CP4)

    func manualWeights(courseID: String) -> [String: Double] {
        manualWeights[courseID] ?? [:]
    }

    /// Sets (or, with `weight: nil`, clears) a manual weight override for one
    /// category. Clearing falls back to Canvas's weight (or 0 in points mode).
    func setManualWeight(courseID: String, categoryID: String, weight: Double?) {
        var courseWeights = manualWeights[courseID] ?? [:]
        if let weight {
            courseWeights[categoryID] = weight
        } else {
            courseWeights.removeValue(forKey: categoryID)
        }
        if courseWeights.isEmpty {
            manualWeights.removeValue(forKey: courseID)
        } else {
            manualWeights[courseID] = courseWeights
        }
        persistManualWeights()
    }

    private func persistManualWeights() {
        guard let data = try? JSONEncoder().encode(manualWeights) else { return }
        UserDefaults.standard.set(data, forKey: Self.manualWeightsKey)
    }

    private static func loadManualWeights() -> [String: [String: Double]] {
        guard let data = UserDefaults.standard.data(forKey: manualWeightsKey),
              let dict = try? JSONDecoder().decode([String: [String: Double]].self, from: data)
        else { return [:] }
        return dict
    }

    // MARK: - Canvas cross-check (docs/grades.md §1, Decision 2)

    /// Canvas's own `computed_current_score` for this course, when available
    /// (nil when the professor hides totals — not an error).
    func canvasComputedScore(courseID: String) -> Double? {
        snapshots[courseID]?.canvasComputedCurrentScore
    }

    /// Whether our computed grade materially disagrees with Canvas's own
    /// number (> 1.0 percentage point). False whenever there's no Canvas
    /// number to compare against, or we don't have a computed grade yet.
    func differsFromCanvas(courseID: String, currentPercent: Double?) -> Bool {
        guard let currentPercent else { return false }
        return GradeEngine.differsFromCanvas(computed: currentPercent, canvasScore: canvasComputedScore(courseID: courseID))
    }
}
