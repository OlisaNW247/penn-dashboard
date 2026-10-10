import Foundation

/// One course-materials sync: for every enrolled course, gather the syllabus
/// text (`CanvasSyllabusClient`), announcement bodies
/// (`CanvasAnnouncementsClient`), module contents (`CanvasModulesClient`), and
/// assignment descriptions plus page bodies (`CanvasCourseContentClient`),
/// then merge the lot into the on-device knowledge base.
///
/// Every request reuses the student's saved Canvas session, or a
/// `CanvasAccessToken` bearer token when one is available (`accessToken`,
/// forwarded unchanged to every client this collector builds); nothing here
/// talks to anything but Canvas. Per-course failures are recorded, not
/// thrown, so one course with a broken Modules page can't hide the rest. An
/// expired session is the exception: it is thrown so the caller can stop
/// hammering Canvas and tell the student to reconnect. A 403 is not an
/// expired session (see `CanvasCourseContentClient.Error.sessionExpired`): it
/// is one course Canvas will not show this account, and that course alone is
/// recorded as an error while the others carry on.
///
/// **A course is only "fully fetched" if nothing about it failed.** The merge
/// drops a fully fetched course's documents that were not seen this run, and
/// the upload tells the server the same, for every classmate, so a fetch that
/// failed and came back empty is indistinguishable from a document the
/// teacher deleted. Any error while reading a course (an endpoint, a page
/// body, a syllabus request, or the announcements call, which covers every
/// course at once) makes it *partial*: its new documents are added and its
/// changed ones updated, nothing it already holds is dropped, and it is not
/// reported as fully synced.
///
/// `fetchFully` (see `run`) lets a caller skip the Canvas fetch for courses
/// the shared backend already has fresh: if a classmate in the same Canvas
/// site fully synced a course an hour ago, that course's syllabus,
/// assignments, pages and modules are already sitting in the shared store
/// and can be downloaded instead of re-scraped from Canvas, which is both
/// cheaper for the student's device and gentler on Canvas itself.
/// Announcements are the one exception: they're fetched for every course
/// regardless of freshness, because a brand-new post can't wait for the
/// next full-sync window.
public struct CourseKnowledgeCollector: Sendable {
    public struct Report: Sendable {
        public let knowledge: CourseKnowledgeBase
        /// How many courses came back usable: at most one of their endpoints
        /// failed. This is only a count for the "couldn't read course
        /// materials" notice; it says nothing about which courses were read
        /// in full (`fullyFetchedCourseIDs`).
        public let syncedCourses: Int
        public let errors: [String]
        /// Which courses this run re-fetched from Canvas without a single
        /// error and merged as a full resync (so documents Canvas no longer
        /// has were dropped). A caller uploading to the shared backend needs
        /// exactly this set for `SyncPlanner.uploads(fullyFetched:)`, and
        /// `syncedCourses` alone (a count) can't reconstruct it. A course
        /// with any error is in `partialCourseIDs` instead.
        public let fullyFetchedCourseIDs: Set<String>
        /// Courses this run fetched from Canvas where something failed. Their
        /// documents were merged add-and-update only, and they are
        /// deliberately absent from `fullyFetchedCourseIDs`.
        public let partialCourseIDs: Set<String>
        /// Outbound links gathered from this run's pages, assignments, and
        /// module items — the raw material for the server's course-website
        /// discovery (`backend/PROTOCOL.md`'s `discover-websites`). Not
        /// persisted to `CourseKnowledgeStore`; a caller uploads them and
        /// then discards them, the same way `fullyFetchedCourseIDs` is
        /// consumed by `SyncPlanner.uploads` and never written to disk.
        public let links: [CourseLink]

        public init(
            knowledge: CourseKnowledgeBase,
            syncedCourses: Int,
            errors: [String],
            fullyFetchedCourseIDs: Set<String> = [],
            partialCourseIDs: Set<String> = [],
            links: [CourseLink] = []
        ) {
            self.knowledge = knowledge
            self.syncedCourses = syncedCourses
            self.errors = errors
            self.fullyFetchedCourseIDs = fullyFetchedCourseIDs
            self.partialCourseIDs = partialCourseIDs
            self.links = links
        }
    }

    /// How far back announcements are pulled on a sync. A semester is about
    /// 115 days; 200 covers a course that started early or ran late.
    public static let announcementLookbackDays = 200

    private let baseURL: URL
    private let cookies: [HTTPCookie]
    private let session: URLSession
    private let store: CourseKnowledgeStore
    /// Forwarded, unchanged, to every Canvas client this collector builds
    /// below — see `CanvasAuth.apply` for why a token wins over cookies when
    /// both are present. `nil` (the pre-existing behavior) means every
    /// request goes out cookie-authenticated, exactly as before this
    /// parameter existed.
    private let accessToken: String?

    public init(
        cookies: [HTTPCookie],
        store: CourseKnowledgeStore,
        baseURL: URL = URL(string: "https://canvas.upenn.edu")!,
        session: URLSession = .shared,
        accessToken: String? = nil
    ) {
        self.cookies = cookies
        self.store = store
        self.baseURL = baseURL
        self.session = session
        self.accessToken = accessToken
    }

    /// - Parameter fetchFully: Which courses to actually fetch from Canvas
    ///   this run. `nil` (the default, and the only behavior before this
    ///   parameter existed) means every course. A course in `courses` but
    ///   not in this set still gets its announcements collected — that call
    ///   covers every course in one request regardless — but is skipped for
    ///   assignments/pages/syllabus/modules and is not inserted into
    ///   `synced`, so `merge` leaves its existing documents exactly as they
    ///   were rather than treating the (empty, for those endpoints) fetch
    ///   this run as a full resync that erases them.
    public func run(courses: [CourseSummary], fetchFully: Set<String>? = nil, now: Date = Date()) async throws -> Report {
        guard !courses.isEmpty else {
            return Report(knowledge: store.load(), syncedCourses: 0, errors: ["No Canvas courses with ids to sync."])
        }

        var documents: [CourseDocument] = []
        var errors: [String] = []
        var synced: Set<String> = []
        var partial: Set<String> = []
        var usableCourses = 0
        var announcementsFailed = false
        // Outbound links, gathered only from pages, assignments and module
        // items — never announcements, which are noisy (a link to a due
        // Gradescope assignment, a Zoom room, a form) compared to the
        // handful of stable, structural pointers those three surfaces tend
        // to carry to the course's own external site.
        var links: [CourseLink] = []

        // Announcements come from one call for every course at once.
        let byCourse = Dictionary(uniqueKeysWithValues: courses.map { ($0.courseID, $0) })
        do {
            let client = CanvasAnnouncementsClient(baseURL: baseURL, cookies: cookies, session: session, accessToken: accessToken)
            let since = now.addingTimeInterval(-Double(Self.announcementLookbackDays) * 86_400)
            let announcements = try await client.fetchAnnouncements(courseIDs: courses.map(\.courseID), since: since)
            for announcement in announcements {
                guard let course = byCourse[announcement.courseID] else { continue }
                documents.append(CourseDocumentBuilder.announcement(from: announcement, course: course, now: now))
            }
        } catch {
            errors.append("announcements: \(error.localizedDescription)")
            // The one call covers every course. Without it a fully fetched
            // course would be merged with no announcements at all, dropping
            // the ones it holds and telling the server they are gone.
            announcementsFailed = true
        }

        let content = CanvasCourseContentClient(baseURL: baseURL, cookies: cookies, session: session, accessToken: accessToken)
        let syllabus = CanvasSyllabusClient(baseURL: baseURL, cookies: cookies, session: session, accessToken: accessToken)
        let modules = CanvasModulesClient(baseURL: baseURL, cookies: cookies, session: session, accessToken: accessToken)

        // What the device already holds for each course's pages, so a page
        // whose `updated_at` has not moved is not downloaded again.
        var storedPages: [String: [String: CourseDocument]] = [:]
        for document in store.load().documents where document.kind == .page {
            storedPages[document.courseID, default: [:]][document.sourceID] = document
        }

        for course in courses {
            guard fetchFully == nil || fetchFully!.contains(course.courseID) else {
                // Already fresh on the shared backend for this run: leave
                // its assignments/pages/syllabus/modules alone (they were,
                // or will be, applied from `SyncPlanner.applyDownloads`
                // instead) and don't touch `synced`, so the merge below
                // keeps whatever this course already has on disk.
                continue
            }

            var courseErrors = 0

            do {
                let assignments = try await content.assignments(courseID: course.courseID)
                documents.append(contentsOf: assignments.map { CourseDocumentBuilder.assignment(from: $0, course: course, now: now) })
                links.append(contentsOf: assignments.flatMap { CourseDocumentBuilder.links(from: $0, course: course) })
            } catch CanvasCourseContentClient.Error.sessionExpired {
                // Stop here: every further request would fail the same way,
                // and the student needs to reconnect, not wait.
                throw CanvasCourseContentClient.Error.sessionExpired
            } catch {
                courseErrors += 1
                errors.append("\(course.code) assignments: \(error.localizedDescription)")
            }

            // Modules are fetched ahead of pages because they say which pages
            // the instructor linked, and those are read first. Their
            // documents and links are still appended last, below, so the
            // order everything else in this run is gathered in is unchanged.
            var moduleItems: [CanvasModulesClient.ModuleItem] = []
            do {
                moduleItems = try await modules.fetchModuleItems(courseID: course.courseID)
            } catch {
                courseErrors += 1
                errors.append("\(course.code) modules: \(error.localizedDescription)")
            }

            do {
                let stored = storedPages[course.courseID] ?? [:]
                let pageSet = try await content.pages(
                    courseID: course.courseID,
                    priorityPageURLs: moduleItems.compactMap(\.pageURL),
                    storedUpdatedAt: stored.compactMapValues(\.updatedAt)
                )
                if let front = pageSet.frontPage {
                    documents.append(CourseDocumentBuilder.home(from: front, course: course, now: now))
                    links.append(contentsOf: CourseDocumentBuilder.links(from: front, course: course))
                }
                documents.append(contentsOf: pageSet.pages.map { CourseDocumentBuilder.page(from: $0, course: course, now: now) })
                links.append(contentsOf: pageSet.pages.flatMap { CourseDocumentBuilder.links(from: $0, course: course) })
                // An unchanged page keeps its stored document, which must be
                // in this run's set or a full merge would treat it as gone.
                // Its links are not re-gathered (the stored text has no
                // hrefs); the server already holds the candidates from the
                // run that first read the page.
                documents.append(contentsOf: pageSet.unchangedPageURLs.compactMap { stored[$0] })
                if !pageSet.failures.isEmpty {
                    courseErrors += 1
                    errors.append("\(course.code) pages: \(pageSet.failures.count) not read, first: \(pageSet.failures[0])")
                }
            } catch {
                courseErrors += 1
                errors.append("\(course.code) pages: \(error.localizedDescription)")
            }

            let syllabusSearch = await syllabus.searchCandidates(courseID: course.courseID)
            for candidate in syllabusSearch.candidates {
                if let doc = CourseDocumentBuilder.syllabus(from: candidate, course: course, now: now) {
                    documents.append(doc)
                }
                links.append(contentsOf: candidate.links.map {
                    CourseLink(courseID: course.courseID, href: $0.href, text: $0.text, origin: .syllabus)
                })
            }
            if !syllabusSearch.failures.isEmpty {
                courseErrors += 1
                errors.append("\(course.code) syllabus: \(syllabusSearch.failures[0])")
            }

            documents.append(contentsOf: CourseDocumentBuilder.modules(from: moduleItems, course: course, now: now))
            links.append(contentsOf: CourseDocumentBuilder.links(from: moduleItems, course: course))

            // A course counts as re-synced (so vanished documents are
            // dropped, here and on the server) only when nothing about it
            // failed. A partial course still gets everything that did arrive
            // merged in; it just never loses what it already had.
            if courseErrors <= 1 { usableCourses += 1 }
            if courseErrors == 0 && !announcementsFailed {
                synced.insert(course.courseID)
            } else {
                partial.insert(course.courseID)
            }
        }

        var knowledge = store.load()
        knowledge.merge(courses: courses, documents: documents, resyncedCourseIDs: synced, syncedAt: now)
        try store.save(knowledge)

        // De-duplicated by (courseID, href) — the same link commonly
        // reappears across a course's pages and module items (a syllabus
        // link repeated in every week's "Readings" module, say), and the
        // upload doesn't need N copies of it. Capped at 400 total, a
        // generous ceiling for what should normally be a handful of links
        // per course, so one course with an unusually link-heavy site can't
        // balloon the upload body.
        var seenLinks: Set<String> = []
        var dedupedLinks: [CourseLink] = []
        for link in links {
            let key = "\(link.courseID)|\(link.href)"
            guard seenLinks.insert(key).inserted else { continue }
            dedupedLinks.append(link)
            if dedupedLinks.count == 400 { break }
        }

        return Report(
            knowledge: knowledge,
            syncedCourses: usableCourses,
            errors: errors,
            fullyFetchedCourseIDs: synced,
            partialCourseIDs: partial,
            links: dedupedLinks
        )
    }
}
