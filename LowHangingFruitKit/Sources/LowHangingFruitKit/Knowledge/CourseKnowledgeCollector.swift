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
public struct CourseKnowledgeCollector: Sendable {
    public struct Report: Sendable {
        public let knowledge: CourseKnowledgeBase
        public let syncedCourses: Int
        public let errors: [String]

        public init(knowledge: CourseKnowledgeBase, syncedCourses: Int, errors: [String]) {
            self.knowledge = knowledge
            self.syncedCourses = syncedCourses
            self.errors = errors
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

    public func run(courses: [CourseSummary], now: Date = Date()) async throws -> Report {
        guard !courses.isEmpty else {
            return Report(knowledge: store.load(), syncedCourses: 0, errors: ["No Canvas courses with ids to sync."])
        }

        var documents: [CourseDocument] = []
        var errors: [String] = []
        var synced: Set<String> = []

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
            var courseErrors = 0

            do {
                let assignments = try await content.assignments(courseID: course.courseID)
                documents.append(contentsOf: assignments.map { CourseDocumentBuilder.assignment(from: $0, course: course, now: now) })
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
            } catch {
                courseErrors += 1
                errors.append("\(course.code) pages: \(error.localizedDescription)")
            }

            do {
                for candidate in try await syllabus.findCandidates(courseID: course.courseID) {
                    if let doc = CourseDocumentBuilder.syllabus(from: candidate, course: course, now: now) {
                        documents.append(doc)
                    }
                }
            } catch {
                courseErrors += 1
                errors.append("\(course.code) syllabus: \(error.localizedDescription)")
            }

            do {
                let items = try await modules.fetchModuleItems(courseID: course.courseID)
                documents.append(contentsOf: CourseDocumentBuilder.modules(from: items, course: course, now: now))
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
        return Report(knowledge: knowledge, syncedCourses: synced.count, errors: errors)
    }
}
