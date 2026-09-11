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

    /// Diagnostics only — never surfaced in normal UI. `refresh` folds every
    /// per-course failure into one banner (`outcome(...)` above), which is
    /// the right call for the student but useless for telling "this course's
    /// grades fetch is silently failing" apart from "the join to this
    /// assignment's Canvas id is broken" apart from "Canvas reported it as
    /// not-submitted." This keeps one short label per Canvas course id from
    /// the most recent refresh that touched it, so `AppState`'s submission
    /// diagnostics can rule hypothesis (a) — a failed grades fetch — in or
    /// out without guessing from the single collapsed error string.
    @Published private(set) var lastRefreshOutcomes: [String: String] = [:]

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
        self.categoryMapEdits = Self.loadCategoryMapEdits()
        self.sharedMappings = Self.loadSharedMappings()
        self.sharedMappingDecisions = Self.loadSharedMappingDecisions()
        self.expectedCounts = Self.loadExpectedCounts()
        self.itemOverrides = Self.loadItemOverrides()
        self.modeOverrides = Self.loadModeOverrides()

        // Round-2 migration: round 1 only ever recorded "excluded" as a flat
        // set (`gradeWatcherExcludedCourses`). Every id in it becomes an
        // explicit `false` (excluded) choice here — the student had already
        // said this course doesn't count, and the storage shape changing
        // underneath them must not silently forget that — and the old key is
        // then removed so this block is a no-op on every later launch.
        // Direct property assignments only (no instance-method calls): a
        // class initializer can't call `self`'s methods until every stored
        // property has a value, and `excludedCourseIDs` below is one of them.
        var choice = Self.loadCourseCountsChoice()
        if let legacy = UserDefaults.lhf.stringArray(forKey: Self.legacyExcludedCourseIDsKey) {
            for id in legacy where choice[id] == nil {
                choice[id] = false
            }
            UserDefaults.lhf.removeObject(forKey: Self.legacyExcludedCourseIDsKey)
            if let data = try? JSONEncoder().encode(choice) {
                UserDefaults.lhf.set(data, forKey: Self.courseCountsChoiceKey)
            }
        }
        self.courseCountsChoice = choice
        // Populated after construction by `AppState.pushGradeWatcherFacts`
        // from synced course-catalog data — never persisted, since it's a
        // pure function of that data and would just go stale sitting in
        // UserDefaults between syncs.
        self.automaticExclusions = []
        self.gradingProfiles = [:]
        self.excludedCourseIDs = Set(choice.compactMap { $0.value ? nil : $0.key })
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
    ///
    /// Courses are fetched with **at most 3 in flight at once**, not fully
    /// sequential and not fully parallel. On a real phone with eight Canvas
    /// sites, fetching them one at a time — each paginating its own
    /// assignment-group requests — took minutes on first launch, and for
    /// every one of those minutes the dashboard kept showing the ICS feed's
    /// view of what's due, which reads as overdue work the student may
    /// already have turned in: the submission signal that rides along with a
    /// grades fetch (`CourseGradeSnapshot.submissions`) simply hadn't landed
    /// yet for whichever course was still waiting its turn. Unbounded
    /// concurrency was rejected too: Canvas rate-limits per session, and
    /// firing eight requests at once from one login is exactly the traffic
    /// shape that trips it, which would turn a slow-but-correct sync into a
    /// pile of `sessionExpired`/`http 4xx` failures that have nothing to do
    /// with whether the session is actually still good. 3 is a bound chosen
    /// to buy most of the wall-clock win without looking like abuse to
    /// Canvas's rate limiter.
    ///
    /// Concurrency only changes *when* each course's network I/O runs, never
    /// how its result is folded into state: every fetch still runs to
    /// completion (a `sessionExpired` on one course does not stop the others,
    /// same as before), and every observable outcome — `snapshots`,
    /// `gradescopeItemsByCourse`, recorded history, `lastRefreshOutcomes`,
    /// the success/failure tally, and the final `error`/`isSessionExpired`
    /// banner — is applied afterward in ascending `courseID` order, exactly
    /// as the old one-at-a-time loop would have produced them. That matters
    /// for two reasons: outcomes have to be deterministic regardless of which
    /// course's network reply happens to land first on a given run, and
    /// `lastRefreshOutcomes` (the diagnostics report) reads as a stable,
    /// sorted list rather than one that reshuffles every refresh for reasons
    /// a student could never explain.
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
            error = "No saved Canvas session. Grades need a live Canvas login. the assignment list doesn\u{2019}t. Reconnect Canvas in Settings to enable grades."
            return
        }
        guard !courseIDs.isEmpty else { return }

        isRefreshing = true
        error = nil
        defer { isRefreshing = false }

        // Canvas's sliding sessions re-mint the session cookie on every
        // authenticated response; `CanvasGradesClient` surfaces those via
        // `refreshedCookieHandler` once a page has actually decoded, and
        // persisting them here is what keeps a session alive from regular
        // use instead of aging out from login time no matter how often the
        // app is opened. `SessionCookieStore` is only ever called from
        // MainActor elsewhere in this codebase (`AutoSyncCoordinator`,
        // `AppState`) even though its Keychain calls are thread-safe on
        // their own, so match that discipline here rather than call it
        // straight from whatever background executor this handler runs on.
        //
        // `CanvasGradesClient` is itself `Sendable` — every stored property is
        // (`URL`, `[HTTPCookie]`, `URLSession`, and a `@Sendable` closure) —
        // so one instance is built here and captured by every child task
        // below instead of constructing one per course; there's nothing
        // course-specific in it that would require isolating separately.
        let client = CanvasGradesClient(cookies: cookies) { rotated in
            Task { @MainActor in
                SessionCookieStore.merge(rotated, service: .canvas)
            }
        }
        var sawSessionExpired = false
        var lastFailure: Swift.Error?
        var fetchedAny = false
        var succeeded = 0

        // Service-scoped since the login hardening: the cookie stores are
        // isolated per service, so asking for Gradescope's cookies directly is
        // both correct and cheaper than filtering every service's by domain.
        let gradescopeConnected = !SessionCookieStore.load(service: .gradescope).isEmpty

        let sortedCourseIDs = courseIDs.keys.sorted()

        // Bounded-concurrency fan-out: start up to 3 fetches, then start one
        // more each time one finishes, until every course has been asked
        // for. Each child task only computes and returns a value — it never
        // touches `self` or any `@Published` property. That's required for
        // correctness (child tasks run off the main actor, so mutating
        // `@Published` state from inside one would be a data race) and it's
        // also what makes the sorted-order application below possible: the
        // network's actual completion order is discarded entirely, kept only
        // long enough to know a course is done and another slot is free.
        var resultsByCourse: [String: Result<CourseGradeSnapshot, Swift.Error>] = [:]
        resultsByCourse.reserveCapacity(sortedCourseIDs.count)
        await withTaskGroup(of: (courseID: String, result: Result<CourseGradeSnapshot, Swift.Error>).self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < sortedCourseIDs.count else { return }
                let courseID = sortedCourseIDs[nextIndex]
                nextIndex += 1
                group.addTask {
                    do {
                        let snapshot = try await client.fetchSnapshot(courseID: courseID, now: now)
                        return (courseID, .success(snapshot))
                    } catch {
                        return (courseID, .failure(error))
                    }
                }
            }

            let initialBatch = min(3, sortedCourseIDs.count)
            for _ in 0..<initialBatch { addNext() }

            while let finished = await group.next() {
                resultsByCourse[finished.courseID] = finished.result
                addNext()
            }
        }

        // Apply every result in ascending-courseID order — see the doc
        // comment above for why this has to be a second pass over
        // `sortedCourseIDs` rather than folded into the fetch loop itself.
        for courseID in sortedCourseIDs {
            guard let result = resultsByCourse[courseID] else { continue }
            switch result {
            case let .success(snapshot):
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
                lastRefreshOutcomes[courseID] = "ok"
            case let .failure(fetchError):
                if case CanvasGradesClient.Error.sessionExpired = fetchError {
                    sawSessionExpired = true
                    lastRefreshOutcomes[courseID] = "sessionExpired"
                } else {
                    lastFailure = fetchError
                    lastRefreshOutcomes[courseID] = Self.fetchOutcomeLabel(for: fetchError)
                }
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

    /// Short, privacy-safe label for `lastRefreshOutcomes` — pure so it's
    /// testable without a live session. Never includes a URL: `.http`'s
    /// associated `url` can carry a query-string token (Canvas API calls are
    /// cookie-authenticated, but some proxies append one), so only the status
    /// code is reported.
    static func fetchOutcomeLabel(for error: Swift.Error) -> String {
        guard let gradesError = error as? CanvasGradesClient.Error else { return "error" }
        switch gradesError {
        case .sessionExpired:
            return "sessionExpired"
        case let .http(status, _):
            return "http \(status)"
        case .decodingFailed:
            return "decode"
        case .notHTTP:
            return "notHTTP"
        case .invalidURL:
            return "invalidURL"
        }
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
                error: "Couldn\u{2019}t refresh \(failed) of \(total) \(noun). those are showing their last grades."
            )
        }

        if sawSessionExpired {
            return RefreshOutcome(
                isSessionExpired: true,
                error: "Your Canvas session expired. grades are showing the last refresh until you reconnect."
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
        expectedCounts: [String: Int] = [:],
        itemOverrides: [String: GradeItemOverride] = [:],
        modeOverride: GradingMode? = nil,
        categoryMap: GradeCategoryMap? = nil,
        now: Date = Date()
    ) -> GradeBreakdown? {
        guard let snapshot = snapshots[courseID] else { return nil }
        return GradeEngine.compute(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: gradeCategories(courseID: courseID),
            manualWeights: manualWeights,
            dropLowestOverrides: dropLowestOverrides,
            syllabusWeightedCategoryIDs: syllabusWeightedCategoryIDs,
            now: now,
            expectedCounts: expectedCounts,
            itemOverrides: itemOverrides,
            modeOverride: modeOverride,
            categoryMap: categoryMap
        ))
    }

    /// Convenience overload the UI uses: folds in this course's category map
    /// (docs above `CategoryMapEdits`), syllabus weights, expected counts,
    /// and every hand-typed override automatically, so views don't have to
    /// thread resolution through by hand — and so every number the UI shows
    /// (this, `trajectory`, `projection`, `weekDelta`, all of which read
    /// through this or `breakdown` directly) is computed from the same
    /// overrides.
    func breakdown(courseID: String, now: Date = Date()) -> GradeBreakdown? {
        breakdown(
            courseID: courseID,
            manualWeights: effectiveWeights(courseID: courseID),
            syllabusWeightedCategoryIDs: syllabusWeightedCategoryIDs(courseID: courseID),
            expectedCounts: effectiveExpectedCounts(courseID: courseID),
            itemOverrides: itemOverrides(courseID: courseID),
            modeOverride: modeOverride(courseID: courseID),
            categoryMap: effectiveCategoryMap(courseID: courseID),
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

    // MARK: - Item overrides, expected counts, mode & course exclusion
    //
    // Everything below is a student-entered correction, not a fetched fact,
    // so it is persisted the same way `manualWeights` above is: small,
    // non-secret, JSON-encoded UserDefaults, not the SwiftData ledger and not
    // the Keychain. It is cheap to lose (worst case, the student re-types a
    // fixed typo or re-excludes a pass/fail lab next launch) and meaningless
    // off this device, exactly the profile `docs/persistence-explained.md`
    // describes for tier 2.

    /// Category id → the whole-semester expected item count the student
    /// typed by hand, courseID -> categoryID -> count. Distinct from
    /// `syllabusExpectedCounts`, which reads the same number off a confirmed
    /// syllabus instead — `effectiveExpectedCounts` merges the two with the
    /// hand-typed value winning, same precedence as `effectiveWeights`.
    @Published private(set) var expectedCounts: [String: [String: Int]] = [:]
    private static let expectedCountsKey = "gradeWatcherExpectedCounts"

    /// A student's own correction to one Canvas grade item — a wrong score, a
    /// wrong points-possible, or an item they want removed from the math
    /// entirely. `GradeEngine.compute` applies these before any other math,
    /// so a correction flows through weights, drops, and both flavors of %
    /// decided exactly as if Canvas had reported the item that way. courseID
    /// -> itemID -> override.
    @Published private(set) var itemOverrides: [String: [String: GradeItemOverride]] = [:]
    private static let itemOverridesKey = "gradeWatcherItemOverrides"

    /// Forces one course into weighted or points mode, overriding both
    /// Canvas's `apply_assignment_group_weights` flag and the
    /// manual-weights-cover-every-category rule. courseID -> mode.
    @Published private(set) var modeOverrides: [String: GradingMode] = [:]
    private static let modeOverridesKey = "gradeWatcherModeOverrides"

    /// The student's own per-course choice about whether a course counts
    /// toward "the" grade and the GPA estimate — `true` = counts, `false` =
    /// excluded. Absence of a course's id here means "no manual choice,"
    /// which is what leaves room for `automaticExclusions` to apply a
    /// default. A manual choice always wins over the automatic one, in
    /// either direction: a student can choose to count a component the
    /// registrar's catalog data excluded, or exclude one it left in.
    /// Persisted the same way `manualWeights` is (JSON into UserDefaults) —
    /// small, non-secret UI preference, not a session credential.
    @Published private(set) var courseCountsChoice: [String: Bool] = [:]
    private static let courseCountsChoiceKey = "gradeWatcherCourseCountsChoice"

    /// Round 1's flat exclude set — kept only as the migration source read
    /// once at init (see `init`'s doc comment there) and then removed.
    private static let legacyExcludedCourseIDsKey = "gradeWatcherExcludedCourses"

    /// Course ids the registrar's own catalog data says are NOT part of "the"
    /// grade — a pass/fail lab or a zero-credit recitation riding along on
    /// the same course code is its OWN Canvas gradebook, graded on its own
    /// scale (often literally pass/fail, which has no percent to average in
    /// at all), and folding its number into the lecture's would misrepresent
    /// both. Computed by `AppState.pushGradeWatcherFacts` from
    /// `GradeSiteExclusion.isAutomaticallyExcluded` and handed in via
    /// `setAutomaticExclusions` every sync; never persisted here, since it's
    /// a pure function of synced data `AppState` already durably caches.
    /// Applies only where `courseCountsChoice` has no entry for the course —
    /// see `isCourseExcluded`.
    @Published private(set) var automaticExclusions: Set<String> = []

    /// This course's shared grading profile — the weights and category list
    /// another student's device already extracted from a syllabus and the
    /// backend pooled per Canvas course. Feeds `suggestedScheme(courseID:)`.
    /// Handed in via `setGradingProfiles` every sync; never persisted for the
    /// same reason as `automaticExclusions`.
    @Published private(set) var gradingProfiles: [String: CourseGradingProfile] = [:]

    /// Courses currently excluded from "the" grade and the GPA estimate —
    /// the manual `false` choices, unioned with the automatic exclusions
    /// that no manual choice has overridden either way. A `@Published`
    /// mirror (not a plain computed property) so a course card observing
    /// only this property, rather than calling `isCourseExcluded` in its
    /// body, still redraws when either input changes; kept in step by
    /// `recomputeExcludedCourseIDs`, called from every setter below and,
    /// during `init`, computed inline instead (see that comment).
    @Published private(set) var excludedCourseIDs: Set<String> = []

    private func recomputeExcludedCourseIDs() {
        let manuallyIncluded = Set(courseCountsChoice.compactMap { $0.value ? $0.key : nil })
        let manuallyExcluded = Set(courseCountsChoice.compactMap { $0.value ? nil : $0.key })
        excludedCourseIDs = manuallyExcluded.union(automaticExclusions.subtracting(manuallyIncluded))
    }

    /// Sets (or, with `count: nil` or `count < 1`, clears) a hand-typed
    /// expected-item-count override for one category.
    func setExpectedCount(courseID: String, categoryID: String, count: Int?) {
        var courseCounts = expectedCounts[courseID] ?? [:]
        if let count, count >= 1 {
            courseCounts[categoryID] = count
        } else {
            courseCounts.removeValue(forKey: categoryID)
        }
        if courseCounts.isEmpty {
            expectedCounts.removeValue(forKey: courseID)
        } else {
            expectedCounts[courseID] = courseCounts
        }
        persistExpectedCounts()
    }

    /// Sets (or, with `override: nil` or an empty override, clears) a
    /// correction for one Canvas grade item.
    func setItemOverride(courseID: String, itemID: String, override: GradeItemOverride?) {
        var courseOverrides = itemOverrides[courseID] ?? [:]
        if let override, !override.isEmpty {
            courseOverrides[itemID] = override
        } else {
            courseOverrides.removeValue(forKey: itemID)
        }
        if courseOverrides.isEmpty {
            itemOverrides.removeValue(forKey: courseID)
        } else {
            itemOverrides[courseID] = courseOverrides
        }
        persistItemOverrides()
    }

    /// Sets (or, with `mode: nil`, clears) a forced grading mode for one
    /// course.
    func setModeOverride(courseID: String, mode: GradingMode?) {
        if let mode {
            modeOverrides[courseID] = mode
        } else {
            modeOverrides.removeValue(forKey: courseID)
        }
        persistModeOverrides()
    }

    /// Records the student's own choice about whether one course counts
    /// toward "the" grade and the GPA estimate. This always wins over
    /// `automaticExclusions`, in either direction.
    func setCourseExcluded(courseID: String, _ excluded: Bool) {
        courseCountsChoice[courseID] = !excluded
        persistCourseCountsChoice()
        recomputeExcludedCourseIDs()
    }

    /// Replaces the registrar-derived automatic-exclusion set — called once
    /// per `AppState.pushGradeWatcherFacts` run, never merged incrementally,
    /// since the incoming set is already every course's current answer, not
    /// a delta.
    func setAutomaticExclusions(_ courseIDs: Set<String>) {
        automaticExclusions = courseIDs
        recomputeExcludedCourseIDs()
    }

    /// Replaces the pooled grading-profile cache. Same "whole set, not a
    /// delta" shape as `setAutomaticExclusions`, and for the same reason.
    func setGradingProfiles(_ profiles: [CourseGradingProfile]) {
        gradingProfiles = Dictionary(profiles.map { ($0.courseID, $0) }, uniquingKeysWith: { _, newest in newest })
    }

    func manualExpectedCounts(courseID: String) -> [String: Int] {
        expectedCounts[courseID] ?? [:]
    }

    /// Canvas category id → whole-semester expected item count, read off the
    /// attached syllabus's categories through the same confirmed match
    /// `syllabusWeights` uses. Empty when no syllabus is attached, the course
    /// hasn't been fetched, or coverage is incomplete — same gate as
    /// `syllabusWeights`, and for the same reason: a partial mapping can't
    /// say which category an unmatched count belongs to, so a half-covered
    /// syllabus must not reach the engine at all.
    func syllabusExpectedCounts(courseID: String) -> [String: Int] {
        guard let syllabus = syllabusSchemes[courseID],
              let match = syllabusMatch(courseID: courseID),
              match.isCompleteCoverage
        else { return [:] }
        // `normalizedCategories` (not `scheme.categories`) because that's the
        // list `SyllabusMatcher.match` actually walked to build `matches` —
        // same ids either way, but matching the matcher's own input avoids
        // ever having to reason about whether the two lists could diverge.
        let expectedBySyllabusID = Dictionary(
            uniqueKeysWithValues: syllabus.scheme.normalizedCategories.map { ($0.id, $0.expectedItemCount) }
        )
        return match.matches.reduce(into: [:]) { result, m in
            guard m.isApplied,
                  let canvasID = m.canvasCategoryID,
                  let expected = expectedBySyllabusID[m.syllabusCategoryID] ?? nil
            else { return }
            result[canvasID] = expected
        }
    }

    /// The expected counts actually used for this course: syllabus first,
    /// with any hand-typed override winning — same precedence rule as
    /// `effectiveWeights`, and for the same reason: an edit typed after
    /// importing a syllabus is the more recent, more deliberate statement of
    /// intent.
    func effectiveExpectedCounts(courseID: String) -> [String: Int] {
        syllabusExpectedCounts(courseID: courseID).merging(manualExpectedCounts(courseID: courseID)) { _, manual in manual }
    }

    func itemOverrides(courseID: String) -> [String: GradeItemOverride] {
        itemOverrides[courseID] ?? [:]
    }

    func modeOverride(courseID: String) -> GradingMode? {
        modeOverrides[courseID]
    }

    /// Manual choice wins where one exists; otherwise the registrar-derived
    /// automatic exclusion applies. Computed directly from the two inputs
    /// (not read off the `excludedCourseIDs` mirror) so this stays correct
    /// even if a future edit adds a code path that forgets to call
    /// `recomputeExcludedCourseIDs`.
    func isCourseExcluded(courseID: String) -> Bool {
        courseCountsChoice[courseID].map { !$0 } ?? automaticExclusions.contains(courseID)
    }

    /// Why this course currently reads as excluded, for the excluded card's
    /// copy — `nil` when it isn't excluded at all. "you chose" whenever a
    /// manual choice exists (even one that happens to match what the
    /// automatic default would have said), since the honest label is what
    /// the student actually did, not what the registrar's data would have
    /// produced on its own.
    func courseExclusionSource(courseID: String) -> String? {
        guard isCourseExcluded(courseID: courseID) else { return nil }
        if courseCountsChoice[courseID] != nil {
            return "you chose"
        }
        if automaticExclusions.contains(courseID) {
            return "from the registrar"
        }
        return nil
    }

    /// The "how this is calculated" model behind Grade Watcher's explanation
    /// panel, built from the same overlay-applied, overrides-and-all
    /// breakdown every other number on the card reads — so the explanation
    /// can never disagree with the headline it's explaining.
    func explanation(courseID: String, now: Date = Date()) -> GradeExplanation? {
        guard let breakdown = breakdown(courseID: courseID, now: now) else { return nil }
        return GradeExplanation.make(
            from: breakdown,
            canvasScore: canvasComputedScore(courseID: courseID),
            categoryMapProvenance: effectiveCategoryMap(courseID: courseID).provenance
        )
    }

    /// This course's overlay-applied items in one category — Canvas's (and
    /// Gradescope's) own values, unaffected by `itemOverrides`, so an item
    /// override editor can show "Canvas says X" right beside whatever
    /// correction the student has typed.
    func items(courseID: String, categoryID: String) -> [GradeItem] {
        gradeCategories(courseID: courseID).first { $0.id == categoryID }?.items ?? []
    }

    private func persistExpectedCounts() {
        guard let data = try? JSONEncoder().encode(expectedCounts) else { return }
        UserDefaults.lhf.set(data, forKey: Self.expectedCountsKey)
    }

    private static func loadExpectedCounts() -> [String: [String: Int]] {
        guard let data = UserDefaults.lhf.data(forKey: expectedCountsKey),
              let dict = try? JSONDecoder().decode([String: [String: Int]].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistItemOverrides() {
        guard let data = try? JSONEncoder().encode(itemOverrides) else { return }
        UserDefaults.lhf.set(data, forKey: Self.itemOverridesKey)
    }

    private static func loadItemOverrides() -> [String: [String: GradeItemOverride]] {
        guard let data = UserDefaults.lhf.data(forKey: itemOverridesKey),
              let dict = try? JSONDecoder().decode([String: [String: GradeItemOverride]].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistModeOverrides() {
        guard let data = try? JSONEncoder().encode(modeOverrides) else { return }
        UserDefaults.lhf.set(data, forKey: Self.modeOverridesKey)
    }

    private static func loadModeOverrides() -> [String: GradingMode] {
        guard let data = UserDefaults.lhf.data(forKey: modeOverridesKey),
              let dict = try? JSONDecoder().decode([String: GradingMode].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistCourseCountsChoice() {
        guard let data = try? JSONEncoder().encode(courseCountsChoice) else { return }
        UserDefaults.lhf.set(data, forKey: Self.courseCountsChoiceKey)
    }

    private static func loadCourseCountsChoice() -> [String: Bool] {
        guard let data = UserDefaults.lhf.data(forKey: courseCountsChoiceKey),
              let dict = try? JSONDecoder().decode([String: Bool].self, from: data)
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

    /// A scheme built from this course's pooled `CourseGradingProfile` —
    /// another student's device already read a syllabus and shared the
    /// extracted weights server-side — offered as a starting point for a
    /// course that hasn't had its own syllabus attached yet. `nil` once a
    /// syllabus IS attached (attached, not merely suggested, always wins:
    /// this is a suggestion, not a silent override) or when no profile has
    /// synced for this course. Never applied on its own — see
    /// `applySuggestedScheme`.
    func suggestedScheme(courseID: String) -> (scheme: SyllabusGradingScheme, source: SyllabusSource)? {
        guard syllabusSchemes[courseID] == nil else { return nil }
        guard let profile = gradingProfiles[courseID],
              let scheme = SyllabusGradingScheme.from(profile: profile)
        else { return nil }
        return (scheme, .sharedProfile)
    }

    /// Accepts `suggestedScheme(courseID:)` exactly as `attachSyllabus`
    /// accepts a scheme parsed from a real document — same call, same
    /// side effects (persists, starts watching) — because from the ledger's
    /// point of view a synced profile and a freshly parsed syllabus are the
    /// same kind of fact, just from a different origin. A no-op when there
    /// is nothing to suggest (already attached, or no synced profile), so a
    /// stale button tap can never invent a scheme from nothing.
    func applySuggestedScheme(courseID: String) {
        guard let suggestion = suggestedScheme(courseID: courseID) else { return }
        attachSyllabus(
            AttachedSyllabus(scheme: suggestion.scheme, source: suggestion.source, documentName: nil, attachedAt: Date()),
            courseID: courseID
        )
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

    // MARK: - Category map (docs/grades.md §14 addendum, round 2/3)
    //
    // Every course now goes through a `GradeCategoryMap` (`effectiveCategoryMap`
    // below), whether or not it has a syllabus: a course with nothing attached
    // gets a map that mirrors Canvas's own groups one-to-one
    // (`GradeCategoryMapBuilder.mirroringCanvas`), and a course with a syllabus
    // gets one built from the matcher's result
    // (`GradeCategoryMapBuilder.suggested`). That single code path is the
    // point — `GradeRegrouper`/`GradeEngine` only ever have to understand ONE
    // shape of category list, not "categories, or maybe categories-plus-a-map
    // if a syllabus happens to be attached."
    //
    // Layered on top of that suggestion is `CategoryMapEdits`: the student's
    // own corrections, persisted as a DIFF over the suggestion rather than as
    // a saved copy of the resulting map. That distinction is deliberate and
    // not just tidiness — the suggestion underneath a course's map can change
    // out from under the student at any time: the backend re-extracts a
    // syllabus and pools a better version, Canvas creates a new assignment
    // group mid-semester, or a shared grading profile syncs for the first
    // time on a course that had nothing before. A saved SNAPSHOT of the old
    // map would silently stop reflecting any of that the moment the
    // suggestion improves. A diff phrased in terms of ids — "move Canvas
    // group X into map category Y," "exclude item Z" — survives a
    // re-suggestion, because those ids (Canvas group/item ids, and the
    // student's own added-category ids) are stable across it in a way "the
    // whole shape of the map" is not.

    /// The student's edits to a course's category map, persisted; layered
    /// over whatever `suggestedCategoryMap`/`GradeCategoryMapBuilder
    /// .mirroringCanvas` currently proposes by `effectiveCategoryMap`. See
    /// this section's doc comment above for why a diff, not a snapshot.
    struct CategoryMapEdits: Codable, Sendable, Hashable, Equatable {
        /// Canvas assignment-group id → map category id the student moved it
        /// to. `""` means "the student explicitly wants this group
        /// unmapped" — distinct from the group's absence from this
        /// dictionary at all, which means "no edit; let the suggested map's
        /// own fold decide."
        var groupAssignments: [String: String] = [:]
        /// Canvas item id → map category id the student moved it to. An item
        /// removed from this dictionary (rather than set to `""`) goes back
        /// to whatever its Canvas group's fold, or the automatic classifier,
        /// would otherwise say — there's no "explicitly homeless" state for
        /// a single item the way there is for a whole group, since an item
        /// always has a Canvas group to fall back on.
        var itemAssignments: [String: String] = [:]
        /// Items the student excluded by hand, on top of whatever
        /// `GradeItemClassifier` already excludes automatically.
        var excludedItemIDs: Set<String> = []
        /// Items the student pulled back IN after an automatic exclusion.
        /// Kept as its own set rather than expressed as "the absence of an
        /// exclusion," because an automatic exclusion is recomputed fresh on
        /// every `effectiveCategoryMap` call — Canvas's own data changes
        /// (today's zero-point placeholder can get a real score tomorrow,
        /// an attendance item can move once a course gains an
        /// Attendance/Participation category) — so if "back in" were only
        /// ever the absence of an exclusion, the very next automatic pass
        /// would have nothing recorded to override and would silently
        /// re-exclude the item, forcing the student to notice and re-decide
        /// every single refresh. This set is what makes "put it back" a
        /// durable, one-time choice instead of a fight with the classifier.
        var includedItemIDs: Set<String> = []
        /// Category id → the student's own display name for it. Cosmetic
        /// only — a rename never touches weight, membership, or math.
        var renamedCategories: [String: String] = [:]
        /// Categories the student created by hand, entirely outside
        /// anything the syllabus or Canvas suggested. Always carry
        /// `provenance: .student` (see `addCategory`).
        var addedCategories: [GradeCategoryMap.Category] = []
        /// Ids of suggested categories the student removed. A removed
        /// category's own `groupAssignments`/`itemAssignments` entries are
        /// dropped at the same time (see `removeCategory`), so its former
        /// groups/items fall back through the normal unmapped/auto-assigned
        /// path rather than pointing at a category that no longer exists.
        var removedCategoryIDs: Set<String> = []

        var isEmpty: Bool {
            groupAssignments.isEmpty
                && itemAssignments.isEmpty
                && excludedItemIDs.isEmpty
                && includedItemIDs.isEmpty
                && renamedCategories.isEmpty
                && addedCategories.isEmpty
                && removedCategoryIDs.isEmpty
        }
    }

    /// Every course's edits, keyed by course id. Empty for a course the
    /// student has never touched the map for.
    @Published private(set) var categoryMapEdits: [String: CategoryMapEdits] = [:]
    private static let categoryMapEditsKey = "gradeWatcherCategoryMapEdits"

    /// Applies `edits` over `map`, producing the map `GradeRegrouper` and
    /// `GradeEngine` actually see. Pure and `static` — like `outcome(...)`
    /// and `fetchOutcomeLabel(...)` above, this is unit-testable without a
    /// live store — so this is where every edit KIND's semantics live in one
    /// place, rather than scattered across the setters that build a
    /// `CategoryMapEdits` value in the first place.
    static func apply(_ edits: CategoryMapEdits, to map: GradeCategoryMap) -> GradeCategoryMap {
        var result = map

        // Category structure first — additions, removals, then renames —
        // since group/item reassignment below needs to resolve target
        // category ids against the FINAL category list, including anything
        // the student added this pass.
        for category in edits.addedCategories where !result.categories.contains(where: { $0.id == category.id }) {
            result.categories.append(category)
        }
        if !edits.removedCategoryIDs.isEmpty {
            result.categories.removeAll { edits.removedCategoryIDs.contains($0.id) }
        }
        for (categoryID, name) in edits.renamedCategories {
            if let index = result.categories.firstIndex(where: { $0.id == categoryID }) {
                result.categories[index].name = name
            }
        }

        // Group reassignment: a group can only ever belong to one category,
        // so pull it out of every category's fold first, then add it back to
        // its target — "" (or a target that no longer exists, e.g. one the
        // student just removed) leaves it pulled out, i.e. unmapped.
        for (groupID, categoryID) in edits.groupAssignments {
            for index in result.categories.indices {
                result.categories[index].canvasGroupIDs.removeAll { $0 == groupID }
            }
            if !categoryID.isEmpty,
               let index = result.categories.firstIndex(where: { $0.id == categoryID }),
               !result.categories[index].canvasGroupIDs.contains(groupID) {
                result.categories[index].canvasGroupIDs.append(groupID)
            }
        }

        // Item reassignment overrides whatever the group fold or the
        // automatic classifier would otherwise say for that one item.
        for (itemID, categoryID) in edits.itemAssignments {
            result.itemAssignments[itemID] = categoryID
        }

        // Exclusions: manual excludes are added, then manual re-includes
        // clear both the exclusion and its reason — reversing an automatic
        // exclusion has to look exactly like the item was never excluded at
        // all, never like a "hidden" exclusion still lurking underneath.
        result.excludedItemIDs.formUnion(edits.excludedItemIDs)
        for itemID in edits.includedItemIDs {
            result.excludedItemIDs.remove(itemID)
            result.exclusionReasons.removeValue(forKey: itemID)
        }

        return result
    }

    /// A map built from this course's attached syllabus and its Canvas
    /// match, or `nil` when no syllabus is attached — the "suggestion" half
    /// of `effectiveCategoryMap`'s precedence chain. Deliberately not gated
    /// on `SyllabusMatcher.Result.isCompleteCoverage`: `GradeCategoryMapBuilder
    /// .suggested` already only folds APPLIED per-category matches, so a
    /// partially-matched syllabus still produces a map — the unmatched
    /// Canvas groups simply come out of `GradeRegrouper` as visible,
    /// zero-weight "needs a home" entries instead of silently blocking the
    /// whole course from getting a map at all, which is what the OLD
    /// all-or-nothing `syllabusWeights`/`isCompleteCoverage` gate did to the
    /// plain-weights path this doesn't replace.
    func suggestedCategoryMap(courseID: String) -> GradeCategoryMap? {
        guard let syllabus = syllabusSchemes[courseID] else { return nil }

        // Precedence: when the student has accepted the server's
        // `map-categories` suggestion FOR THE COURSE'S CURRENT CANVAS
        // STRUCTURE, build from that shared mapping instead of the local
        // syllabus/Canvas matcher below — "use it" in the report
        // (`acceptSharedMapping`) is the only path here, never automatic.
        // The moment Canvas's own groups change shape (a new assignment
        // group appears, one gets renamed), `currentStructureHash` changes
        // too, the accepted decision no longer matches it, and this falls
        // straight back through to the local suggestion until the student
        // is offered — and accepts — a fresh server suggestion for the new
        // shape. An accepted mapping is a statement about a SPECIFIC
        // structure, not a standing preference that should keep applying
        // once the course it was made about no longer exists in that shape.
        //
        // Deliberately NOT done by folding the server's mapping into
        // `categoryMapEdits` instead: that dictionary is defined (see this
        // section's opening doc comment) as the student's OWN corrections,
        // and `GradeExplanation`, `hasCategoryMapEdits`, and the "reset
        // categories" confirmation copy all read its presence as "you
        // edited this." Writing the server's answer there would make an
        // unmodified, server-suggested mapping read as a personal edit —
        // losing the `.sharedProfile` provenance the report needs to say
        // "as read by locust's server" rather than "you typed this in" —
        // and would survive a re-suggestion as a stale saved copy instead
        // of being recomputed fresh from the current mapping and Canvas
        // structure the way this accepted-decision branch does every time
        // it's read.
        if let hash = currentStructureHash(courseID: courseID),
           let decision = sharedMappingDecisions[courseID],
           decision.choice == .accepted,
           decision.localStructureHash == hash,
           let record = sharedMappings[courseID],
           record.localStructureHash == hash,
           let mapping = record.mapping {
            return GradeCategoryMapBuilder.fromSharedMapping(
                mapping,
                scheme: syllabus.scheme,
                canvasCategories: gradeCategories(courseID: courseID)
            )
        }

        let provenance: GradeCategoryMap.Provenance = syllabus.source == .sharedProfile ? .sharedProfile : .syllabus
        return GradeCategoryMapBuilder.suggested(
            scheme: syllabus.scheme,
            match: syllabusMatch(courseID: courseID),
            canvasCategories: gradeCategories(courseID: courseID),
            provenance: provenance
        )
    }

    /// The map actually in effect for this course: the syllabus-derived
    /// suggestion (or, absent a syllabus, a plain mirror of Canvas's own
    /// groups) with the student's own edits layered on top, and the
    /// automatic classifier re-applied for anything the edits didn't touch.
    /// Never `nil` — see this section's opening doc comment for why every
    /// course goes through one map, syllabus or not.
    ///
    /// The classifier runs a SECOND time here (the suggestion/mirror already
    /// ran it once while it was built) because the student's edits can
    /// change the very structure the classifier reasons about — moving a
    /// group, renaming a category to "Attendance," or adding/removing a
    /// category can change which category is "the" attendance category, or
    /// which Canvas group an item's fold now resolves through. Items the
    /// edits themselves mention are left alone: `GradeItemClassifier
    /// .autoAssignments` already only ever adds entries for items neither
    /// `itemAssignments` nor `excludedItemIDs` already cover, but that
    /// alone isn't enough for `includedItemIDs` — an item the student pulled
    /// back in has, by definition, just had its exclusion REMOVED, so
    /// without excluding it from this second pass too it would read as
    /// "not yet covered" and the classifier would immediately re-exclude it,
    /// silently defeating the whole reason `includedItemIDs` exists.
    func effectiveCategoryMap(courseID: String) -> GradeCategoryMap {
        let base = suggestedCategoryMap(courseID: courseID) ?? GradeCategoryMapBuilder.mirroringCanvas(
            gradeCategories(courseID: courseID),
            courseUsesWeights: snapshots[courseID]?.courseUsesWeights ?? false
        )
        let edits = categoryMapEdits[courseID] ?? CategoryMapEdits()
        var map = Self.apply(edits, to: base)

        let editsMention = Set(edits.itemAssignments.keys)
            .union(edits.excludedItemIDs)
            .union(edits.includedItemIDs)
        let auto = GradeItemClassifier.autoAssignments(canvasCategories: gradeCategories(courseID: courseID), map: map)
        for (itemID, categoryID) in auto.itemAssignments where !editsMention.contains(itemID) {
            map.itemAssignments[itemID] = categoryID
        }
        for itemID in auto.excludedItemIDs where !editsMention.contains(itemID) {
            map.excludedItemIDs.insert(itemID)
        }
        for (itemID, reason) in auto.reasons where !editsMention.contains(itemID) {
            map.exclusionReasons[itemID] = reason
        }

        // Belt-and-suspenders: `apply(edits:to:)` already cleared these, and
        // the loop above already skips anything an include mentions, so this
        // is only ever a no-op in practice — but it's what actually
        // guarantees "included always wins," rather than that guarantee
        // living implicitly in two other pieces of code agreeing with each
        // other.
        for itemID in edits.includedItemIDs {
            map.excludedItemIDs.remove(itemID)
        }

        return map
    }

    func hasCategoryMapEdits(courseID: String) -> Bool {
        !(categoryMapEdits[courseID]?.isEmpty ?? true)
    }

    /// Moves a Canvas assignment group to a different map category, or
    /// (`toCategory: nil`) marks it explicitly unmapped.
    func assignGroup(courseID: String, groupID: String, toCategory categoryID: String?) {
        var edits = categoryMapEdits[courseID] ?? CategoryMapEdits()
        edits.groupAssignments[groupID] = categoryID ?? ""
        setCategoryMapEdits(edits, courseID: courseID)
    }

    /// Moves a single Canvas item to a different map category, or
    /// (`toCategory: nil`) clears the override so the item goes back to
    /// following its Canvas group (or the automatic classifier).
    func assignItem(courseID: String, itemID: String, toCategory categoryID: String?) {
        var edits = categoryMapEdits[courseID] ?? CategoryMapEdits()
        if let categoryID {
            edits.itemAssignments[itemID] = categoryID
        } else {
            edits.itemAssignments.removeValue(forKey: itemID)
        }
        setCategoryMapEdits(edits, courseID: courseID)
    }

    /// Excludes or re-includes one item, on top of the automatic classifier
    /// (docs above `includedItemIDs`).
    func setItemExcluded(courseID: String, itemID: String, _ excluded: Bool) {
        var edits = categoryMapEdits[courseID] ?? CategoryMapEdits()
        if excluded {
            edits.excludedItemIDs.insert(itemID)
            edits.includedItemIDs.remove(itemID)
        } else {
            edits.excludedItemIDs.remove(itemID)
            edits.includedItemIDs.insert(itemID)
        }
        setCategoryMapEdits(edits, courseID: courseID)
    }

    /// Adds a student-authored category (provenance `.student`) with no
    /// Canvas groups or items yet — those come from subsequent
    /// `assignGroup`/`assignItem` calls. Returns the new category's id so a
    /// caller can immediately route something into it. Calling this again
    /// with the same name replaces the earlier addition rather than
    /// duplicating it, since the id (`"map:" + slug(name)`) is derived from
    /// the name alone.
    @discardableResult
    func addCategory(courseID: String, name: String, weightPercent: Double) -> String {
        var edits = categoryMapEdits[courseID] ?? CategoryMapEdits()
        // The id is derived from the name, and the suggested map may already
        // own that id (a student adding "Homework" beside the syllabus's
        // "HomeWorks" lands on "map:homeworks"). `apply` refuses to append a
        // duplicate id, which would leave this edit recorded but invisible —
        // so pick the first free suffix instead, and the new category shows
        // up beside the existing one as the student expects.
        let base = "map:" + GradeCategoryMap.slug(name)
        let taken = Set(effectiveCategoryMap(courseID: courseID).categories.map(\.id))
            .subtracting(edits.addedCategories.map(\.id))
        var id = base
        var suffix = 2
        while taken.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        edits.addedCategories.removeAll { $0.id == id }
        edits.removedCategoryIDs.remove(id)
        edits.addedCategories.append(
            GradeCategoryMap.Category(id: id, name: name, weightPercent: weightPercent, provenance: .student)
        )
        setCategoryMapEdits(edits, courseID: courseID)
        return id
    }

    /// Removes a category — one the student added, or one the suggested map
    /// proposed. Its groups/items are released back to the normal
    /// unmapped/auto-assigned path (see `removedCategoryIDs`'s doc comment).
    func removeCategory(courseID: String, categoryID: String) {
        var edits = categoryMapEdits[courseID] ?? CategoryMapEdits()
        edits.addedCategories.removeAll { $0.id == categoryID }
        edits.removedCategoryIDs.insert(categoryID)
        edits.groupAssignments = edits.groupAssignments.filter { $0.value != categoryID }
        edits.itemAssignments = edits.itemAssignments.filter { $0.value != categoryID }
        setCategoryMapEdits(edits, courseID: courseID)
    }

    /// Cosmetic rename — never touches weight, membership, or math.
    func renameCategory(courseID: String, categoryID: String, name: String) {
        var edits = categoryMapEdits[courseID] ?? CategoryMapEdits()
        if let index = edits.addedCategories.firstIndex(where: { $0.id == categoryID }) {
            edits.addedCategories[index].name = name
        } else {
            edits.renamedCategories[categoryID] = name
        }
        setCategoryMapEdits(edits, courseID: courseID)
    }

    /// Discards every edit for a course, reverting it to whatever
    /// `suggestedCategoryMap`/Canvas-mirroring would produce on its own —
    /// including any accepted-shared-mapping decision, since that decision
    /// is itself a kind of "how this course's map is built" choice that
    /// "reset categories" promises to undo.
    func resetCategoryMapEdits(courseID: String) {
        categoryMapEdits.removeValue(forKey: courseID)
        persistCategoryMapEdits()
        clearSharedMappingDecision(courseID: courseID)
    }

    private func setCategoryMapEdits(_ edits: CategoryMapEdits, courseID: String) {
        if edits.isEmpty {
            categoryMapEdits.removeValue(forKey: courseID)
        } else {
            categoryMapEdits[courseID] = edits
        }
        persistCategoryMapEdits()
    }

    /// Canvas groups the effective map doesn't claim — a course-report
    /// "needs a home" list, via the same `GradeRegrouper` pass `GradeEngine`
    /// itself runs, so this can never disagree with what the math actually
    /// did with an unmapped group (weight 0, passthrough category).
    func unmappedGroups(courseID: String) -> [GradeCategory] {
        let map = effectiveCategoryMap(courseID: courseID)
        let output = GradeRegrouper.apply(map, to: gradeCategories(courseID: courseID))
        let unmappedIDs = Set(output.unmappedGroupIDs)
        return output.categories.filter { unmappedIDs.contains($0.id) }
    }

    /// Every item the effective map removes from the math, with its reason —
    /// an automatic classification (a placeholder, an attendance item with
    /// nowhere to go) or the student's own manual exclusion.
    func excludedItems(courseID: String) -> [(item: GradeItem, reason: String)] {
        let map = effectiveCategoryMap(courseID: courseID)
        guard !map.excludedItemIDs.isEmpty else { return [] }
        var result: [(item: GradeItem, reason: String)] = []
        for category in gradeCategories(courseID: courseID) {
            for item in category.items where map.excludedItemIDs.contains(item.id) {
                result.append((item, map.exclusionReasons[item.id] ?? "excluded"))
            }
        }
        return result
    }

    private func persistCategoryMapEdits() {
        guard let data = try? JSONEncoder().encode(categoryMapEdits) else { return }
        UserDefaults.lhf.set(data, forKey: Self.categoryMapEditsKey)
    }

    private static func loadCategoryMapEdits() -> [String: CategoryMapEdits] {
        guard let data = UserDefaults.lhf.data(forKey: categoryMapEditsKey),
              let dict = try? JSONDecoder().decode([String: CategoryMapEdits].self, from: data)
        else { return [:] }
        return dict
    }

    // MARK: - Shared category mapping (map-categories)
    //
    // A second, independent suggestion layered ABOVE the local
    // syllabus/Canvas matcher the previous section builds: LHF's backend
    // pools a `map-categories` answer per course (`backend/PROTOCOL.md`),
    // built by a model that can read every Canvas group and item name at
    // once, rather than the small synonym/fuzzy table `SyllabusMatcher` uses
    // on-device — so it can catch a fold the local matcher can't ("Imported
    // Assignments" really being homework, say). It is never applied
    // automatically; see `sharedMappingSuggestion`'s doc comment for the
    // honesty rule this store enforces before ever showing one, and
    // `suggestedCategoryMap`'s doc comment above for exactly what accepting
    // one does and does not do.
    //
    // Two dictionaries, cached separately on purpose:
    //   - `sharedMappings` is what the SERVER said, keyed by course id, one
    //     record at a time — a fresh answer for a new Canvas structure
    //     simply overwrites the old one. This is a cache of a FACT (what did
    //     the server last say), not a decision.
    //   - `sharedMappingDecisions` is what the STUDENT said about that fact
    //     — accepted or declined — recorded against the specific structure
    //     hash they were looking at when they decided, so a later Canvas
    //     structure change (a new assignment group appearing) makes the old
    //     decision stop applying rather than silently keep applying to a
    //     course that no longer looks like what was decided about.
    //
    // Neither dictionary is folded into `categoryMapEdits` — see
    // `suggestedCategoryMap`'s doc comment for why that would be the wrong
    // design (it would read as the student's own edit and lose its
    // provenance).

    /// The server's cached `map-categories` answer for a course, and the
    /// `localStructureHash` (`MapCategoriesRequest.localStructureHash`) it
    /// was requested for — so a later read can tell "this is still the
    /// answer for the Canvas structure I have right now" from "Canvas's
    /// groups changed since I asked, this answer is stale." `mapping: nil`
    /// is a real, rememberable answer (the server has nothing to suggest for
    /// this course yet) — not a "no data" placeholder — precisely so a
    /// brand-new course with no syllabus-derived categories to map onto
    /// doesn't get asked again every single refresh (see
    /// `shouldRequestSharedMapping`).
    struct SharedMappingRecord: Codable, Sendable, Hashable {
        var mapping: SharedCategoryMapping?
        var localStructureHash: String
        var fetchedAt: Date
    }

    /// Persisted so a relaunch doesn't re-ask the server for a course it
    /// already answered this same Canvas structure for.
    @Published private(set) var sharedMappings: [String: SharedMappingRecord] = [:]
    private static let sharedMappingsKey = "gradeWatcherSharedCategoryMappings"

    /// The student's own accept/decline choice about a course's shared
    /// mapping, recorded against the specific `localStructureHash` they were
    /// looking at — see this section's opening doc comment for why the hash
    /// travels with the choice rather than the choice being a standing,
    /// structure-independent preference.
    struct SharedMappingDecision: Codable, Sendable, Hashable {
        enum Choice: String, Codable, Sendable {
            case accepted, declined
        }
        var choice: Choice
        var localStructureHash: String
    }

    @Published private(set) var sharedMappingDecisions: [String: SharedMappingDecision] = [:]
    private static let sharedMappingDecisionsKey = "gradeWatcherSharedMappingDecisions"

    /// The Canvas-structure fingerprint `map-categories` would be asked
    /// about for this course right now, or `nil` when the course hasn't been
    /// fetched at all yet — there is nothing to fingerprint before a
    /// snapshot exists. Unlike `mapCategoriesRequest` below, this doesn't
    /// also require non-empty categories: an empty-but-fetched course still
    /// has a well-defined (if trivial) structure hash, and callers that only
    /// need the hash to compare cached records against
    /// (`shouldRequestSharedMapping`, `sharedMappingSuggestion`) shouldn't
    /// have to reason about why a perfectly good hash came back `nil`.
    func currentStructureHash(courseID: String) -> String? {
        guard snapshots[courseID] != nil else { return nil }
        return MapCategoriesRequest(courseID: courseID, canvasCategories: gradeCategories(courseID: courseID)).localStructureHash
    }

    /// The request `AppState` would actually send the server for this
    /// course, or `nil` when there's nothing worth sending: no snapshot yet,
    /// or a snapshot with zero Canvas categories (a course Canvas itself
    /// hasn't populated with assignment groups yet — asking the server to
    /// map nothing would just spend a call against the daily quota for no
    /// reason).
    func mapCategoriesRequest(courseID: String) -> MapCategoriesRequest? {
        guard snapshots[courseID] != nil else { return nil }
        let categories = gradeCategories(courseID: courseID)
        guard !categories.isEmpty else { return nil }
        return MapCategoriesRequest(courseID: courseID, canvasCategories: categories)
    }

    /// Whether asking the server for this course is worth a call against the
    /// per-user daily quota (`MAP_DAILY_LIMIT`, `backend/PROTOCOL.md`): a
    /// snapshot exists (there's something to describe), a syllabus scheme is
    /// attached (without one there are no categories to map ONTO, and
    /// `suggestedCategoryMap` wouldn't use the answer anyway), the student
    /// hasn't already hand-edited this course's map (an edit is a more
    /// specific, more recent statement of intent than anything the server
    /// could offer), and neither a cached record nor a decision already
    /// exists for the CURRENT Canvas structure — re-asking about a structure
    /// already answered (with a real mapping, an explicit `nil`, or a
    /// decision either way) would just spend quota to hear the same thing
    /// again.
    func shouldRequestSharedMapping(courseID: String) -> Bool {
        guard snapshots[courseID] != nil else { return false }
        guard syllabusSchemes[courseID] != nil else { return false }
        guard !hasCategoryMapEdits(courseID: courseID) else { return false }
        guard let hash = currentStructureHash(courseID: courseID) else { return false }
        if let record = sharedMappings[courseID], record.localStructureHash == hash { return false }
        if let decision = sharedMappingDecisions[courseID], decision.localStructureHash == hash { return false }
        return true
    }

    /// Records the server's answer for this course and structure hash —
    /// called by `AppState` after a successful `map-categories` call.
    /// `mapping: nil` is recorded exactly like a real mapping (see
    /// `SharedMappingRecord`'s doc comment): both are legitimate answers
    /// that stop `shouldRequestSharedMapping` from asking again about this
    /// same structure.
    func setSharedMapping(_ mapping: SharedCategoryMapping?, courseID: String, localStructureHash: String, fetchedAt: Date = Date()) {
        sharedMappings[courseID] = SharedMappingRecord(mapping: mapping, localStructureHash: localStructureHash, fetchedAt: fetchedAt)
        persistSharedMappings()
    }

    /// The shared mapping to OFFER in the report right now, or `nil` when
    /// there's nothing worth showing. Every one of these has to hold:
    ///   - a syllabus scheme is attached (nothing to build the alternative
    ///     from otherwise);
    ///   - the student hasn't hand-edited this course's map (an edit already
    ///     says more than a suggestion could add, and offering one over an
    ///     edit would read as second-guessing a choice already made);
    ///   - a cached record exists for the CURRENT structure hash, with a
    ///     non-nil mapping (a stale-hash or a `nil`-mapping record has
    ///     nothing to offer);
    ///   - the student hasn't already decided about THIS hash (accepted or
    ///     declined — either way, re-showing the same offer over and over is
    ///     the failure mode this guards against);
    ///   - and, the actual honesty rule: the map the server's answer would
    ///     BUILD has to differ from what the local matcher already proposes,
    ///     in at least one category's `canvasGroupIDs` or in
    ///     `itemAssignments`. If the server agrees with the local matcher
    ///     down to the id, showing a suggestion would be a UI lie — there is
    ///     nothing to accept that isn't already true.
    func sharedMappingSuggestion(courseID: String) -> GradeCategoryMap? {
        guard let syllabus = syllabusSchemes[courseID] else { return nil }
        guard !hasCategoryMapEdits(courseID: courseID) else { return nil }
        guard let hash = currentStructureHash(courseID: courseID) else { return nil }
        guard let record = sharedMappings[courseID], record.localStructureHash == hash, let mapping = record.mapping else { return nil }
        if let decision = sharedMappingDecisions[courseID], decision.localStructureHash == hash { return nil }

        let built = GradeCategoryMapBuilder.fromSharedMapping(mapping, scheme: syllabus.scheme, canvasCategories: gradeCategories(courseID: courseID))
        guard let local = suggestedCategoryMap(courseID: courseID) else { return built }

        let builtGroups = Dictionary(uniqueKeysWithValues: built.categories.map { ($0.id, Set($0.canvasGroupIDs)) })
        let localGroups = Dictionary(uniqueKeysWithValues: local.categories.map { ($0.id, Set($0.canvasGroupIDs)) })
        guard builtGroups != localGroups || built.itemAssignments != local.itemAssignments else { return nil }
        return built
    }

    /// The student taps "use it" — records acceptance for the CURRENT
    /// structure hash. See `suggestedCategoryMap`'s doc comment for what
    /// this changes and why it's recorded as a decision rather than copied
    /// into `categoryMapEdits`. A no-op (nothing to accept) when there's no
    /// snapshot to hash against.
    func acceptSharedMapping(courseID: String) {
        guard let hash = currentStructureHash(courseID: courseID) else { return }
        sharedMappingDecisions[courseID] = SharedMappingDecision(choice: .accepted, localStructureHash: hash)
        persistSharedMappingDecisions()
    }

    /// The student taps "not now" — records a decline for the CURRENT
    /// structure hash, so the same offer stops resurfacing every time this
    /// course's report is opened, without discarding the cached record
    /// itself (a later `clearSharedMappingDecision` can still bring the
    /// exact same offer back).
    func declineSharedMapping(courseID: String) {
        guard let hash = currentStructureHash(courseID: courseID) else { return }
        sharedMappingDecisions[courseID] = SharedMappingDecision(choice: .declined, localStructureHash: hash)
        persistSharedMappingDecisions()
    }

    /// Forgets whatever accept/decline decision is on record for this
    /// course, regardless of which structure hash it names — used by
    /// `resetCategoryMapEdits` (a full "start over" for the course's map)
    /// and available on its own for a "reconsider" affordance.
    func clearSharedMappingDecision(courseID: String) {
        sharedMappingDecisions.removeValue(forKey: courseID)
        persistSharedMappingDecisions()
    }

    private func persistSharedMappings() {
        guard let data = try? JSONEncoder().encode(sharedMappings) else { return }
        UserDefaults.lhf.set(data, forKey: Self.sharedMappingsKey)
    }

    private static func loadSharedMappings() -> [String: SharedMappingRecord] {
        guard let data = UserDefaults.lhf.data(forKey: sharedMappingsKey),
              let dict = try? JSONDecoder().decode([String: SharedMappingRecord].self, from: data)
        else { return [:] }
        return dict
    }

    private func persistSharedMappingDecisions() {
        guard let data = try? JSONEncoder().encode(sharedMappingDecisions) else { return }
        UserDefaults.lhf.set(data, forKey: Self.sharedMappingDecisionsKey)
    }

    private static func loadSharedMappingDecisions() -> [String: SharedMappingDecision] {
        guard let data = UserDefaults.lhf.data(forKey: sharedMappingDecisionsKey),
              let dict = try? JSONDecoder().decode([String: SharedMappingDecision].self, from: data)
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
            now: now,
            expectedCounts: effectiveExpectedCounts(courseID: courseID),
            itemOverrides: itemOverrides(courseID: courseID),
            modeOverride: modeOverride(courseID: courseID),
            categoryMap: effectiveCategoryMap(courseID: courseID)
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
