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

    // MARK: - Item 5: ledger partition guarantee + dashboard visibility

    @Test("upserted .canvasAnnouncement rows appear in the dashboard buckets and survive a .canvas-source reconcile")
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
            #expect(dashboardItems.contains { $0.title == "Bring a signed permission form" })

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
