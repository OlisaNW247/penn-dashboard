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
    /// This course's Canvas-only assignment groups (`fetchSnapshot`'s output,
    /// no Gradescope overlay applied). Kept across a failed refresh so a
    /// lapsed session degrades to "stale," never to blank. The overlay is
    /// recomputed on demand by `overlayResult(courseID:)` instead of being
    /// baked in here, so confirming a suggested match (which only changes
    /// `confirmedGradescopeMappings`) recomputes the fill without a network
    /// refresh.
    @Published private(set) var snapshots: [String: CourseGradeSnapshot] = [:]
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSessionExpired = false
    @Published var error: String?

    /// This course's Gradescope items, already scoped by course name — the
    /// raw input `overlayResult(courseID:)` re-applies the overlay against on
    /// every read. Empty when Gradescope isn't connected. Not `@Published`:
    /// it only ever changes in lockstep with `snapshots` inside `refresh`.
    private var gradescopeItemsByCourse: [String: [Assignment]] = [:]

    /// Manual category-weight overrides (CP4 UI), keyed courseID -> categoryID
    /// -> percent. This is the ONLY fallback when Canvas has no weights
    /// (docs/grades.md §6), so it's always editable regardless of course mode.
    /// Persisted the same way as `AppState.manualAssignments` — JSON-encoded
    /// into UserDefaults — since these are small, non-secret UI preferences,
    /// not session credentials (unlike `SessionCookieStore`, which is Keychain).
    @Published private(set) var manualWeights: [String: [String: Double]] = [:]
    private static let manualWeightsKey = "gradeWatcherManualWeights"

    /// User-confirmed Gradescope → Canvas fuzzy matches (docs/grades.md §5,
    /// last paragraph), keyed courseID -> `GradescopeOverlay.normalizedKey` ->
    /// Canvas item id. Once confirmed, a mapping auto-applies exactly like an
    /// exact match on every subsequent `overlayResult`/`refresh`, so the user
    /// isn't re-asked each sync. Persisted the same way as `manualWeights`.
    @Published private(set) var confirmedGradescopeMappings: [String: [String: String]] = [:]
    private static let confirmedGradescopeMappingsKey = "gradeWatcherConfirmedGradescopeMappings"

    /// Observed grade history — one (day, percent) entry per course per
    /// calendar day, appended on each successful refresh. This is the memory
    /// behind the "this week" delta chip (docs/grades.md §11): the trajectory
    /// chart is *reconstructed* from due dates, but "what changed since I
    /// last looked" needs real observations. Persisted like `manualWeights`;
    /// pruned to the most recent 180 entries per course.
    @Published private(set) var history: [String: [GradeHistoryPoint]] = [:]
    private static let historyKey = "gradeWatcherHistory"

    struct GradeHistoryPoint: Codable, Hashable, Sendable {
        let date: Date
        let percent: Double
    }

    init() {
        self.manualWeights = Self.loadManualWeights()
        self.confirmedGradescopeMappings = Self.loadConfirmedGradescopeMappings()
        self.history = Self.loadHistory()
    }

    /// Refreshes grades for exactly the courses the caller passes in — this
    /// store never decides course selection itself. Pass
    /// `AppState.selectedCanvasCourseIDs()` to honor the class picker.
    ///
    /// `gradescopeItems` is whatever Gradescope has already scraped this
    /// launch (`AppState.gradescopeItems`, itself gated by
    /// `AutoSyncCoordinator`'s 15-minute throttle) — this piggybacks on that
    /// data rather than triggering a second, unthrottled Gradescope fetch of
    /// its own (docs/grades.md §4/§9). If Gradescope isn't connected
    /// (`SessionCookieStore` has no Gradescope cookies), the overlay is
    /// skipped entirely and courses fall back to Canvas-only scores.
    func refresh(
        courseIDs: [String: String],
        cookies: [HTTPCookie],
        gradescopeItems: [Assignment] = [],
        now: Date = Date()
    ) async {
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

        let gradescopeConnected = SessionCookieStore.load()
            .contains { $0.domain.localizedCaseInsensitiveContains("gradescope") }

        for courseID in courseIDs.keys.sorted() {
            do {
                let snapshot = try await client.fetchSnapshot(courseID: courseID, now: now)
                snapshots[courseID] = snapshot

                // Store the Canvas-only snapshot alongside its raw (course-
                // scoped) Gradescope items; `overlayResult` applies the
                // overlay fresh on every read instead of baking it in here,
                // so a later confirmed match recomputes without a refetch.
                if gradescopeConnected, let courseName = courseIDs[courseID] {
                    gradescopeItemsByCourse[courseID] = gradescopeItems.filter { $0.course == courseName }
                } else {
                    gradescopeItemsByCourse[courseID] = []
                }

                fetchedAny = true
                recordHistory(courseID: courseID, now: now)
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

    // MARK: - Gradescope overlay (recomputed on demand — see `snapshots` doc comment)

    /// Applies the Gradescope overlay fresh against this course's stored
    /// Canvas-only categories, using whatever mappings have been confirmed so
    /// far. Nil if the course hasn't been fetched yet.
    private func overlayResult(courseID: String) -> GradescopeOverlay.Result? {
        guard let snapshot = snapshots[courseID] else { return nil }
        return GradescopeOverlay.apply(
            categories: snapshot.categories,
            gradescopeItems: gradescopeItemsByCourse[courseID] ?? [],
            confirmedMappings: confirmedGradescopeMappings[courseID] ?? [:]
        )
    }

    /// This course's grade categories with the Gradescope overlay applied
    /// (falls back to the Canvas-only categories if there's no overlay data,
    /// and to `[]` if the course hasn't been fetched yet at all). Used both
    /// by `breakdown(courseID:)` and by the UI to look up a category's raw
    /// items (e.g. to detect a `.gradescopeEarly` score for a source badge).
    func gradeCategories(courseID: String) -> [GradeCategory] {
        overlayResult(courseID: courseID)?.categories ?? snapshots[courseID]?.categories ?? []
    }

    /// This course's unmatched Gradescope scores from the last refresh (empty
    /// if Gradescope isn't connected or nothing was unmatched).
    func unmatchedGradescopeScores(courseID: String) -> [GradescopeOverlay.UnmatchedItem] {
        overlayResult(courseID: courseID)?.unmatched ?? []
    }

    /// Lower-confidence fuzzy matches awaiting user confirmation
    /// (docs/grades.md §5 item 4) — never counted until confirmed via
    /// `confirmSuggestedMatch`.
    func suggestedGradescopeMatches(courseID: String) -> [GradescopeOverlay.SuggestedMatch] {
        overlayResult(courseID: courseID)?.suggested ?? []
    }

    /// Runs `GradeEngine.compute()` over this course's overlay-applied
    /// categories, or nil if that course hasn't been fetched yet.
    func breakdown(
        courseID: String,
        manualWeights: [String: Double] = [:],
        dropLowestOverrides: [String: Int] = [:],
        now: Date = Date()
    ) -> GradeBreakdown? {
        guard let snapshot = snapshots[courseID] else { return nil }
        return GradeEngine.compute(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: gradeCategories(courseID: courseID),
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

    /// Confirms a fuzzy-matched suggestion (docs/grades.md §5 item 4): fills
    /// the Canvas item with the Gradescope score right away by persisting the
    /// mapping, which the next `overlayResult` read (immediate, since this
    /// mutates a `@Published` property) applies exactly like an exact match.
    func confirmSuggestedMatch(courseID: String, match: GradescopeOverlay.SuggestedMatch) {
        var courseMappings = confirmedGradescopeMappings[courseID] ?? [:]
        courseMappings[GradescopeOverlay.normalizedKey(match.gradescopeTitle)] = match.itemID
        confirmedGradescopeMappings[courseID] = courseMappings
        persistConfirmedGradescopeMappings()
    }

    private func persistConfirmedGradescopeMappings() {
        guard let data = try? JSONEncoder().encode(confirmedGradescopeMappings) else { return }
        UserDefaults.standard.set(data, forKey: Self.confirmedGradescopeMappingsKey)
    }

    private static func loadConfirmedGradescopeMappings() -> [String: [String: String]] {
        guard let data = UserDefaults.standard.data(forKey: confirmedGradescopeMappingsKey),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dict
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

    // MARK: - Trajectory, history & week delta (docs/grades.md §11)

    /// The course's reconstructed grade-over-time line, overlay-applied and
    /// honoring persisted manual weights — the same inputs as `breakdown`, so
    /// the line's endpoint always equals the card's headline number.
    func trajectory(courseID: String, now: Date = Date()) -> [GradeEngine.TrajectoryPoint] {
        guard let snapshot = snapshots[courseID] else { return [] }
        return GradeEngine.trajectory(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: gradeCategories(courseID: courseID),
            manualWeights: manualWeights(courseID: courseID),
            now: now
        ))
    }

    /// Change in the course grade vs ~a week ago: current minus the recorded
    /// observation closest to 7 days back. Requires a baseline at least 24h
    /// old so a refresh can't compare against itself; nil until one exists
    /// (i.e. the chip stays hidden on day one of watching).
    func weekDelta(courseID: String, now: Date = Date()) -> Double? {
        guard let current = breakdown(courseID: courseID, now: now)?.currentPercent else { return nil }
        let target = now.addingTimeInterval(-7 * 86_400)
        let baseline = (history[courseID] ?? [])
            .filter { $0.date <= now.addingTimeInterval(-86_400) }
            .min { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
        guard let baseline else { return nil }
        return current - baseline.percent
    }

    /// Records today's computed grade for one course, replacing an earlier
    /// entry from the same calendar day so repeated refreshes can't flood
    /// the history.
    private func recordHistory(courseID: String, now: Date) {
        guard let percent = breakdown(courseID: courseID, now: now)?.currentPercent else { return }
        var entries = history[courseID] ?? []
        if let last = entries.last, Calendar.current.isDate(last.date, inSameDayAs: now) {
            entries[entries.count - 1] = GradeHistoryPoint(date: now, percent: percent)
        } else {
            entries.append(GradeHistoryPoint(date: now, percent: percent))
        }
        history[courseID] = Array(entries.suffix(180))
        persistHistory()
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    private static func loadHistory() -> [String: [GradeHistoryPoint]] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let dict = try? JSONDecoder().decode([String: [GradeHistoryPoint]].self, from: data)
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
