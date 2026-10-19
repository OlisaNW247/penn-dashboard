import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Covers the wiring added to plug `CanvasAnnouncementsClient` +
/// `AnnouncementAssignmentExtractor` into the dashboard: the new
/// `Assignment.Source.canvasAnnouncement` case, `RecurringTask.isOccurrence`'s
/// updated switch, `AppState`'s two pure static helpers
/// (`announcementAssignments(from:announcement:courseCode:)` and
/// `filteringAnnouncementDuplicates(_:against:)`), the ledger/dashboard
/// partition guarantee `.canvasAnnouncement` rows get from
/// `AssignmentStore.reconcile(_:source:)`, and the two Settings-facing
/// defaults (`announcementWatcherEnabled`, `announcementAIEnabled`).
///
/// (Stale below the first sentence: `syncAnnouncements()` now has test seams
/// and is exercised end to end by `AnnouncementLogSyncTests` and, for Ed
/// posts, by `AnnouncementWatcherEdTests` at the bottom of this file.)
/// `syncAnnouncements()` itself is NOT exercised here — same reasoning
/// `ModuleReadingImportTests` gives for not exercising
/// `refreshCourseIntel(cookies:)`'s network path: it needs a non-empty cookie
/// jar and talks to `CanvasAnnouncementsClient` over a real `URLSession` with
/// no injection seam from `AppState`. Everything downstream of a fetch — the
/// mapping, the dedup, the ledger partition, the dashboard bucket placement —
/// is fully covered by driving those seams directly, the same split
/// `ModuleReadingImportTests` uses for the modules-import path.
///
/// `AppState` persists into the process-wide `UserDefaults.lhf`, so every test
/// that touches the two announcement-watcher settings keys backs them up and
/// restores them — see `ConnectionNoticeTests.withRestoredDefaults`. The
/// suite is `.serialized`, matching `ModuleReadingImportTests`, since more
/// than one test here writes to those same process-wide keys.
@MainActor
@Suite("Announcement watcher wiring", .serialized)
struct AnnouncementWatcherWiringTests {

    private static let watcherEnabledKey = "announcementWatcherEnabledV1"
    private static let aiEnabledKey = "announcementAIEnabledV1"
    private static let processedIDsKey = "processedAnnouncementIDsV1"
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let touchedKeys = [watcherEnabledKey, aiEnabledKey, processedIDsKey, extractionVersionKey]

    /// Snapshots every announcement-watcher key this suite can touch, runs
    /// `body`, then puts the real values back exactly as found — `nil`
    /// meaning "the key was absent," restored by removing it rather than
    /// writing some placeholder. Mirrors `ConnectionNoticeTests
    /// .withRestoredDefaults` / `ModuleReadingImportTests.withCleanDecision`.
    private func withRestoredDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let saved = Self.touchedKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        body()
    }

    // MARK: - Item 1: Source rawValue + Assignment.id round-trip

    @Test(".canvasAnnouncement rawValue round-trips through Source(rawValue:), and an Assignment carrying it round-trips its id")
    func sourceRawValueRoundTrips() {
        #expect(Assignment.Source(rawValue: "canvasAnnouncement") == .canvasAnnouncement)
        #expect(Assignment.Source.canvasAnnouncement.rawValue == "canvasAnnouncement")

        let item = Assignment(
            source: .canvasAnnouncement,
            sourceID: "announcement-42-0",
            kind: .assignment,
            course: "CIS 1200",
            title: "Bring a signed permission form",
            dueAt: nil,
            url: nil
        )
        #expect(item.id == "canvasAnnouncement:announcement-42-0")
    }

    // MARK: - Item 2: RecurringTask.isOccurrence

    @Test("RecurringTask.isOccurrence is false for a .canvasAnnouncement item — it's real coursework, never a generated occurrence")
    func isOccurrenceFalseForAnnouncementItem() {
        let item = Assignment(
            source: .canvasAnnouncement,
            sourceID: "announcement-7-0",
            kind: .assignment,
            course: "CIS 1200",
            title: "Read chapter 4 before Friday",
            dueAt: Date(),
            url: nil
        )
        #expect(!RecurringTask.isOccurrence(item))
    }

    // MARK: - Item 3: announcementAssignments(from:announcement:courseCode:)

    @Test("announcementAssignments maps every field, mints stable per-index sourceIDs, and maps .submission -> .assignment / .preparation -> .event")
    func announcementAssignmentsMapsFields() {
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let announcementURL = URL(string: "https://canvas.upenn.edu/courses/1010/discussion_topics/555")!
        let announcement = CanvasAnnouncement(
            id: "555",
            courseID: "1010",
            title: "Midterm logistics",
            message: "Read chapter 4 before Friday. Bring a calculator.",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: announcementURL
        )
        // One of each `ExtractedTaskKind` — `.submission` (something to hand
        // in) and `.preparation` (something to do or bring, nothing to
        // submit) — so the kind mapping is covered on both branches, not
        // just the historically-only-branch `.assignment` case.
        let extracted = [
            ExtractedAssignment(title: "Read chapter 4", dueAt: dueDate, kind: .submission),
            ExtractedAssignment(title: "Bring a calculator", dueAt: nil, kind: .preparation),
        ]

        let mapped = AppState.announcementAssignments(
            from: extracted,
            announcement: announcement,
            courseCode: "CIS 1010"
        )

        #expect(mapped.count == 2)
        #expect(mapped.allSatisfy { $0.source == .canvasAnnouncement })
        #expect(mapped.allSatisfy { $0.course == "CIS 1010" })
        #expect(mapped.allSatisfy { $0.url == announcementURL })
        #expect(mapped.allSatisfy { $0.submitted == false })

        #expect(mapped[0].sourceID == "announcement-555-0")
        #expect(mapped[0].title == "Read chapter 4")
        #expect(mapped[0].dueAt == dueDate)
        #expect(mapped[0].kind == .assignment)

        #expect(mapped[1].sourceID == "announcement-555-1")
        #expect(mapped[1].title == "Bring a calculator")
        #expect(mapped[1].dueAt == nil)
        #expect(mapped[1].kind == .event)
    }

    // MARK: - Item 4: filteringAnnouncementDuplicates

    @Test("filteringAnnouncementDuplicates drops a same-course title match, keeps a genuinely new one, and keeps a same-title item in a different course")
    func filteringAnnouncementDuplicatesDropsOnlyRealMatches() {
        let due = Date()
        let existingCanvasAssignment = Assignment(
            source: .canvas, sourceID: "c1", kind: .assignment,
            course: "CIS 1200", title: "HW 3", dueAt: due, url: nil
        )

        // "Homework 3" normalizes to the same token sequence as "HW 3"
        // (`AssignmentDeduplicator.normalize` canonicalizes "homework" -> "hw"),
        // same course, same due date — a real duplicate.
        let duplicateCandidate = Assignment(
            source: .canvasAnnouncement, sourceID: "a1", kind: .assignment,
            course: "CIS 1200", title: "Homework 3", dueAt: due, url: nil
        )
        // Unrelated title, same course — nothing to collapse into.
        let newCandidate = Assignment(
            source: .canvasAnnouncement, sourceID: "a2", kind: .assignment,
            course: "CIS 1200", title: "Bring your laptop to lecture", dueAt: due, url: nil
        )
        // Same title as the existing item, but a different course — course
        // scoping must keep this one, even though the title alone would match.
        let sameTitleOtherCourse = Assignment(
            source: .canvasAnnouncement, sourceID: "a3", kind: .assignment,
            course: "MATH 1400", title: "HW 3", dueAt: due, url: nil
        )

        let filtered = AppState.filteringAnnouncementDuplicates(
            [duplicateCandidate, newCandidate, sameTitleOtherCourse],
            against: [existingCanvasAssignment]
        )

        #expect(!filtered.contains { $0.sourceID == "a1" })
        #expect(filtered.contains { $0.sourceID == "a2" })
        #expect(filtered.contains { $0.sourceID == "a3" })
    }

    @Test("announcement duplicate filtering canonicalizes raw and formatted course labels")
    func filteringAnnouncementDuplicatesCanonicalizesCourseLabels() {
        let existing = Assignment(
            source: .canvas, sourceID: "quiz-2", kind: .quiz,
            course: "CIS 1200", title: "Quiz 2", dueAt: Date(), url: nil
        )
        let announcement = Assignment(
            source: .canvasAnnouncement, sourceID: "announcement-quiz-2", kind: .assignment,
            course: "CIS-1200-001 202630 Programming Languages",
            title: "Take Quiz 2 on Canvas by Friday", dueAt: nil, url: nil
        )

        #expect(AppState.announcementCoursesMatch(announcement.course, existing.course))
        #expect(AppState.announcementCoursesMatch("PHYS 0151", "PHYS 151"))
        #expect(AppState.filteringAnnouncementDuplicates([announcement], against: [existing]).isEmpty)
    }

    @Test("per-course announcement toggle changes dashboard promotion but never the announcements page")
    func perCourseAnnouncementToggleOnlyChangesDashboard() {
        withRestoredDefaults {
            UserDefaults.lhf.set(2, forKey: Self.extractionVersionKey)
            let store = try! AssignmentStore(inMemory: true)
            store.upsert([Assignment(
                source: .canvasAnnouncement,
                sourceID: "announcement-assessment-3",
                kind: .assignment,
                course: "PHYS 0151",
                title: "Assessment 3",
                dueAt: Date().addingTimeInterval(3_600),
                url: nil
            )])

            let state = AppState(assignmentStore: store)
            let originalPreference = state.coursePreferences
                .announcementAssignmentsOnDashboard("PHYS 0151")
            defer {
                state.setAnnouncementAssignmentsOnDashboard("PHYS 0151", originalPreference)
            }
            // This preference is intentionally persistent; make the test's
            // starting state explicit so a prior run that toggled it off
            // cannot leak into this assertion.
            state.setAnnouncementAssignmentsOnDashboard("PHYS 0151", true)
            #expect((state.assignments + state.laterAssignments + state.assessments)
                .contains { $0.sourceID == "announcement-assessment-3" })
            #expect(state.announcementPageItems.contains { $0.sourceID == "announcement-assessment-3" })

            state.setAnnouncementAssignmentsOnDashboard("PHYS 0151", false)

            #expect(!(state.assignments + state.laterAssignments + state.assessments)
                .contains { $0.sourceID == "announcement-assessment-3" })
            #expect(state.announcementPageItems.contains { $0.sourceID == "announcement-assessment-3" })
        }
    }

    @Test("announcement routing keeps direct assessments on the dashboard and moves preparation or materials to finds")
    func announcementRoutingSeparatesOwedWorkFromFinds() {
        func placement(_ title: String, kind: Assignment.Kind = .assignment) -> AppState.AnnouncementDashboardPlacement {
            AppState.announcementDashboardPlacement(for: Assignment(
                source: .canvasAnnouncement, sourceID: title, kind: kind,
                course: "CIS 1200", title: title, dueAt: nil, url: nil
            ))
        }

        #expect(placement("Take midterm 1") == .main)
        #expect(placement("Take mid term 1 by Thursday") == .main)
        #expect(placement("Take mid-term 1 by Thursday") == .main)
        #expect(placement("Take the practice mid term by Thursday") == .find)
        #expect(placement("Practice midterm") == .find)
        #expect(placement("Practice mid term") == .find)
        #expect(placement("Review p sets") == .find)
        #expect(placement("Bring Arches cover paper") == .find)
        #expect(placement("Read chapter 4", kind: .event) == .find)
        #expect(placement("Slides have been posted", kind: .assignment) == .find)
        #expect(placement("Quiz 2", kind: .event) == .main)
        #expect(placement("Test 1", kind: .event) == .main)
        #expect(placement("Assessment 3", kind: .event) == .main)
        #expect(placement("Mid term 1", kind: .event) == .main)
        #expect(placement("Take the practice test", kind: .assignment) == .find)
        #expect(placement("Quiz grades posted", kind: .assignment) == .find)
    }

    // MARK: - Item 5: ledger partition guarantee + dashboard visibility

    @Test("preparation announcement rows surface only in finds and survive a .canvas-source reconcile")
    func announcementRowsSurviveCanvasReconcileAndSurfaceOnDashboard() {
        withRestoredDefaults {
            // Pinned to the current repair version so `AppState.init`'s
            // one-time `repairAnnouncementExtractionIfNeeded` (see that
            // method's doc comment) is a no-op here — this test is about the
            // ledger partition guarantee and dashboard visibility, not about
            // the repair, and an unrelated incomplete `.canvasAnnouncement`
            // fixture is exactly what that repair would otherwise purge.
            UserDefaults.lhf.set(2, forKey: Self.extractionVersionKey)

            let store = try! AssignmentStore(inMemory: true)
            let course = "ANNC 9001"

            // Due an hour from now, not literally `Date()` — see
            // `ModuleReadingImportTests.includedReadingSurfacesInCoursework`'s
            // doc comment: a fixture due at the instant of construction can read
            // as already-passed by the time `AppState.init`'s later
            // `rebuildDashboardItems` captures `now`.
            let announcementRow = Assignment(
                source: .canvasAnnouncement,
                sourceID: "announcement-9001-0",
                kind: .assignment,
                course: course,
                title: "Bring a signed permission form",
                dueAt: Date().addingTimeInterval(3600),
                url: nil
            )
            store.upsert([announcementRow])

            let state = AppState(assignmentStore: store)
            let dashboardItems = state.assignments + state.laterAssignments + state.assessments
            #expect(!dashboardItems.contains { $0.title == "Bring a signed permission form" })
            #expect(state.announcementFinds.contains { $0.title == "Bring a signed permission form" })

            // A `.canvas`-source reconcile for the same course must not disturb
            // the `.canvasAnnouncement` row — `reconcile` partitions existing
            // rows by source before deciding what's missing from a fresh fetch,
            // so a same-course, different-source batch can never mark it gone.
            let canvasRow = Assignment(
                source: .canvas, sourceID: "hw-1", kind: .assignment,
                course: course, title: "Problem set 1", dueAt: Date(), url: nil
            )
            _ = store.reconcile([canvasRow], source: .canvas)

            let announcementRowsAfter = store.assignments(source: .canvasAnnouncement)
            #expect(announcementRowsAfter.contains { $0.sourceID == "announcement-9001-0" })
        }
    }

    @Test("a structured assignment arriving after an announcement removes the announcement twin on rebuild")
    func lateStructuredAssignmentSuppressesAnnouncementTwin() {
        withRestoredDefaults {
            UserDefaults.lhf.set(2, forKey: Self.extractionVersionKey)
            let store = try! AssignmentStore(inMemory: true)
            let course = "CIS 1200"
            store.upsert([Assignment(
                source: .canvasAnnouncement,
                sourceID: "announcement-quiz-2",
                kind: .assignment,
                course: "CIS-1200-001 202630 Programming Languages",
                title: "Take Quiz 2 on Canvas by Friday",
                dueAt: nil,
                url: nil
            )])

            let state = AppState(assignmentStore: store)
            #expect((state.assignments + state.laterAssignments + state.assessments)
                .contains { $0.source == .canvasAnnouncement && $0.title == "Take Quiz 2 on Canvas by Friday" })
            let announcementItem = state.announcementItems.first { $0.sourceID == "announcement-quiz-2" }!
            state.markCompleted(announcementItem)

            state.canvasItems = [Assignment(
                source: .canvas,
                sourceID: "quiz-2",
                kind: .quiz,
                course: course,
                title: "Quiz 2",
                dueAt: Date().addingTimeInterval(3600),
                url: nil
            )]
            state.setCourse(course, selected: true)

            #expect(state.mergedCoursework.contains { $0.source == .canvas && $0.title == "Quiz 2" })
            #expect(!state.mergedCoursework.contains { $0.source == .canvasAnnouncement })
            #expect(!state.announcementFinds.contains { $0.sourceID == "announcement-quiz-2" })
            #expect(state.isCompleted(state.canvasItems[0]))
        }
    }

    // MARK: - Item 6: settings defaults

    @Test("announcementWatcherEnabled and announcementAIEnabled both default true with no key on disk — ai assist now runs under LHF's own key, gated by the heuristic pre-filter rather than by defaulting off")
    func announcementSettingsDefaultOnDiskAbsent() {
        withRestoredDefaults {
            let defaults = UserDefaults.lhf
            defaults.removeObject(forKey: Self.watcherEnabledKey)
            defaults.removeObject(forKey: Self.aiEnabledKey)
            defaults.removeObject(forKey: Self.processedIDsKey)

            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))

            #expect(state.announcementWatcherEnabled)
            #expect(state.announcementAIEnabled)
        }
    }

    @Test("announcementAIEnabled honors an explicit false on disk rather than the new true default")
    func announcementAISettingExplicitFalseHonored() {
        withRestoredDefaults {
            UserDefaults.lhf.set(false, forKey: Self.aiEnabledKey)

            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))

            #expect(!state.announcementAIEnabled)
        }
    }

    @Test("setAnnouncementWatcherEnabled/setAnnouncementAIEnabled persist through UserDefaults.lhf and are read back on the next AppState")
    func announcementSettingsPersistAcrossLaunches() {
        withRestoredDefaults {
            let firstLaunch = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            firstLaunch.setAnnouncementWatcherEnabled(false)
            firstLaunch.setAnnouncementAIEnabled(true)

            let secondLaunch = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            #expect(!secondLaunch.announcementWatcherEnabled)
            #expect(secondLaunch.announcementAIEnabled)
        }
    }

    // MARK: - Item 7: the one-time announcement-extraction repair

    /// Covers `AppState.repairAnnouncementExtractionIfNeeded` — the sweep run
    /// once from `init` to clean up after the extractor rewrite that added
    /// `ExtractedTaskKind` and the informational/task-likely gates. Forces
    /// the repair to run by clearing the version key, seeds the ledger with
    /// one incomplete and one completed `.canvasAnnouncement` row (standing
    /// in for an old false-positive the student never acted on, and one they
    /// happened to tick off before the fix landed), and checks all three of
    /// the repair's effects land from a single `AppState(assignmentStore:)`
    /// construction.
    @Test("the one-time announcement-extraction repair purges an incomplete .canvasAnnouncement row, keeps a completed one, empties processedAnnouncementIDs, and claims the version")
    func announcementExtractionRepairPurgesIncompleteKeepsCompleted() {
        withRestoredDefaults {
            let defaults = UserDefaults.lhf
            defaults.removeObject(forKey: Self.extractionVersionKey)
            defaults.set(["announcement-1-0", "announcement-2-0"], forKey: Self.processedIDsKey)

            let store = try! AssignmentStore(inMemory: true)
            let course = "REPAIR 1000"
            let incomplete = Assignment(
                source: .canvasAnnouncement, sourceID: "wrong-guess-0", kind: .assignment,
                course: course, title: "The slides discussed today have been posted",
                dueAt: Date().addingTimeInterval(-3600), url: nil
            )
            let completed = Assignment(
                source: .canvasAnnouncement, sourceID: "real-task-0", kind: .assignment,
                course: course, title: "Bring a signed permission form",
                dueAt: Date().addingTimeInterval(-3600), url: nil
            )
            store.upsert([incomplete, completed])
            store.setCompleted(ids: [completed.id], at: Date())

            let state = AppState(assignmentStore: store)

            let remaining = store.assignments(source: .canvasAnnouncement)
            #expect(remaining.contains { $0.sourceID == "real-task-0" })
            #expect(!remaining.contains { $0.sourceID == "wrong-guess-0" })
            #expect(state.announcementItems.contains { $0.sourceID == "real-task-0" })
            #expect(!state.announcementItems.contains { $0.sourceID == "wrong-guess-0" })

            #expect(state.processedAnnouncementIDs.isEmpty)
            #expect(defaults.object(forKey: Self.processedIDsKey) == nil)

            #expect(defaults.integer(forKey: Self.extractionVersionKey) == 2)
        }
    }
}

/// `syncAnnouncements()` reading Ed Discussion posts, end to end with no
/// network: the Canvas fetch and the extractor choice are the per-instance
/// seams `announcementFetchForTesting` / `announcementExtractorForTesting`,
/// and the Ed posts are `.ed` documents placed in `courseKnowledge`, the
/// store the Ed sync fills. The wiring above could not run the sync; this
/// suite follows `AnnouncementEdSyncTests`' harness (a seeded id -> code map,
/// course codes unique to the suite) but leaves the announcement log off, so
/// it touches neither Application Support nor any seen-ids key.
///
/// The one shared write is the extraction pipeline's own
/// `processedAnnouncementIDsV1` (the sync cannot be pointed elsewhere), backed
/// up and restored the way `AnnouncementLogSyncTests` does; it and the repair
/// version are pinned before the `AppState` exists so its one-time sweep is a
/// no-op. Every id and class code here is unique to this suite.
@MainActor
@Suite("Announcement watcher: Ed posts", .serialized)
struct AnnouncementWatcherEdTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let processedKey = "processedAnnouncementIDsV1"
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    /// Written by every `syncAnnouncements` (`lastAnnouncementSyncSummaryV1`),
    /// so it is backed up and restored with the other two.
    private static let summaryKey = "lastAnnouncementSyncSummaryV1"
    /// The per-id failure counter and the run-level back-off, both written
    /// by a failing `syncAnnouncements`; backed up, cleared and restored.
    private static let attemptsKey = "announcementExtractionAttemptsV1"
    private static let backoffKey = "announcementExtractionBackoffUntilV1"
    private static let course = (id: "9401", code: "ANWED 9401")
    private static let hiddenCourse = (id: "9402", code: "ANWED 9402")

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var sources: [AnnouncementSourceText] = []
        func record(_ source: AnnouncementSourceText) {
            lock.lock(); defer { lock.unlock() }
            sources.append(source)
        }
        var all: [AnnouncementSourceText] {
            lock.lock(); defer { lock.unlock() }
            return sources
        }
        var ids: [String] { all.map(\.announcementID) }
    }

    /// Records what reached it and finds one task per announcement, always
    /// with the same title, so two announcements about "the same thing" can
    /// be built without a second extractor.
    private struct FindsOneTask: AnnouncementAssignmentExtractor {
        let seen: Seen
        let title: String
        let dueAt: Date?
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            seen.record(announcement)
            return [ExtractedAssignment(title: title, dueAt: dueAt, kind: .submission)]
        }
    }

    @MainActor
    private final class Harness {
        let state: AppState
        let seen = Seen()
        var canvasResponse: [CanvasAnnouncement] = []
        init(state: AppState) { self.state = state }

        var finds: [Assignment] { state.assignmentStore?.assignments(source: .canvasAnnouncement) ?? [] }
    }

    private func withHarness(
        taskTitle: String = "Sign up for a Verbal Assessment #2 slot",
        taskDue: Date? = nil,
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let backup = [
            Self.processedKey, Self.extractionVersionKey, Self.summaryKey, Self.attemptsKey, Self.backoffKey,
        ].map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in backup {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: Self.extractionVersionKey)
        shared.removeObject(forKey: Self.processedKey)
        shared.removeObject(forKey: Self.attemptsKey)
        shared.removeObject(forKey: Self.backoffKey)

        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        state.forceFixtureDataForTesting(false)
        let courses = [Self.course, Self.hiddenCourse]
        state.canvasItems = courses.map { course in
            Assignment(
                source: .canvas, sourceID: "seed-\(course.id)", kind: .assignment,
                course: course.code, title: "Seed \(course.code)", dueAt: nil,
                url: URL(string: "https://canvas.upenn.edu/courses/\(course.id)/assignments/1")
            )
        }
        state.setCourse(Self.course.code, selected: true)
        state.setCourse(Self.hiddenCourse.code, selected: false)
        defer {
            for course in courses {
                state.restoreCourse(course.code)
                state.setCourse(course.code, selected: true)
                state.coursePreferences.setCanvasCourseID(course.code, nil)
            }
        }

        let harness = Harness(state: state)
        let seen = harness.seen
        state.announcementFetchForTesting = { [harness] _, _, _ in harness.canvasResponse }
        state.announcementExtractorForTesting = { _ in FindsOneTask(seen: seen, title: taskTitle, dueAt: taskDue) }
        try await body(harness)
    }

    private func edDoc(
        _ thread: String,
        reason: String = "announcement",
        title: String = "Verbal Assessment #2 Sign-Ups",
        body: String = "Sign-ups for Verbal Assessment #2 are open on the course site. Please sign up by Friday.",
        daysAgo: Double = 1,
        courseID: String = AnnouncementWatcherEdTests.course.id,
        courseCode: String = AnnouncementWatcherEdTests.course.code
    ) -> CourseDocument {
        AnnouncementEdRowsTests.edDocument(
            thread: thread, courseID: courseID, course: courseCode, reason: reason,
            body: body, daysAgo: daysAgo, title: title,
            url: URL(string: "https://edstem.org/us/courses/77/discussion/\(thread)"), now: Date()
        )
    }

    // MARK: A post becomes a find

    @Test("an Ed announcement with a sign-up sentence becomes a find with the Ed id, the class code and the Ed thread URL, extracted from the body and not the header")
    func edPostBecomesFind() async throws {
        try await withHarness { h in
            let document = edDoc("9400501")
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [document])
            // No Canvas announcements at all: the Ed post alone must be
            // enough to run the extraction.
            h.canvasResponse = []
            await h.state.syncAnnouncements(now: Date())

            let find = try #require(h.finds.first)
            #expect(h.finds.count == 1)
            #expect(find.sourceID == "announcement-ed:9401:9400501-0")
            #expect(find.source == .canvasAnnouncement)
            #expect(find.course == Self.course.code)
            #expect(find.url == URL(string: "https://edstem.org/us/courses/77/discussion/9400501"))
            #expect(find.title == "Sign up for a Verbal Assessment #2 slot")
            #expect(h.state.announcementItems.map(\.sourceID) == [find.sourceID])

            // What the extractor was given: Ed's id, the title, and a body
            // with no `[ed · …]` header line in it.
            let source = try #require(h.seen.all.first)
            #expect(source.announcementID == "ed:9401:9400501")
            #expect(source.courseCode == Self.course.code)
            #expect(source.title == "Verbal Assessment #2 Sign-Ups")
            #expect(!source.body.contains("[ed"))
            #expect(source.body.hasPrefix("Sign-ups for Verbal Assessment #2"))

            #expect(h.state.processedAnnouncementIDs == ["ed:9401:9400501"])
            // The sheet's "task found" tag joins on this id.
            #expect(AnnouncementRecord.announcementID(fromFindSourceID: find.sourceID) == document.id)
        }
    }

    @Test("a staff post is read as well, and a pinned one")
    func staffAndPinnedPostsAreRead() async throws {
        try await withHarness { h in
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [
                edDoc("9400511", reason: "staff post", title: "HW3 moved", body: "HW3 is now due Monday."),
                edDoc("9400512", reason: "pinned", title: "Office hours", body: "Bring your laptop to office hours."),
            ])
            await h.state.syncAnnouncements(now: Date())
            #expect(Set(h.seen.ids) == ["ed:9401:9400511", "ed:9401:9400512"])
        }
    }

    // MARK: Dedup and gates

    @Test("a processed Ed post is not extracted again")
    func processedEdPostIsNotReextracted() async throws {
        try await withHarness { h in
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400521")])
            await h.state.syncAnnouncements(now: Date())
            await h.state.syncAnnouncements(now: Date())
            #expect(h.seen.ids == ["ed:9401:9400521"])
            #expect(h.finds.count == 1)
        }
    }

    @Test("an informational Ed post is marked processed and makes no find, and never reaches the extractor")
    func informationalEdPostIsProcessedWithoutAFind() async throws {
        try await withHarness { h in
            #expect(HeuristicAnnouncementExtractor.isLikelyInformational(title: "Recording is up", body: "See Canvas."))
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [
                edDoc("9400531", title: "Recording is up", body: "See Canvas."),
            ])
            await h.state.syncAnnouncements(now: Date())
            #expect(h.seen.ids.isEmpty)
            #expect(h.finds.isEmpty)
            #expect(h.state.processedAnnouncementIDs == ["ed:9401:9400531"])
        }
    }

    @Test("a question, a student post, a private post, a headerless one, an image-only one, an old one, a hidden class's and a Canvas-kind document never reach the extractor")
    func nothingElseIsRead() async throws {
        try await withHarness { h in
            let now = Date()
            let headerless = CourseDocument(
                courseID: Self.course.id, course: Self.course.code, kind: .ed, sourceID: "9400546",
                title: "Anyone free to study?", url: nil,
                text: "Anyone free to study for the midterm? Sign up here.",
                updatedAt: now.addingTimeInterval(-Self.day), fetchedAt: now
            )
            let canvasKind = CourseDocument(
                courseID: Self.course.id, course: Self.course.code, kind: .announcement, sourceID: "9400548",
                title: "Canvas doc", url: nil,
                text: "[ed · announcement] Please sign up by Friday.",
                updatedAt: now.addingTimeInterval(-Self.day), fetchedAt: now
            )
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [
                edDoc("9400541", reason: "student or question"),
                edDoc("9400542", reason: "question"),
                edDoc("9400543", reason: "private"),
                edDoc("9400544", body: "- [image]"),
                edDoc("9400545", daysAgo: 20),
                headerless,
                edDoc("9400547", courseID: Self.hiddenCourse.id, courseCode: Self.hiddenCourse.code),
                canvasKind,
            ])
            await h.state.syncAnnouncements(now: now)
            #expect(h.seen.ids.isEmpty)
            #expect(h.finds.isEmpty)
            #expect(h.state.processedAnnouncementIDs.isEmpty)
        }
    }

    // MARK: Twins

    @Test("a Canvas announcement and an Ed post about the same task make one find, the Canvas one")
    func canvasAndEdTwinsMakeOneFind() async throws {
        try await withHarness { h in
            let now = Date()
            h.canvasResponse = [
                CanvasAnnouncement(
                    id: "9400601", courseID: Self.course.id,
                    title: "Verbal Assessment #2 Sign-Ups",
                    message: "Please sign up for a slot by Friday.",
                    postedAt: now.addingTimeInterval(-2 * Self.day),
                    url: URL(string: "https://canvas.upenn.edu/courses/9401/discussion_topics/9400601")
                ),
            ]
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400602")])
            await h.state.syncAnnouncements(now: now)

            #expect(h.finds.map(\.sourceID) == ["announcement-9400601-0"])
            // Both were read; the Ed one found a task and lost it as a twin,
            // which is still a completed parse.
            #expect(Set(h.seen.ids) == ["9400601", "ed:9401:9400602"])
            #expect(h.state.processedAnnouncementIDs == ["9400601", "ed:9401:9400602"])
        }
    }

    @Test("an Ed post that restates a find made on an earlier sync is dropped too")
    func edTwinOfAnEarlierFindIsDropped() async throws {
        try await withHarness { h in
            let now = Date()
            h.canvasResponse = [
                CanvasAnnouncement(
                    id: "9400611", courseID: Self.course.id,
                    title: "Verbal Assessment #2 Sign-Ups",
                    message: "Please sign up for a slot by Friday.",
                    postedAt: now.addingTimeInterval(-2 * Self.day), url: nil
                ),
            ]
            await h.state.syncAnnouncements(now: now)
            #expect(h.finds.map(\.sourceID) == ["announcement-9400611-0"])

            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400612")])
            await h.state.syncAnnouncements(now: now)
            #expect(h.finds.map(\.sourceID) == ["announcement-9400611-0"])
            #expect(h.state.processedAnnouncementIDs.contains("ed:9401:9400612"))
        }
    }

    // MARK: What the last run says about itself

    @Test("after a run with one Ed post the summary reads the counts, behind the time and the extractor")
    func summaryAfterAnEdFind() async throws {
        try await withHarness { h in
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400701")])
            let now = Date()
            await h.state.syncAnnouncements(now: now)

            let summary = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(summary.hasSuffix("ok \u{00B7} canvas 0 \u{00B7} ed 1 \u{00B7} eligible 1 \u{00B7} finds 1 \u{00B7} errors 0 \u{00B7} processed 1"))
            #expect(summary.hasPrefix(AppState.diagnosticStamp(now) + " \u{00B7} extractor injected \u{00B7} "))
            // Counts and words only: nothing of the post got in.
            #expect(!summary.contains("Verbal"))
            #expect(!summary.contains("9400701"))
            #expect(!summary.contains("http"))
        }
    }

    @Test("a second run with nothing new says so, with the two fetch counts")
    func summaryWhenNothingIsNew() async throws {
        try await withHarness { h in
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400711")])
            await h.state.syncAnnouncements(now: Date())
            await h.state.syncAnnouncements(now: Date())
            let summary = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(summary.hasSuffix("nothing new \u{00B7} canvas 0 \u{00B7} ed 1"))
        }
    }

    @Test("a fetch that throws is recorded by its error kind alone, and nothing is extracted")
    func summaryWhenTheFetchThrows() async throws {
        try await withHarness { h in
            h.state.announcementFetchForTesting = { _, _, _ in throw URLError(.notConnectedToInternet) }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400721")])
            await h.state.syncAnnouncements(now: Date())

            let summary = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(summary.hasSuffix("canvas fetch failed: URLError -1009"))
            #expect(h.seen.ids.isEmpty)
        }
    }

    private struct ThrowsError: AnnouncementAssignmentExtractor {
        let error: any Error
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            throw error
        }
    }

    @Test("a failing extractor adds the first error's kind after processed, and a clean run adds nothing")
    func summaryNamesTheFirstExtractorError() async throws {
        try await withHarness { h in
            h.state.announcementExtractorForTesting = { _ in ThrowsError(error: BackendError.http(502)) }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400731")])
            await h.state.syncAnnouncements(now: Date())
            let failed = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(failed.hasSuffix("errors 1 \u{00B7} processed 0 \u{00B7} first error: http 502"))
        }
        try await withHarness { h in
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400732")])
            await h.state.syncAnnouncements(now: Date())
            let clean = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(clean.hasSuffix("errors 0 \u{00B7} processed 1"))
            #expect(!clean.contains("first error"))
        }
    }

    @Test("extractor error kinds: backend cases by name, decoding with its capped detail only when given")
    func extractorErrorKinds() {
        func kind(_ e: Error, _ d: String? = nil) -> String {
            AppState.extractorErrorKindForSummary(e, decodingDetail: d)
        }
        #expect(kind(BackendError.quotaExceeded(resetAt: nil)) == "quota")
        #expect(kind(BackendError.unauthorized) == "unauthorized")
        #expect(kind(BackendError.transport) == "transport")
        #expect(kind(BackendError.notConfigured) == "notConfigured")
        #expect(kind(URLError(.timedOut)) == "URLError -1001")
        #expect(kind(BackendError.decoding) == "decoding")
        #expect(kind(BackendError.decoding, "extract: Unrecognized backend date 2026-10-22") == "decoding (extract: Unrecognized backend date 2026-10-22)")
        #expect(kind(BackendError.http(500), "ignored") == "http 500")
        let long = String(repeating: "a", count: 500)
        #expect(kind(BackendError.decoding, long).count == "decoding ()".count + 200)
    }

    // MARK: A failing extractor must not burn the shared quota forever

    /// Records the call, then throws.
    private struct RecordsThenThrows: AnnouncementAssignmentExtractor {
        let seen: Seen
        let error: any Error
        func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
            seen.record(announcement)
            throw error
        }
    }

    private func attempts() -> [String: Int] {
        UserDefaults.lhf.dictionary(forKey: Self.attemptsKey) as? [String: Int] ?? [:]
    }

    @Test("an id that throws on three runs is processed on the third with no find, and the summary says it gave up")
    func threeFailuresGiveUp() async throws {
        try await withHarness { h in
            let seen = h.seen
            h.state.announcementExtractorForTesting = { _ in RecordsThenThrows(seen: seen, error: BackendError.http(502)) }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400801")])
            let t0 = Date()
            // Two hours apart so the back-off each failed run sets has lapsed.
            await h.state.syncAnnouncements(now: t0)
            #expect(attempts()["ed:9401:9400801"] == 1)
            #expect(h.state.processedAnnouncementIDs.isEmpty)
            await h.state.syncAnnouncements(now: t0.addingTimeInterval(2 * 3600))
            #expect(attempts()["ed:9401:9400801"] == 2)
            #expect(h.state.processedAnnouncementIDs.isEmpty)
            let second = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(!second.contains("gave up"))

            await h.state.syncAnnouncements(now: t0.addingTimeInterval(4 * 3600))
            #expect(h.state.processedAnnouncementIDs.contains("ed:9401:9400801"))
            #expect(attempts().isEmpty)
            #expect(h.finds.isEmpty)
            #expect(seen.ids.count == 3)
            let third = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(third.hasSuffix("errors 1 \u{00B7} processed 1 \u{00B7} first error: http 502 \u{00B7} gave up 1"))
        }
    }

    @Test("an id that throws twice and then succeeds makes its find and leaves no counter behind")
    func twoFailuresThenSuccess() async throws {
        try await withHarness { h in
            let seen = h.seen
            h.state.announcementExtractorForTesting = { _ in RecordsThenThrows(seen: seen, error: BackendError.transport) }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400811")])
            let t0 = Date()
            await h.state.syncAnnouncements(now: t0)
            await h.state.syncAnnouncements(now: t0.addingTimeInterval(2 * 3600))
            #expect(attempts()["ed:9401:9400811"] == 2)

            h.state.announcementExtractorForTesting = { _ in
                FindsOneTask(seen: seen, title: "Sign up for a Verbal Assessment #2 slot", dueAt: nil)
            }
            await h.state.syncAnnouncements(now: t0.addingTimeInterval(4 * 3600))
            #expect(h.finds.count == 1)
            #expect(h.state.processedAnnouncementIDs.contains("ed:9401:9400811"))
            #expect(attempts().isEmpty)
            let summary = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(!summary.contains("gave up"))
        }
    }

    @Test("a quota refusal stops the run: the second post is never sent, nothing is processed, no counter moves, no back-off is set")
    func quotaStopsTheRun() async throws {
        try await withHarness { h in
            let seen = h.seen
            h.state.announcementExtractorForTesting = { _ in
                RecordsThenThrows(seen: seen, error: BackendError.quotaExceeded(resetAt: nil))
            }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400821"), edDoc("9400822")])
            await h.state.syncAnnouncements(now: Date())

            #expect(seen.ids.count == 1)
            #expect(h.state.processedAnnouncementIDs.isEmpty)
            #expect(attempts().isEmpty)
            #expect(UserDefaults.lhf.object(forKey: Self.backoffKey) == nil)
            let summary = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(summary.hasSuffix("errors 1 \u{00B7} processed 0 \u{00B7} first error: quota"))
        }
    }

    @Test("after a run where every extraction failed, a run inside the hour skips with the back-off line and calls nothing, and one after the hour proceeds and clears it")
    func backoffAfterAnAllFailedRun() async throws {
        try await withHarness { h in
            let seen = h.seen
            h.state.announcementExtractorForTesting = { _ in RecordsThenThrows(seen: seen, error: BackendError.http(500)) }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400831"), edDoc("9400832")])
            let t0 = Date()
            await h.state.syncAnnouncements(now: t0)
            #expect(seen.ids.count == 2)
            #expect(UserDefaults.lhf.object(forKey: Self.backoffKey) != nil)

            let until = t0.addingTimeInterval(AppState.announcementExtractionBackoff)
            await h.state.syncAnnouncements(now: t0.addingTimeInterval(30 * 60))
            #expect(seen.ids.count == 2)
            let skipped = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(skipped.hasSuffix("skipped: extraction backoff until \(AppState.backoffClockStamp(until))"))
            // A skip is not a failed attempt.
            #expect(attempts().values.allSatisfy { $0 == 1 })

            h.state.announcementExtractorForTesting = { _ in
                FindsOneTask(seen: seen, title: "Sign up for a Verbal Assessment #2 slot", dueAt: nil)
            }
            await h.state.syncAnnouncements(now: t0.addingTimeInterval(61 * 60))
            #expect(seen.ids.count == 4)
            #expect(UserDefaults.lhf.object(forKey: Self.backoffKey) == nil)
            #expect(h.state.processedAnnouncementIDs.count == 2)
        }
    }

    @Test("a run where only some extractions failed sets no back-off")
    func partialFailureSetsNoBackoff() async throws {
        try await withHarness { h in
            let seen = h.seen
            h.state.announcementExtractorForTesting = { announcement in
                if announcement.id.hasSuffix("9400841") {
                    return RecordsThenThrows(seen: seen, error: BackendError.http(500))
                }
                return FindsOneTask(seen: seen, title: "Sign up for a Verbal Assessment #2 slot", dueAt: nil)
            }
            h.state.courseKnowledge = CourseKnowledgeBase(documents: [edDoc("9400841"), edDoc("9400842")])
            await h.state.syncAnnouncements(now: Date())
            #expect(seen.ids.count == 2)
            #expect(UserDefaults.lhf.object(forKey: Self.backoffKey) == nil)
            #expect(h.state.processedAnnouncementIDs.count == 1)
        }
    }

    @Test("a run with no selected course records why it stopped")
    func summaryWhenNoCourseIsSelected() async throws {
        try await withHarness { h in
            h.state.setCourse(Self.course.code, selected: false)
            await h.state.syncAnnouncements(now: Date())
            let summary = try #require(h.state.lastAnnouncementSyncSummary)
            #expect(summary.hasSuffix("skipped: no selected courses"))
        }
    }
}

/// The pure parts of the two sync summaries (`AppState.diagnosticStamp`,
/// `errorKindForSummary`, `scrubbedForSummary`, `courseKnowledgeSkipSummary`).
/// None touches `UserDefaults`.
@Suite("Sync summaries")
struct SyncSummaryFormatTests {
    @Test("the stamp is the renewal summary's format, in the zone given")
    func stampFormat() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = AppState.diagnosticStamp(date, timeZone: utc)
        #expect(stamp == "2027-01-15 08:00")
        let renewal = AppState.renewalSummary(kind: .renewed, at: date, context: .foreground, timeZone: utc)
        #expect(renewal.contains(stamp))
    }

    @Test("an error is reduced to a kind: a status, a URLError code or a type name, never its text")
    func errorKinds() {
        #expect(AppState.errorKindForSummary(URLError(.timedOut)) == "URLError -1001")
        let url = URL(string: "https://canvas.upenn.edu/api/v1/secret?token=abc")!
        #expect(AppState.errorKindForSummary(CanvasAnnouncementsClient.Error.http(status: 503, url: url)) == "http 503")
        #expect(AppState.errorKindForSummary(CanvasAnnouncementsClient.Error.sessionExpired) == "sessionExpired")
    }

    @Test("anything URL-shaped is scrubbed from persisted text, and long text is cut")
    func scrubbing() {
        #expect(AppState.scrubbedForSummary("ed launch ended at https://x.edu/a?b=c today") == "ed launch ended at <url> today")
        #expect(AppState.scrubbedForSummary("connected: CIS 2400") == "connected: CIS 2400")
        #expect(AppState.scrubbedForSummary(String(repeating: "a", count: 300)).count == 123)
    }

    @Test("a skip keeps the last real run's line behind it, and a skip after a skip does not stack")
    func skipKeepsTheLastRun() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = AppState.diagnosticStamp(date)
        let run = "2027-01-15 07:00 \u{00B7} ok \u{00B7} courses 3"

        let first = AppState.courseKnowledgeSkipSummary(previous: run, at: date, reason: "not stale")
        #expect(first == "\(stamp) \u{00B7} skipped: not stale | last run: \(run)")
        let second = AppState.courseKnowledgeSkipSummary(previous: first, at: date, reason: "already syncing")
        #expect(second == "\(stamp) \u{00B7} skipped: already syncing | last run: \(run)")

        let bare = AppState.courseKnowledgeSkipSummary(previous: nil, at: date, reason: "not stale")
        #expect(bare == "\(stamp) \u{00B7} skipped: not stale")
        #expect(AppState.courseKnowledgeSkipSummary(previous: bare, at: date, reason: "not stale") == bare)
    }
}
