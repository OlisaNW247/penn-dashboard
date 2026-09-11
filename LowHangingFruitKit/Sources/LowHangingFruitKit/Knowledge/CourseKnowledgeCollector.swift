import Foundation

/// One course-materials sync: for every enrolled course, gather the syllabus
/// text (`CanvasSyllabusClient`), announcement bodies
/// (`CanvasAnnouncementsClient`), module contents (`CanvasModulesClient`), and
/// assignment descriptions plus page bodies (`CanvasCourseContentClient`),
/// then merge the lot into the on-device knowledge base.
///
/// Every request reuses the student's saved Canvas session; nothing here
/// talks to anything but Canvas. Per-course failures are recorded, not
/// thrown, so one course with a broken Modules page can't hide the rest. An
/// expired session is the exception: it is thrown so the caller can stop
/// hammering Canvas and tell the student to reconnect.
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
        public let syncedCourses: Int
        public let errors: [String]
        /// Which courses this run actually re-fetched from Canvas and
        /// merged as a full resync — i.e. the `fetchFully` set that
        /// succeeded (or, when `fetchFully` was `nil`, every course whose
        /// endpoints mostly answered). A caller uploading to the shared
        /// backend needs exactly this set for `SyncPlanner.uploads(fullyFetched:)`,
        /// and `syncedCourses` alone (a count) can't reconstruct it.
        public let fullyFetchedCourseIDs: Set<String>
        /// Outbound links gathered from this run's pages, assignments, and
        /// module items — the raw material for the server's course-website
        /// discovery (`backend/PROTOCOL.md`'s `discover-websites`). Not
        /// persisted to `CourseKnowledgeStore`; a caller uploads them and
        /// then discards them, the same way `fullyFetchedCourseIDs` is
        /// consumed by `SyncPlanner.uploads` and never written to disk.
        public let links: [CourseLink]

        public init(knowledge: CourseKnowledgeBase, syncedCourses: Int, errors: [String], fullyFetchedCourseIDs: Set<String> = [], links: [CourseLink] = []) {
            self.knowledge = knowledge
            self.syncedCourses = syncedCourses
            self.errors = errors
            self.fullyFetchedCourseIDs = fullyFetchedCourseIDs
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

    public init(
        cookies: [HTTPCookie],
        store: CourseKnowledgeStore,
        baseURL: URL = URL(string: "https://canvas.upenn.edu")!,
        session: URLSession = .shared
    ) {
        self.cookies = cookies
        self.store = store
        self.baseURL = baseURL
        self.session = session
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
        // Outbound links, gathered only from pages, assignments and module
        // items — never announcements, which are noisy (a link to a due
        // Gradescope assignment, a Zoom room, a form) compared to the
        // handful of stable, structural pointers those three surfaces tend
        // to carry to the course's own external site.
        var links: [CourseLink] = []

        // Announcements come from one call for every course at once.
        let byCourse = Dictionary(uniqueKeysWithValues: courses.map { ($0.courseID, $0) })
        do {
            let client = CanvasAnnouncementsClient(baseURL: baseURL, cookies: cookies, session: session)
            let since = now.addingTimeInterval(-Double(Self.announcementLookbackDays) * 86_400)
            let announcements = try await client.fetchAnnouncements(courseIDs: courses.map(\.courseID), since: since)
            for announcement in announcements {
                guard let course = byCourse[announcement.courseID] else { continue }
                documents.append(CourseDocumentBuilder.announcement(from: announcement, course: course, now: now))
            }
        } catch {
            errors.append("announcements: \(error.localizedDescription)")
        }

        let content = CanvasCourseContentClient(baseURL: baseURL, cookies: cookies, session: session)
        let syllabus = CanvasSyllabusClient(baseURL: baseURL, cookies: cookies, session: session)
        let modules = CanvasModulesClient(baseURL: baseURL, cookies: cookies, session: session)

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

            do {
                let pages = try await content.pages(courseID: course.courseID)
                documents.append(contentsOf: pages.map { CourseDocumentBuilder.page(from: $0, course: course, now: now) })
                links.append(contentsOf: pages.flatMap { CourseDocumentBuilder.links(from: $0, course: course) })
            } catch {
                courseErrors += 1
                errors.append("\(course.code) pages: \(error.localizedDescription)")
            }

            do {
                for candidate in try await syllabus.findCandidates(courseID: course.courseID) {
                    if let doc = CourseDocumentBuilder.syllabus(from: candidate, course: course, now: now) {
                        documents.append(doc)
                    }
                    links.append(contentsOf: candidate.links.map {
                        CourseLink(courseID: course.courseID, href: $0.href, text: $0.text, origin: .syllabus)
                    })
                }
            } catch {
                courseErrors += 1
                errors.append("\(course.code) syllabus: \(error.localizedDescription)")
            }

            do {
                let items = try await modules.fetchModuleItems(courseID: course.courseID)
                documents.append(contentsOf: CourseDocumentBuilder.modules(from: items, course: course, now: now))
                links.append(contentsOf: CourseDocumentBuilder.links(from: items, course: course))
            } catch {
                courseErrors += 1
                errors.append("\(course.code) modules: \(error.localizedDescription)")
            }

            // A course counts as re-synced (so vanished documents are dropped)
            // only when most of its endpoints answered; otherwise the last
            // good copy is kept rather than half-erased.
            if courseErrors <= 1 { synced.insert(course.courseID) }
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

        return Report(knowledge: knowledge, syncedCourses: synced.count, errors: errors, fullyFetchedCourseIDs: synced, links: dedupedLinks)
    }
}
