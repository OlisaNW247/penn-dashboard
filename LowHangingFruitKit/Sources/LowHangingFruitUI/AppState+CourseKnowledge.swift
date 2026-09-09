import Foundation
import LowHangingFruitKit

// MARK: – Course materials for ask
//
// The knowledge base is what lets ask answer a policy question. Before it,
// the only course text on disk was the grading table `SyllabusParser`
// keeps; syllabus prose and announcement bodies were fetched, mined, and
// dropped (see the header of `AssistantContextAssembly.swift`). The
// collector below keeps them, on-device, keyed by Canvas course id.
//
// Which courses: every Canvas site whose code the app knows, not one per
// code — see `canvasCourseSummaries()`. `canvasCourseIDsByCode`, the
// persisted `[code: id]` cache, can only remember one id per code, and Penn
// runs some courses (PHYS 0151's lecture and lab) as two Canvas sites that
// both parse to the same code; building this sync's course list from that
// cache silently dropped whichever site lost the cache, so half a course's
// material was never fetched. Which cookies: the ones
// `AutoSyncCoordinator.canvasCookies()` already gathers for grades — this
// sync piggybacks on that refresh rather than opening its own session axis,
// the way readings detection does.
//
// ## The shared store (`backend/PROTOCOL.md`)
//
// With `BackendServices.client` configured, this sync is no longer a
// device-local fetch: it is a manifest exchange with LHF's server first,
// then Canvas only for whatever the manifest says this phone doesn't
// already have fresh. Two things move off the phone and one thing never
// does:
//
//  - **Uploaded**: course-level material only — syllabus prose, page and
//    module text, assignment descriptions, announcement bodies —
//    identified by the Canvas *course* id, the same key every enrolled
//    student's phone uploads under. `CourseDocumentWire` has no field for
//    `submitted`, so there is no way to accidentally serialize a student's
//    own submission state onto the wire even by mistake.
//  - **Never uploaded**: grades, completions, the work list, the student's
//    name, submission state — the manifest and upload request shapes have
//    no field for any of them, and this file never builds one. That is also
//    why `deleteBackendData()` below can erase this student's server-side
//    row (their `enrollments`, their `ask_usage`) without touching a single
//    other student's synced material: that material was never this
//    student's data in the first place (`PROTOCOL.md`'s `delete-account`).
//  - **The phone still does every Canvas fetch.** The server never sees a
//    Canvas cookie and never talks to Canvas — it only receives documents
//    this phone already extracted with the student's own session. That is
//    the whole reason `CourseKnowledgeCollector` still runs here rather
//    than moving server-side: a shared backend that held Canvas
//    credentials for every student would be a far larger thing to trust
//    than one that only ever receives already-public course-site text.
//
// Offline, over quota, or with the backend unreachable, this file falls
// back to fetching everything straight from Canvas and skipping the
// upload — exactly what it always did before `BackendServices` existed —
// rather than failing the sync outright.

/// One `refreshCourseKnowledge()` run's outcome — the trace surfaced in
/// Settings → Diagnostics (`AppState.courseKnowledgeSyncDiagnosticLines`) so
/// a sync that stops silently partway is diagnosable without instrumenting a
/// device by hand. Before this existed, the only trace of a stuck sync was
/// `courseKnowledgeNotice`'s one line, which can't tell "the manifest never
/// came back," "the collector fetched but every endpoint failed," and "the
/// upload that shares this phone's fetch with the server never went out"
/// apart — all three read identically from the outside as "a Canvas site
/// enrolled server-side with `last_full_sync_at` still null a day later."
///
/// In-memory only, gone on relaunch: this is a debugging aid for *this
/// launch's* most recent run, not a persisted audit log, so it carries none
/// of the guarantees the ledger or Keychain tiers need — nothing in it is
/// data the student would mind losing, because none of it is the student's
/// data in the first place (course ids, counts, and error strings that
/// already meet `submissionDiagnosticLines`'s privacy budget).
struct CourseKnowledgeSyncTrace: Sendable {
    var startedAt: Date
    var forced: Bool
    /// Every Canvas site id this run considered (`canvasCourseSummaries()`),
    /// sorted. Empty for a run that never got past a guard.
    var courseIDs: [String]
    var manifestSucceeded: Bool
    /// `SyncManifestResponse.coursesFresh`, sorted — the courses the server
    /// says this phone already has current material for.
    var coursesFresh: [String]
    /// `SyncPlanner.SyncPlan.coursesToFetch`'s ids, sorted — what this run
    /// actually asked the collector to re-fetch from Canvas. With no backend
    /// configured this is every course, since there is no manifest-derived
    /// plan to shrink it from "everything."
    var coursesToFetch: [String]
    /// `CourseKnowledgeCollector.Report.fullyFetchedCourseIDs`, sorted.
    var fullyFetched: [String]
    /// `CourseKnowledgeCollector.Report.errors` verbatim — already just
    /// "<code> <endpoint>: <description>" (or "announcements: <description>"),
    /// never a URL or a title.
    var collectorErrors: [String]
    var uploadBatches: Int
    var uploadedDocuments: Int
    var uploadError: String?
    /// Set when a guard turned this run away before it reached the
    /// collector — "already syncing", "not stale", "no cookies" — so a sync
    /// that looks stuck can be told apart from one that ran and failed.
    var skippedReason: String?
    var finishedAt: Date?
}

extension AppState {
    /// Re-sync course materials at most this often on the launch/activation
    /// path. Was 6 hours when every sync meant fetching every course from
    /// Canvas; now that a no-change sync is just one manifest round trip
    /// (`SyncManifestResponse.coursesFresh` short-circuits the Canvas fetch
    /// entirely), there's no reason to hold announcements — which change
    /// daily and are the main thing ask needs to stay current — back for six
    /// hours' worth of staleness.
    static let courseKnowledgeStaleAfter: TimeInterval = 60 * 60

    /// Bump this whenever the sync logic changes what it would fetch or how it
    /// keys it. The staleness window alone let a build that taught the sync
    /// to fetch every Canvas site of a course sit idle for an hour after
    /// install, because the previous build had synced recently and the
    /// knowledge base looked fresh — nothing on disk knew the *rules* had
    /// changed. A stored version older than this one counts as stale.
    ///   2: courses come from every Canvas site of a code (2026-09-08).
    ///   3: forces one full run on every device so the new
    ///   `CourseKnowledgeSyncTrace` (`lastCourseKnowledgeSyncTrace`) gets
    ///   populated at least once, rather than sitting empty until the next
    ///   hourly staleness window or a manual force-refresh — this was the
    ///   only way to get first-run diagnostic visibility into a course
    ///   already sitting server-side with `last_full_sync_at` null
    ///   (2026-09-09).
    static let courseKnowledgeSyncVersion = 3
    private static let courseKnowledgeSyncVersionKey = "courseKnowledgeSyncVersionV1"

    var courseKnowledgeIsStale: Bool {
        if UserDefaults.lhf.integer(forKey: Self.courseKnowledgeSyncVersionKey) < Self.courseKnowledgeSyncVersion {
            return true
        }
        guard let last = courseKnowledge.lastSyncedAt else { return true }
        return Date().timeIntervalSince(last) > Self.courseKnowledgeStaleAfter
    }

    /// Recorded only after a run that reached the collector, so a launch that
    /// bails early (no cookies, backend down before the fetch) keeps the
    /// forced resync pending.
    private func markCourseKnowledgeSyncVersion() {
        UserDefaults.lhf.set(Self.courseKnowledgeSyncVersion, forKey: Self.courseKnowledgeSyncVersionKey)
    }

    /// The knowledge `ask` reasons over. Preview mode (the App Store
    /// reviewer's path and `-LHFDemoData`) gets the bundled sample syllabi so
    /// the screen can be exercised with no Canvas account, exactly as the
    /// dashboard and Grade Watcher do with `SampleData`.
    var assistantKnowledge: CourseKnowledgeBase {
        isUsingFixtureData ? SampleData.knowledge() : courseKnowledge
    }

    /// Every dashboard item, active or done, with the app's completion state
    /// applied — what the on-device answerer computes "what's due" from.
    /// Mirrors the pools `assistantContextDocument()` sends to the backend so
    /// the two paths agree on what exists.
    func assistantWorkItems() -> [WorkItem] {
        let pool = canvasItems + gradescopeItems + moduleReadingItems + announcementItems
            + recurringTasks.flatMap { $0.upcomingAssignments() }
            + manualAssignments.map { $0.asAssignment() }
        var seen: Set<String> = []
        return pool.compactMap { assignment in
            guard seen.insert(assignment.id).inserted else { return nil }
            return WorkItem(assignment: assignment, isCompleted: isCompleted(assignment))
        }
    }

    /// Pulls course materials and stores them on-device, sharing what it
    /// learns with LHF's server (course-level material only — see the file
    /// header) when a backend is configured. Never throws; problems land in
    /// `courseKnowledgeNotice` for Settings to show, and local knowledge is
    /// never discarded because a network step upstream of it failed.
    ///
    /// Every run that gets past the three early guards — including one that
    /// then fails outright — leaves a `CourseKnowledgeSyncTrace` behind in
    /// `lastCourseKnowledgeSyncTrace`, and a run a guard turns away leaves a
    /// trace too (via `recordCourseKnowledgeSkip`), just an emptier one. See
    /// that type's doc comment for why: `courseKnowledgeNotice` alone can't
    /// tell apart "the guard never let this run start," "the manifest never
    /// came back," and "the collector ran but every endpoint failed."
    func refreshCourseKnowledge(cookies: [HTTPCookie], force: Bool = false) async {
        // Preview/demo mode isn't a real sync attempt — `assistantKnowledge`
        // reads `SampleData.knowledge()` in that mode regardless, so there is
        // nothing here worth tracing and no reason to overwrite whatever
        // trace a real device already has.
        guard !isUsingFixtureData else { return }
        guard !isCourseKnowledgeSyncing else {
            recordCourseKnowledgeSkip(forced: force, reason: "already syncing")
            return
        }
        guard force || courseKnowledgeIsStale else {
            recordCourseKnowledgeSkip(forced: force, reason: "not stale")
            return
        }
        guard !cookies.isEmpty else {
            courseKnowledgeNotice = "reconnect canvas to sync course materials."
            recordCourseKnowledgeSkip(forced: force, reason: "no cookies")
            return
        }

        let courses = canvasCourseSummaries()

        var trace = CourseKnowledgeSyncTrace(
            startedAt: Date(),
            forced: force,
            courseIDs: courses.map(\.courseID).sorted(),
            manifestSucceeded: false,
            coursesFresh: [],
            coursesToFetch: [],
            fullyFetched: [],
            collectorErrors: [],
            uploadBatches: 0,
            uploadedDocuments: 0,
            uploadError: nil,
            skippedReason: nil,
            finishedAt: nil
        )

        isCourseKnowledgeSyncing = true
        // `trace` is a local `var`, mutated throughout the run below; `defer`
        // captures it by reference, so whatever it holds at each `return`
        // (including the early one in the no-backend branch) is what gets
        // published here, timestamped as of the moment this run actually
        // stopped.
        defer {
            isCourseKnowledgeSyncing = false
            trace.finishedAt = Date()
            lastCourseKnowledgeSyncTrace = trace
        }

        let store = CourseKnowledgeStore.default()
        let collector = CourseKnowledgeCollector(cookies: cookies, store: store)

        guard let client = BackendServices.client else {
            // No backend configured: this phone is fully on-device, exactly
            // as it always was. Fetch every course fully from Canvas.
            // `trace.manifestSucceeded` stays `false` — there was never a
            // manifest to succeed or fail — and `coursesToFetch` is every
            // course, since there's no manifest-derived plan to shrink it.
            trace.coursesToFetch = trace.courseIDs
            do {
                let report = try await collector.run(courses: courses, fetchFully: nil)
                courseKnowledge = report.knowledge
                markCourseKnowledgeSyncVersion()
                trace.fullyFetched = report.fullyFetchedCourseIDs.sorted()
                trace.collectorErrors = report.errors
                if report.syncedCourses == 0 {
                    courseKnowledgeNotice = "couldn't read course materials from canvas. \(report.errors.first ?? "")"
                } else if !report.errors.isEmpty {
                    courseKnowledgeNotice = "synced \(report.syncedCourses) courses; some pages were skipped."
                } else {
                    courseKnowledgeNotice = nil
                }
            } catch {
                courseKnowledgeNotice = error.localizedDescription
                trace.collectorErrors = [error.localizedDescription]
            }
            return
        }

        // Step 1: manifest exchange. On failure this is treated exactly like
        // an empty response — fetch every course fully from Canvas, upload
        // nothing this run — so a server hiccup degrades to the same
        // behavior as no backend at all rather than blocking the sync.
        var manifest = SyncManifestResponse()
        var manifestSucceeded = false
        do {
            manifest = try await client.syncManifest(SyncManifestRequest(
                courses: courses.map { CourseSummaryWire(summary: $0) },
                documents: courseKnowledge.documents.map(DocumentStub.init(document:))
            ))
            manifestSucceeded = true
        } catch {
            courseKnowledgeNotice = "couldn't reach lhf's server; syncing from canvas only."
        }
        trace.manifestSucceeded = manifestSucceeded
        trace.coursesFresh = manifest.coursesFresh.sorted()

        let plan = SyncPlanner.plan(courses: courses, manifest: manifest)
        trace.coursesToFetch = plan.coursesToFetch.map(\.courseID).sorted()

        var withDownloads = courseKnowledge
        SyncPlanner.applyDownloads(manifest.download, to: &withDownloads, courses: courses, now: Date())
        // The course catalog (`ClassMeeting`s per course, from the server's
        // own registrar-derived data) rides the same manifest response as
        // the document downloads above — folded in here, before the save
        // below, so it survives on-device the same way and is available to
        // `syncAnnouncements()`'s `CourseKnowledgeBase.catalogEntry(
        // forCourseCode:)` lookup on the very next announcement sync.
        SyncPlanner.applyCatalog(manifest.catalog, to: &withDownloads)
        // Saved before the collector runs so its own `store.load()` merge
        // starts from what the manifest just handed down, not from what was
        // on disk before this sync began.
        try? store.save(withDownloads)
        courseKnowledge = withDownloads

        do {
            let report = try await collector.run(courses: courses, fetchFully: Set(plan.coursesToFetch.map(\.courseID)))
            courseKnowledge = report.knowledge
            markCourseKnowledgeSyncVersion()
            trace.fullyFetched = report.fullyFetchedCourseIDs.sorted()
            trace.collectorErrors = report.errors
            if !report.errors.isEmpty {
                courseKnowledgeNotice = "synced \(report.fullyFetchedCourseIDs.count) courses; some pages were skipped."
            } else if manifestSucceeded {
                courseKnowledgeNotice = nil
            }

            // Step 2: upload only runs when the manifest exchange actually
            // happened — uploading against a manifest we never received
            // would risk re-sending documents the server already has, or
            // worse, the `fullySyncedCourses` bookkeeping telling the server
            // to mark documents gone that it simply hasn't reported yet.
            if manifestSucceeded {
                let uploadRequest = SyncPlanner.uploads(
                    local: courseKnowledge,
                    serverManifest: manifest.serverManifest,
                    fullyFetched: report.fullyFetchedCourseIDs,
                    links: report.links
                )
                do {
                    var profileStale: [String] = []
                    var websitesPending: [String] = []
                    for batch in SyncPlanner.uploadBatches(uploadRequest, maxDocuments: 200) {
                        let response = try await client.syncUpload(batch)
                        // Counted only once the round trip for this batch
                        // actually completed — a batch that never gets this
                        // far (the loop threw on an earlier one) is not
                        // "sent" by any reasonable reading of the word.
                        trace.uploadBatches += 1
                        trace.uploadedDocuments += batch.documents.count
                        profileStale.append(contentsOf: response.profileStale)
                        websitesPending.append(contentsOf: response.websitesPending)
                    }
                    if !profileStale.isEmpty {
                        // Fire-and-forget: `extract-profile` only refreshes
                        // the policy-question cache on the server, nothing
                        // ask needs synchronously, so there's no reason to
                        // make this sync (or onboarding, on the caller that
                        // kicks this off from `connectCanvas`) wait on it.
                        Task { try? await client.extractProfile(courseIDs: profileStale) }
                    }
                    if !websitesPending.isEmpty {
                        // Fire-and-forget for the same reason as
                        // `extractProfile` above, only more so: a crawl of
                        // an external course website can take tens of
                        // seconds, and nothing about this sync — or the
                        // student looking at the app right after it — can
                        // use a discovered site until a later sync downloads
                        // whatever the crawl produced anyway.
                        Task { try? await client.discoverWebsites(courseIDs: websitesPending) }
                    }
                } catch {
                    courseKnowledgeNotice = "synced from canvas; couldn't share updates with lhf's server."
                    trace.uploadError = error.localizedDescription
                }
            }
        } catch {
            courseKnowledgeNotice = error.localizedDescription
            trace.collectorErrors.append(error.localizedDescription)
        }
    }

    /// Records a run that never reached the collector — a guard turned it
    /// away before there was anything else to trace. Kept separate from the
    /// happy-path trace construction in `refreshCourseKnowledge` so a launch
    /// that bails on "not stale" doesn't have to fake up values (an empty
    /// `courseIDs`, a `manifestSucceeded` that was never attempted, …) for
    /// fields that plain don't apply to a run that stopped this early.
    private func recordCourseKnowledgeSkip(forced: Bool, reason: String) {
        let now = Date()
        lastCourseKnowledgeSyncSkip = CourseKnowledgeSyncTrace(
            startedAt: now,
            forced: forced,
            courseIDs: [],
            manifestSucceeded: false,
            coursesFresh: [],
            coursesToFetch: [],
            fullyFetched: [],
            collectorErrors: [],
            uploadBatches: 0,
            uploadedDocuments: 0,
            uploadError: nil,
            skippedReason: reason,
            finishedAt: now
        )
    }

    func clearCourseKnowledge() {
        CourseKnowledgeStore.default().clear()
        courseKnowledge = .empty
        courseKnowledgeNotice = nil
    }

    /// Settings → "delete my class data from lhf's server". Erases this
    /// student's row there — their `enrollments` and `ask_usage` history —
    /// and, since ask's local cache is meaningless without a synced-with
    /// account behind it, the on-device knowledge too. Course material
    /// itself is left alone server-side: it was never this student's data
    /// (`PROTOCOL.md`'s `delete-account` — every other student enrolled in
    /// the same course still needs it). Returns whether the server call
    /// succeeded; on failure the local cache is left as-is and a notice
    /// explains why, rather than silently wiping ask's memory for a request
    /// that didn't actually reach the server.
    func deleteBackendData() async -> Bool {
        guard let client = BackendServices.client else { return true }
        do {
            try await client.deleteAccount()
            clearCourseKnowledge()
            return true
        } catch {
            courseKnowledgeNotice = "couldn't delete your data from lhf's server: \(error.localizedDescription)"
            return false
        }
    }

    /// Settings → Diagnostics' course-materials section — see
    /// `DiagnosticsReport`. Feeds this launch's live state into the pure
    /// line-builder below; kept as a thin, one-line-per-field instance
    /// wrapper specifically so nothing except this property (and the static
    /// function it calls) needs to know what `courseKnowledgeSyncVersionKey`
    /// is spelled, or how to reach `canvasCourseSummaries()`.
    var courseKnowledgeSyncDiagnosticLines: [String] {
        var lines = Self.courseKnowledgeDiagnosticLines(
            trace: lastCourseKnowledgeSyncTrace,
            knowledge: courseKnowledge,
            summaries: canvasCourseSummaries(),
            storedVersion: UserDefaults.lhf.integer(forKey: Self.courseKnowledgeSyncVersionKey),
            currentVersion: Self.courseKnowledgeSyncVersion
        )
        if let skip = lastCourseKnowledgeSyncSkip {
            let iso = ISO8601DateFormatter()
            iso.timeZone = TimeZone(identifier: "UTC")
            lines.append("last skip: at=\(iso.string(from: skip.startedAt)) reason=\(skip.skippedReason ?? "-") forced=\(skip.forced)")
        }
        return lines
    }

    /// Pure line-rendering behind `courseKnowledgeSyncDiagnosticLines` above
    /// — a `static` function, not a method, specifically so `swift test` can
    /// exercise it with a fixture `CourseKnowledgeSyncTrace` and a fixture
    /// `CourseKnowledgeBase` without constructing a full `AppState` (which
    /// needs a Canvas session, a knowledge store, and the rest of the launch
    /// path just to exist). This is the seam `CourseKnowledgeDiagnosticsTests`
    /// actually calls.
    ///
    /// Same privacy budget as `submissionDiagnosticLines`: Canvas course
    /// ids, course codes, section tokens (`CourseSummary.section`),
    /// document-`Kind` raw values, and counts only. `collectorErrors` and
    /// `uploadError` are printed verbatim because they already meet that bar
    /// at the source — `CourseKnowledgeCollector.Report.errors` is built as
    /// "<code> <endpoint>: <description>", never a URL or a title (see that
    /// type's doc comment), and `uploadError`/`courseKnowledgeNotice`
    /// elsewhere in this file already surface a raw `error.localizedDescription`
    /// the same way.
    static func courseKnowledgeDiagnosticLines(
        trace: CourseKnowledgeSyncTrace?,
        knowledge: CourseKnowledgeBase,
        summaries: [CourseSummary],
        storedVersion: Int,
        currentVersion: Int
    ) -> [String] {
        let iso = ISO8601DateFormatter()
        // Pinned explicitly rather than relying on the documented UTC
        // default — this report gets pasted into support messages from
        // devices in whatever time zone the student is in, and an explicit
        // zone here means a timestamp in it always means the same instant
        // regardless of where it's read.
        iso.timeZone = TimeZone(identifier: "UTC")

        var lines: [String] = []
        lines.append("stored sync version=\(storedVersion) current=\(currentVersion)")

        let lastSyncedText = knowledge.lastSyncedAt.map { iso.string(from: $0) } ?? "never"
        lines.append("local knowledge: lastSyncedAt=\(lastSyncedText) documents=\(knowledge.documents.count) catalog=\(knowledge.catalog.count)")

        for summary in summaries.sorted(by: { $0.courseID.localizedStandardCompare($1.courseID) == .orderedAscending }) {
            let sectionText = summary.section.map { "section \($0)" } ?? "no section"
            var kindCounts: [String: Int] = [:]
            for doc in knowledge.documents where doc.courseID == summary.courseID {
                kindCounts[doc.kind.rawValue, default: 0] += 1
            }
            let docCount = kindCounts.values.reduce(0, +)
            let kindsText = kindCounts.keys.sorted()
                .map { "\($0)=\(kindCounts[$0]!)" }
                .joined(separator: " ")
            lines.append("site \(summary.courseID) \(summary.code) \(sectionText): docs=\(docCount) kinds \(kindsText)")
        }

        guard let trace else {
            lines.append("last run: none this launch")
            return lines
        }

        lines.append("last run:")
        lines.append("  started=\(iso.string(from: trace.startedAt)) forced=\(trace.forced) skipped=\(trace.skippedReason ?? "-")")
        lines.append("  manifest=\(trace.manifestSucceeded ? "ok" : "failed") fresh=\(Self.bracketedList(trace.coursesFresh)) toFetch=\(Self.bracketedList(trace.coursesToFetch)) fullyFetched=\(Self.bracketedList(trace.fullyFetched))")
        lines.append("  collector errors=\(trace.collectorErrors.count)")
        for error in trace.collectorErrors.prefix(12) {
            lines.append("    \(error)")
        }
        lines.append("  upload batches=\(trace.uploadBatches) documents=\(trace.uploadedDocuments) error=\(trace.uploadError ?? "-")")
        lines.append("  finished=\(trace.finishedAt.map { iso.string(from: $0) } ?? "-")")
        return lines
    }

    private static func bracketedList(_ values: [String]) -> String {
        "[\(values.joined(separator: ","))]"
    }
}
