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
// Which courses: `canvasCourseIDsByCode`, the same code → id map Grade
// Watcher is keyed by, so a course becomes askable exactly when it becomes
// watchable. Which cookies: the ones `AutoSyncCoordinator.canvasCookies()`
// already gathers for grades — this sync piggybacks on that refresh rather
// than opening its own session axis, the way readings detection does.
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

extension AppState {
    /// Re-sync course materials at most this often on the launch/activation
    /// path. Was 6 hours when every sync meant fetching every course from
    /// Canvas; now that a no-change sync is just one manifest round trip
    /// (`SyncManifestResponse.coursesFresh` short-circuits the Canvas fetch
    /// entirely), there's no reason to hold announcements — which change
    /// daily and are the main thing ask needs to stay current — back for six
    /// hours' worth of staleness.
    static let courseKnowledgeStaleAfter: TimeInterval = 60 * 60

    var courseKnowledgeIsStale: Bool {
        guard let last = courseKnowledge.lastSyncedAt else { return true }
        return Date().timeIntervalSince(last) > Self.courseKnowledgeStaleAfter
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
    func refreshCourseKnowledge(cookies: [HTTPCookie], force: Bool = false) async {
        guard !isUsingFixtureData, !isCourseKnowledgeSyncing else { return }
        guard force || courseKnowledgeIsStale else { return }
        guard !cookies.isEmpty else {
            courseKnowledgeNotice = "reconnect canvas to sync course materials."
            return
        }

        let courses = canvasCourseIDsByCode
            .map { code, id in
                CourseSummary(
                    courseID: id,
                    code: code,
                    name: courseDisplayName(code),
                    url: URL(string: "https://canvas.upenn.edu/courses/\(id)")
                )
            }
            .sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }

        isCourseKnowledgeSyncing = true
        defer { isCourseKnowledgeSyncing = false }

        let store = CourseKnowledgeStore.default()
        let collector = CourseKnowledgeCollector(cookies: cookies, store: store)

        guard let client = BackendServices.client else {
            // No backend configured: this phone is fully on-device, exactly
            // as it always was. Fetch every course fully from Canvas.
            do {
                let report = try await collector.run(courses: courses, fetchFully: nil)
                courseKnowledge = report.knowledge
                if report.syncedCourses == 0 {
                    courseKnowledgeNotice = "couldn't read course materials from canvas. \(report.errors.first ?? "")"
                } else if !report.errors.isEmpty {
                    courseKnowledgeNotice = "synced \(report.syncedCourses) courses; some pages were skipped."
                } else {
                    courseKnowledgeNotice = nil
                }
            } catch {
                courseKnowledgeNotice = error.localizedDescription
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

        let plan = SyncPlanner.plan(courses: courses, manifest: manifest)

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
                }
            }
        } catch {
            courseKnowledgeNotice = error.localizedDescription
        }
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
}
