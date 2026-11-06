import Foundation
import LowHangingFruitKit

// MARK: – Canvas's structured sources, applied to the ledger
//
// `CanvasStructuredSourcesClient` fetches planner items, missing submissions
// and, per course, modules, assignments with `all_dates`, discussion topics
// and pages. `CanvasStructuredSourcesReconciler` turns that into plain facts
// (`CanvasStructuredSignals`). This file is the applier, the only place those
// facts touch the app's state, and it is bound by "nothing the student did is
// ever lost":
//
//  - rows are UPSERTED, never reconciled. `AssignmentStore.reconcile`
//    partitions by source, so reconciling this fetch against the whole
//    `.canvasModules` partition would retire every module reading the fetch
//    did not mention (the same trap `importModuleReadings` documents).
//  - completions are an ADDITIVE set consulted by `isCompleted`, not a write
//    of `userCompleted`. A card Canvas says is done shows as done; the
//    student's own tick, and their un-tick, stay theirs: marking such a card
//    active records an override beside the set (`structuredCompletionOverrides`),
//    and a Canvas un-tick, seen by a run that read everything, retires both.
//    Nothing here ever writes a completion for the student or removes one of theirs. The tempting version, `setCompleted`, would stamp the
//    student's own completion on Canvas's say-so, and could not be told apart
//    from the student's tap on the next sync or when sync-ing devices.
//    `applySubmissionState` was the other candidate and is the wrong tool: it
//    is a full replace by design (so a retracted submission self-heals), so the
//    grade refresh that follows would clear what this wrote, and a row with no
//    assignment id (a quiz module item, a planner note) has nothing for it to
//    join on.
//  - dismissals HIDE (`structuredDismissedItemIDs`, filtered in the dashboard
//    pool). The ledger row stays. Unlike completions they are reversible from
//    Canvas: a run whose planner endpoint finished in full REPLACES the set
//    with its own dismissals, so un-dismissing in Canvas brings the card back.
//    A run whose planner did not finish (rate limit, failure, cut-off) only
//    adds, so it can never drop a dismissal it simply failed to see.
//  - section due dates are kept in a map beside the pool and substituted into
//    the pool's copy of the row (`applyingStructuredDueOverride`), never
//    written onto the ledger row, for the same reason the student's edits are
//    kept beside the pool: the feed overwrites `dueAt` on every sync. Why not a
//    new source in the due-date-edit store: `dueDateEdits` is `[id: Date]` with
//    no provenance, it is synced between devices and pruned by id family, so a
//    Canvas-written entry in it would be indistinguishable from the student's
//    own and ship to their other devices as if they had chosen it. With the
//    override applied to the row's `dueAt`, the student's edit wins by
//    construction (`effectiveDueDate` reads the edit first), and a later
//    override can never replace one because it never touches the edit map.
//  - `missing` stores nothing; the dashboard already shows overdue.
//
// The whole step is behind `FeatureFlags.structuredCanvasSources`, and nothing
// in it can abort the refresh that called it.

extension AppState {
    /// Defaults keys. `UserDefaults.lhf`, per the preferences rule.
    enum StructuredKey {
        static let completed = "structuredCompletedItemIDsV1"
        static let completionOverrides = "structuredCompletionOverridesV1"
        static let dismissed = "structuredDismissedItemIDsV1"
        static let dueOverrides = "structuredDueOverridesV1"
        static let summary = "lastStructuredSourcesSyncSummaryV1"
    }

    /// Counts only; never a title, id or URL.
    struct StructuredApplySummary: Equatable {
        var rows = 0
        var completions = 0
        var dismissals = 0
        var dueOverrides = 0
        var missing = 0
        var skipped: String?

        var text: String {
            if let skipped { return "skipped: \(skipped)" }
            return "rows=\(rows) completions=\(completions) dismissals=\(dismissals) dueOverrides=\(dueOverrides) missing=\(missing)"
        }
    }

    // MARK: Persistence

    func loadStructuredState() {
        guard FeatureFlags.structuredCanvasSources, let defaults = structuredDefaults else { return }
        structuredCompletedItemIDs = Set(defaults.stringArray(forKey: StructuredKey.completed) ?? [])
        structuredCompletionOverrides = Set(defaults.stringArray(forKey: StructuredKey.completionOverrides) ?? [])
        structuredDismissedItemIDs = Set(defaults.stringArray(forKey: StructuredKey.dismissed) ?? [])
        structuredDueOverrides = defaults.dictionary(forKey: StructuredKey.dueOverrides) as? [String: Date] ?? [:]
    }

    private func saveStructuredState() {
        guard let defaults = structuredDefaults else { return }
        defaults.set(structuredCompletedItemIDs.sorted(), forKey: StructuredKey.completed)
        defaults.set(structuredCompletionOverrides.sorted(), forKey: StructuredKey.completionOverrides)
        defaults.set(structuredDismissedItemIDs.sorted(), forKey: StructuredKey.dismissed)
        defaults.set(structuredDueOverrides, forKey: StructuredKey.dueOverrides)
    }

    /// On Canvas disconnect.
    func clearStructuredState() {
        structuredCompletedItemIDs = []
        structuredCompletionOverrides = []
        structuredDismissedItemIDs = []
        structuredDueOverrides = [:]
        guard let defaults = structuredDefaults else { return }
        for key in [StructuredKey.completed, StructuredKey.completionOverrides, StructuredKey.dismissed, StructuredKey.dueOverrides, StructuredKey.summary] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Undoing a Canvas-derived completion

    /// The student marked `assignment` active again. If a structured
    /// completion is what still shows it done, remember the un-tick beside the
    /// set (`structuredCompletionOverrides`) so `isCompleted` stops honouring
    /// it. The set itself keeps its ids: it is rebuilt from Canvas on every
    /// run, so deleting from it would be undone by the same planner tick on
    /// the next refresh, which was the bug. If the card is still done for any
    /// other reason (Canvas says it was submitted), the override is not
    /// recorded: it would silently outlive that submission and hide a later
    /// genuine Canvas completion. Called after the ledger un-tick is applied.
    func overrideStructuredCompletionIfItWasTheOnlyReason(_ assignment: Assignment, ids: Set<String>) {
        let added = ids.intersection(structuredCompletedItemIDs).subtracting(structuredCompletionOverrides)
        guard !added.isEmpty else { return }
        structuredCompletionOverrides.formUnion(added)
        if isCompleted(assignment) { structuredCompletionOverrides.subtract(added) }
        saveStructuredState()
    }

    /// The student completed these themselves: their own tick is the truth
    /// now, and an old un-tick must not linger and mask a later Canvas tick.
    func releaseStructuredCompletionOverride(ids: Set<String>) {
        guard !structuredCompletionOverrides.isDisjoint(with: ids) else { return }
        structuredCompletionOverrides.subtract(ids)
        saveStructuredState()
    }

    // MARK: Dashboard read

    /// The pool's copy of a Canvas row with its section date, when Canvas
    /// stated one. Identity (`id`) is unchanged.
    func applyingStructuredDueOverride(_ item: Assignment) -> Assignment {
        guard let due = structuredDueOverrides[item.id], due != item.dueAt else { return item }
        return Assignment(
            source: item.source, sourceID: item.sourceID, kind: item.kind, course: item.course,
            title: item.title, dueAt: due, url: item.url, term: item.term, submitted: item.submitted,
            scoreEarned: item.scoreEarned, scoreMax: item.scoreMax, linkedID: item.linkedID
        )
    }

    // MARK: Fetch

    /// The refresh step. Never throws; a failure is logged and the rest of the
    /// refresh carries on.
    func syncStructuredCanvasSources(cookies: [HTTPCookie], now: Date = Date()) async {
        guard FeatureFlags.structuredCanvasSources, !isUsingFixtureData else { return }
        let courses = structuredSourcesCoursesForTesting
            ?? canvasCourseSummaries().filter { isCourseSelected($0.code) }
        guard !courses.isEmpty else { return }

        let run: CanvasStructuredSourcesClient.RunResult
        if let canned = structuredSourcesRunForTesting {
            run = canned
        } else {
            let client = CanvasStructuredSourcesClient(
                baseURL: canvasBaseURL,
                cookies: cookies,
                accessToken: canvasAccessTokenBearer
            )
            run = await client.fetch(
                courseIDs: courses.map(\.courseID),
                plannerStart: now.addingTimeInterval(-14 * 24 * 60 * 60),
                plannerEnd: now.addingTimeInterval(120 * 24 * 60 * 60)
            )
        }
        applyStructuredSources(run: run, courses: courses, now: now)
    }

    // MARK: Apply

    /// Order: rows first (so what follows can resolve against them), then
    /// completions, dismissals, section dates, then persist and summarise.
    /// The caller rebuilds the dashboard.
    @discardableResult
    func applyStructuredSources(
        run: CanvasStructuredSourcesClient.RunResult,
        courses: [CourseSummary],
        now: Date = Date()
    ) -> StructuredApplySummary {
        var summary = StructuredApplySummary()
        guard FeatureFlags.structuredCanvasSources, !isUsingFixtureData else {
            summary.skipped = "off"
            return summary
        }
        // A lapsed session means the rest of the run was skipped, and what
        // came before it is not trusted either: apply nothing.
        guard !run.sessionExpired else {
            summary.skipped = "session expired"
            recordStructuredSummary(summary)
            return summary
        }

        let signals = CanvasStructuredSourcesReconciler.signals(from: run, courses: courses, baseURL: canvasBaseURL)
        summary.missing = signals.missing.count

        // 1. Rows. Upsert, never reconcile.
        let rows = signals.rows.map(\.assignment)
        if !rows.isEmpty {
            if let store = assignmentStore {
                store.upsert(rows)
                replaceModuleReadingItems(store.assignments(source: .canvasModules))
            } else {
                var byID = Dictionary(uniqueKeysWithValues: moduleReadingItems.map { ($0.id, $0) })
                for row in rows { byID[row.id] = row }
                replaceModuleReadingItems(Array(byID.values).sorted { $0.id < $1.id })
            }
            summary.rows = rows.count
        }

        // Everything below resolves a Canvas id to ledger ids against what the
        // ledger holds now, feed rows and module rows alike.
        let ledger: [Assignment] = assignmentStore.map {
            $0.assignments(source: .canvas) + $0.assignments(source: .canvasModules)
        } ?? (canvasItems + moduleReadingItems)
        func ids(_ ref: CanvasStructuredSignals.Ref) -> [String] {
            if let assignmentID = ref.assignmentID {
                return ledger.filter { $0.canvasAssignmentID == assignmentID }.map(\.id)
            }
            if let sourceID = ref.sourceID {
                return ledger.filter { $0.sourceID == sourceID }.map(\.id)
            }
            return []
        }

        var keyByCourseID: [String: String] = [:]
        for course in courses { keyByCourseID[course.courseID] = course.code }

        // 2. Completions. Additive within a run, but Canvas's own un-tick is
        // honoured: an id the set holds that this run no longer reports done
        // is dropped (with any student override on it), so the set tracks
        // Canvas instead of only growing.
        //
        // Only where this run can be trusted to have seen it. Completions come
        // from the planner, the missing list and each course's modules, so an
        // id is retired only when all three finished in full (a partial run
        // is silent about what it did not read, and silence must never drop a
        // completion), the id resolves to a ledger row of a course whose
        // modules were read, and that row's due date lies inside the planner
        // window (an older or undated row is simply not in the planner's
        // answer, which is not a retraction).
        let completed = Set(signals.completions.flatMap { ids($0.ref) })
        summary.completions = completed.count
        if run.plannerCompleted, run.missingCompleted {
            let modulesRead = Set(run.courses.filter { $0.completedEndpoints.contains(.modules) }
                .compactMap { keyByCourseID[$0.courseID] })
            let windowStart = now.addingTimeInterval(-14 * 24 * 60 * 60)
            let windowEnd = now.addingTimeInterval(120 * 24 * 60 * 60)
            var rowByID: [String: Assignment] = [:]
            for row in ledger { rowByID[row.id] = row }
            let retracted = structuredCompletedItemIDs.subtracting(completed).filter { id in
                guard let row = rowByID[id], modulesRead.contains(row.course),
                      let due = row.dueAt, due >= windowStart, due <= windowEnd else { return false }
                return true
            }
            structuredCompletedItemIDs.subtract(retracted)
            structuredCompletionOverrides.subtract(retracted)
        }
        structuredCompletedItemIDs.formUnion(completed)

        // 3. Dismissals: replaced by a complete planner read, otherwise additive.
        let dismissed = Set(signals.dismissals.flatMap { ids($0.ref) })
        summary.dismissals = dismissed.count
        if run.plannerCompleted {
            structuredDismissedItemIDs = dismissed
        } else {
            structuredDismissedItemIDs.formUnion(dismissed)
        }

        // 4. Section dates. A course whose assignments endpoint finished in
        // full is authoritative for its own rows, so an override Canvas has
        // since removed is dropped; a partial course only adds.
        let fullyRead = Set(run.courses.filter { $0.completedEndpoints.contains(.assignments) }
            .compactMap { keyByCourseID[$0.courseID] })
        if !fullyRead.isEmpty {
            let stale = Set(ledger.filter { fullyRead.contains($0.course) }.map(\.id))
            structuredDueOverrides = structuredDueOverrides.filter { !stale.contains($0.key) }
        }
        for correction in signals.dueDateCorrections {
            for id in ids(.assignment(correction.assignmentID)) {
                structuredDueOverrides[id] = correction.dueAt
            }
        }
        summary.dueOverrides = structuredDueOverrides.count

        saveStructuredState()
        recordStructuredSummary(summary)
        return summary
    }

    private func recordStructuredSummary(_ summary: StructuredApplySummary) {
        structuredDefaults?.set(summary.text, forKey: StructuredKey.summary)
        recordModuleImport("structured: \(summary.text)")
    }
}
