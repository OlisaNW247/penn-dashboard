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
    /// calendar day, recorded on each successful refresh. This is the memory
    /// behind the "this week" delta chip (docs/grades.md §11): the trajectory
    /// chart is *reconstructed* from due dates, but "what changed since I
    /// last looked" needs real observations.
    ///
    /// Unlike the settings above it is **not** a UserDefaults blob any more.
    /// The rows live in `historyStore` (SwiftData, App Group container); this
    /// property is a read-through cache of them so the views that observe it
    /// don't have to hit the store on every render. `historyStore` is the
    /// source of truth — never write to this directly.
    @Published private(set) var history: [String: [GradeHistoryPoint]] = [:]

    /// Durable backing for `history`. Optional so that a store that can't be
    /// created degrades to session-only history rather than crashing, exactly
    /// like `AppState.assignmentStore`.
    private let historyStore: GradeHistoryStore?

    typealias GradeHistoryPoint = GradeHistoryStore.Observation

    /// Courses the user explicitly asked LHF to **watch**. Watching is an
    /// opt-in per class: it unlocks the full grade report (projections,
    /// what's-left, target planning) and is where a syllabus gets attached.
    ///
    /// Every selected class still gets a card and a grade — watching doesn't
    /// gate the numbers. It exists because attaching and confirming a syllabus
    /// is per-course setup work, and asking for it across five classes at once
    /// is how a feature gets abandoned on first launch.
    @Published private(set) var watchedCourseIDs: Set<String> = []
    private static let watchedCoursesKey = "gradeWatcherWatchedCourses"

    /// `historyStore` is injectable so tests can drive observed history across
    /// simulated launches; the default is the shared App Group store.
    init(historyStore: GradeHistoryStore? = nil) {
        let historyStore = historyStore ?? GradeHistoryStore.makeDefault()
        self.historyStore = historyStore
        self.manualWeights = Self.loadManualWeights()
        self.confirmedGradescopeMappings = Self.loadConfirmedGradescopeMappings()
        self.history = historyStore?.allHistory() ?? [:]
        self.watchedCourseIDs = Set(UserDefaults.lhf.stringArray(forKey: Self.watchedCoursesKey) ?? [])
        self.syllabusSchemes = Self.loadSyllabusSchemes()
        self.confirmedCategoryMappings = Self.loadConfirmedCategoryMappings()
    }

    func isWatching(_ courseID: String) -> Bool {
        watchedCourseIDs.contains(courseID)
    }

    func setWatching(_ watching: Bool, courseID: String) {
        if watching {
            watchedCourseIDs.insert(courseID)
        } else {
            watchedCourseIDs.remove(courseID)
        }
        UserDefaults.lhf.set(Array(watchedCourseIDs), forKey: Self.watchedCoursesKey)
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
            // Being "logged in" to the dashboard isn't enough: the assignment
            // list rides a cookieless ICS feed, while grades need a real Canvas
            // session. An account connected before this app stored Canvas
            // cookies has none, so say what actually fixes it.
            error = "No saved Canvas session. Grades need a live Canvas login \u{2014} the assignment list doesn\u{2019}t. Reconnect Canvas in Settings to enable grades."
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
        var succeeded = 0

        // Service-scoped since the login hardening: the cookie stores are
        // isolated per service, so asking for Gradescope's cookies directly is
        // both correct and cheaper than filtering every service's by domain.
        let gradescopeConnected = !SessionCookieStore.load(service: .gradescope).isEmpty

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
                succeeded += 1
                recordHistory(courseID: courseID, now: now)
            } catch CanvasGradesClient.Error.sessionExpired {
                sawSessionExpired = true
            } catch {
                lastFailure = error
            }
        }

        if fetchedAny {
            lastRefreshed = now
        }

        let outcome = Self.outcome(
            total: courseIDs.count,
            succeeded: succeeded,
            sawSessionExpired: sawSessionExpired,
            lastFailure: lastFailure
        )
        isSessionExpired = outcome.isSessionExpired
        error = outcome.error
    }

    struct RefreshOutcome: Equatable {
        let isSessionExpired: Bool
        let error: String?
    }

    /// Turns a per-course refresh tally into the banner state. Pure and
    /// `static` so it can be tested without a live Canvas session (the same
    /// seam `CanvasGradesClient.decodeSnapshot` uses).
    ///
    /// Two judgements live here:
    ///
    /// 1. **A Canvas session is global.** If even one course fetched with these
    ///    cookies, the login is alive — so a 401 on another course means *that
    ///    course* is restricted, not that the session lapsed. Canvas commonly
    ///    does this for a concluded term, which is precisely when a student is
    ///    looking back at a class they just finished. Reporting "your session
    ///    expired" there dims every grade on the screen and sends them through
    ///    an SSO login that fixes nothing.
    /// 2. **A partial failure is not a failed sync.** Four classes refreshing
    ///    and one failing used to raise the same blanket error as a total
    ///    outage, over cards that had just updated correctly.
    static func outcome(
        total: Int,
        succeeded: Int,
        sawSessionExpired: Bool,
        lastFailure: Swift.Error?
    ) -> RefreshOutcome {
        let failed = max(0, total - succeeded)
        guard failed > 0 else { return RefreshOutcome(isSessionExpired: false, error: nil) }

        if succeeded > 0 {
            let noun = failed == 1 ? "class" : "classes"
            return RefreshOutcome(
                isSessionExpired: false,
                error: "Couldn\u{2019}t refresh \(failed) of \(total) \(noun) — those are showing their last grades."
            )
        }

        if sawSessionExpired {
            return RefreshOutcome(
                isSessionExpired: true,
                error: "Your Canvas session expired — grades are showing the last refresh until you reconnect."
            )
        }
        return RefreshOutcome(
            isSessionExpired: false,
            error: "Grade Watcher sync failed: \(lastFailure?.localizedDescription ?? "unknown error")"
        )
    }

    /// Drops every fetched and derived grade artifact. Called when the user
    /// disconnects Canvas — grades are downstream of that session, so leaving
    /// snapshots (and the observed-history trail behind the week delta) on
    /// disk after a sign-out would keep showing a signed-out student's grades.
    /// User-authored settings (manual weights, confirmed Gradescope mappings,
    /// syllabus schemes) are preserved: re-connecting shouldn't make the user
    /// redo their setup.
    func clearAll() {
        snapshots = [:]
        gradescopeItemsByCourse = [:]
        history = [:]
        historyStore?.clearAll()
        lastRefreshed = nil
        isSessionExpired = false
        error = nil
    }

    /// Seeds the store from bundled fixtures for preview (demo) mode — no
    /// network, no cookies, no error banner. Everything downstream (the
    /// engine, the overlay, projections, the report) then runs its real code
    /// path against fixture snapshots, so the demo exercises the actual
    /// feature rather than a mock of it.
    func loadPreviewSnapshots(_ fixtures: [String: CourseGradeSnapshot], now: Date = Date()) {
        snapshots = fixtures
        gradescopeItemsByCourse = [:]
        lastRefreshed = now
        isSessionExpired = false
        error = nil
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
        syllabusWeightedCategoryIDs: Set<String> = [],
        now: Date = Date()
    ) -> GradeBreakdown? {
        guard let snapshot = snapshots[courseID] else { return nil }
        return GradeEngine.compute(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: gradeCategories(courseID: courseID),
            manualWeights: manualWeights,
            dropLowestOverrides: dropLowestOverrides,
            syllabusWeightedCategoryIDs: syllabusWeightedCategoryIDs,
            now: now
        ))
    }

    /// Convenience overload the UI uses: folds in this course's syllabus
    /// weights and hand-typed overrides automatically, so views don't have to
    /// thread weight resolution through by hand.
    func breakdown(courseID: String, now: Date = Date()) -> GradeBreakdown? {
        breakdown(
            courseID: courseID,
            manualWeights: effectiveWeights(courseID: courseID),
            syllabusWeightedCategoryIDs: syllabusWeightedCategoryIDs(courseID: courseID),
            now: now
        )
    }

    /// Where this course can still finish (docs/grades.md §13) — floor,
    /// ceiling, pace, and what's left. Nil until the course has a snapshot.
    func projection(courseID: String, now: Date = Date()) -> GradeProjection? {
        guard let breakdown = breakdown(courseID: courseID, now: now) else { return nil }
        return GradeProjector.project(breakdown)
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
        UserDefaults.lhf.set(data, forKey: Self.confirmedGradescopeMappingsKey)
    }

    private static func loadConfirmedGradescopeMappings() -> [String: [String: String]] {
        guard let data = UserDefaults.lhf.data(forKey: confirmedGradescopeMappingsKey),
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
        UserDefaults.lhf.set(data, forKey: Self.manualWeightsKey)
    }

    private static func loadManualWeights() -> [String: [String: Double]] {
        guard let data = UserDefaults.lhf.data(forKey: manualWeightsKey),
              let dict = try? JSONDecoder().decode([String: [String: Double]].self, from: data)
        else { return [:] }
        return dict
    }

    // MARK: - Syllabus (docs/grades.md §13)

    /// The syllabus the user attached to each watched course, by course id.
    @Published private(set) var syllabusSchemes: [String: AttachedSyllabus] = [:]
    private static let syllabusSchemesKey = "gradeWatcherSyllabusSchemes"

    /// User-confirmed syllabus-category → Canvas-category pairings, keyed
    /// courseID -> syllabus category id -> Canvas assignment group id. Same
    /// confirm-once pattern as `confirmedGradescopeMappings`.
    @Published private(set) var confirmedCategoryMappings: [String: [String: String]] = [:]
    private static let confirmedCategoryMappingsKey = "gradeWatcherConfirmedCategoryMappings"

    func syllabus(courseID: String) -> AttachedSyllabus? {
        syllabusSchemes[courseID]
    }

    /// Attaching also starts watching: you don't add a syllabus to a class you
    /// aren't following.
    func attachSyllabus(_ syllabus: AttachedSyllabus, courseID: String) {
        syllabusSchemes[courseID] = syllabus
        persistSyllabusSchemes()
        setWatching(true, courseID: courseID)
    }

    /// Removes the syllabus and every mapping confirmed against it — those
    /// pairings are meaningless once the categories they referenced are gone.
    func detachSyllabus(courseID: String) {
        syllabusSchemes.removeValue(forKey: courseID)
        confirmedCategoryMappings.removeValue(forKey: courseID)
        persistSyllabusSchemes()
        persistConfirmedCategoryMappings()
    }

    /// This course's syllabus categories matched against its Canvas assignment
    /// groups. Nil when no syllabus is attached or the course isn't fetched.
    func syllabusMatch(courseID: String) -> SyllabusMatcher.Result? {
        guard let syllabus = syllabusSchemes[courseID] else { return nil }
        let categories = gradeCategories(courseID: courseID)
        guard !categories.isEmpty else { return nil }
        return SyllabusMatcher.match(
            scheme: syllabus.scheme,
            canvasCategories: categories,
            confirmed: confirmedCategoryMappings[courseID] ?? [:]
        )
    }

    func confirmCategoryMapping(courseID: String, syllabusCategoryID: String, canvasCategoryID: String) {
        var forCourse = confirmedCategoryMappings[courseID] ?? [:]
        forCourse[syllabusCategoryID] = canvasCategoryID
        confirmedCategoryMappings[courseID] = forCourse
        persistConfirmedCategoryMappings()
    }

    func clearCategoryMapping(courseID: String, syllabusCategoryID: String) {
        guard var forCourse = confirmedCategoryMappings[courseID] else { return }
        forCourse.removeValue(forKey: syllabusCategoryID)
        confirmedCategoryMappings[courseID] = forCourse.isEmpty ? nil : forCourse
        persistConfirmedCategoryMappings()
    }

    /// Canvas category id → weight for the categories a confirmed syllabus
    /// covers. Empty unless coverage is complete — a partial syllabus must not
    /// reach the engine, whose manual weights are all-or-nothing.
    func syllabusWeights(courseID: String) -> [String: Double] {
        syllabusMatch(courseID: courseID)?.canvasWeights ?? [:]
    }

    func syllabusWeightedCategoryIDs(courseID: String) -> Set<String> {
        Set(syllabusWeights(courseID: courseID).keys)
    }

    /// The weights actually used for this course: syllabus first, with any
    /// hand-typed override winning. A user who edits a weight after importing
    /// a syllabus means it — the edit is the more recent, more deliberate
    /// statement of intent.
    func effectiveWeights(courseID: String) -> [String: Double] {
        syllabusWeights(courseID: courseID).merging(manualWeights(courseID: courseID)) { _, manual in manual }
    }

    /// This course's letter-grade cutoffs: the syllabus's own table when it
    /// published one, otherwise the standard estimate.
    func cutoffs(courseID: String) -> GradeCutoffs {
        syllabusSchemes[courseID]?.scheme.cutoffs ?? .standard
    }

    /// Categories where the syllabus promises more items than Canvas lists —
    /// work that's coming but hasn't been created yet.
    func countGaps(courseID: String) -> [SyllabusCountGap] {
        guard let syllabus = syllabusSchemes[courseID],
              let match = syllabusMatch(courseID: courseID)
        else { return [] }
        return SyllabusReconciler.countGaps(
            match: match,
            scheme: syllabus.scheme,
            canvasCategories: gradeCategories(courseID: courseID)
        )
    }

    private func persistSyllabusSchemes() {
        guard let data = try? JSONEncoder().encode(syllabusSchemes) else { return }
        UserDefaults.lhf.set(data, forKey: Self.syllabusSchemesKey)
    }

    private static func loadSyllabusSchemes() -> [String: AttachedSyllabus] {
        guard let data = UserDefaults.lhf.data(forKey: syllabusSchemesKey),
              let dict = try? JSONDecoder().decode([String: AttachedSyllabus].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistConfirmedCategoryMappings() {
        guard let data = try? JSONEncoder().encode(confirmedCategoryMappings) else { return }
        UserDefaults.lhf.set(data, forKey: Self.confirmedCategoryMappingsKey)
    }

    private static func loadConfirmedCategoryMappings() -> [String: [String: String]] {
        guard let data = UserDefaults.lhf.data(forKey: confirmedCategoryMappingsKey),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
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
    /// the history. The store owns both that rule and the 180-entry cap; this
    /// just re-reads the course back into the published cache.
    private func recordHistory(courseID: String, now: Date) {
        guard let percent = breakdown(courseID: courseID, now: now)?.currentPercent else { return }
        guard let historyStore else {
            // No durable store (creation failed): keep the old in-memory shape
            // so the delta chip still works within this session.
            var entries = history[courseID] ?? []
            if let last = entries.last, Calendar.current.isDate(last.date, inSameDayAs: now) {
                entries[entries.count - 1] = GradeHistoryPoint(date: now, percent: percent)
            } else {
                entries.append(GradeHistoryPoint(date: now, percent: percent))
            }
            history[courseID] = Array(entries.suffix(GradeHistoryStore.retentionPerCourse))
            return
        }
        historyStore.record(courseID: courseID, percent: percent, now: now)
        history[courseID] = historyStore.history(courseID: courseID)
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
