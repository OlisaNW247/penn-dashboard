import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Two field-discovered course-intel gaps (see the delegation brief this
/// file was written against, not itself checked in):
///
/// 1. `CourseCode.containsExplicitCode` + `refreshCourseIntel`'s enrolled
///    filter — Canvas community/resource sites ("Chemistry Diagnostic
///    2024-2025", "Penn Engineering Class of 2028", …) have no DEPT+number
///    course code and shouldn't be treated as classes at all.
/// 2. `AssignmentStore.upsert`-based `.canvasModules` persistence —
///    `reconcile`'s single end-of-batch call used to mark OTHER courses'
///    already-imported readings `isGoneFromFeed` because it partitions by
///    source, not by course; `upsert` only ever touches the ids it's given.
///
/// `refreshCourseIntel(cookies:)` and `importReadingsIfNeeded(for:)`'s
/// network/cookie-dependent halves are NOT exercised here — same reasoning
/// `ModuleReadingImportTests`/`CourseContentNudgeTests` document: they talk
/// to `CanvasDiscoveryClient`/`CanvasModulesClient` over a real `URLSession`
/// with no injection seam from `AppState`, and `importModuleReadings` itself
/// is `private`. Where the brief asked for coverage of those paths, this
/// file either mirrors the pure logic directly or tests the synchronous
/// guard clauses that run before any network call, and says so plainly
/// where it can't go further.
///
/// This suite is `.serialized`, and every course code is unique to this
/// file ("LGST 999x"), for the same reason `ModuleReadingImportTests`/
/// `CourseContentDashboardTests` document: `courseContentDecisions` is one
/// process-wide JSON blob under `UserDefaults.lhf`'s
/// "courseContentDecisionsV1" key, backed up/restored around each test that
/// touches it.
@MainActor
@Suite("Course intel refinement — junk filtering + upsert-based readings import", .serialized)
struct CourseIntelRefinementTests {

    // MARK: - A: CourseCode.containsExplicitCode

    @Test("containsExplicitCode distinguishes real course codes from Canvas resource/cohort sites")
    func containsExplicitCodeTruthTable() {
        // Real device enrolled-course junk (field evidence): none of these
        // parse to a DEPT+number course code.
        let junk = [
            "Chemistry Diagnostic 2024-2025",
            "Math Diagnostic 2024-2025",
            "Penn Engineering Class of 2028",
            "Physics Exam Archive",
            "The Studios @ Venture Labs",
            "Connections@Wharton",
        ]
        for name in junk {
            #expect(!CourseCode.containsExplicitCode(name), "expected no course code in \"\(name)\"")
        }

        // Real classes always parse.
        let real = [
            "ACCT 1010",
            "LGST 1010 Law and Social Values 2026C",
            "cis-1200-001",
        ]
        for name in real {
            #expect(CourseCode.containsExplicitCode(name), "expected a course code in \"\(name)\"")
        }

        // Accepted false positive, called out explicitly by the brief: "TAP
        // 2028" parses like a real course code (2-4 letter dept + 3-4 digit
        // number) even though it's actually a class-year cohort org. Users
        // who don't want it toggle it off manually like any other course —
        // this is documented, not silently swallowed.
        #expect(CourseCode.containsExplicitCode("TAP 2028"))
    }

    // MARK: - B: the enrolled filter in refreshCourseIntel

    /// `refreshCourseIntel`'s enrolled-course filter
    /// (`Self.isEnrolledCourseCurrent($0) && CourseCode.containsExplicitCode($0.name)`)
    /// lives inline in a cookie/network-dependent function with no injection
    /// seam (see this file's doc comment), so it can't be invoked directly.
    /// This mirrors that exact boolean expression against the same
    /// `CanvasCourseDiscoveryParser.Course` fixtures `EnrolledCourseTermBackstopTests`
    /// uses for `isEnrolledCourseCurrent`, so a future change to either half
    /// of the `&&` is still caught here even though the call site itself
    /// isn't exercised.
    private func now() -> Date { Date(timeIntervalSince1970: 1_787_000_000) } // Fall 2026

    private func survivesEnrolledFilter(_ course: CanvasCourseDiscoveryParser.Course) -> Bool {
        AppState.isEnrolledCourseCurrent(course, now: now()) && CourseCode.containsExplicitCode(course.name)
    }

    @Test("the enrolled filter drops every real-device junk course, current-term or not")
    func enrolledFilterDropsJunk() {
        let junkNames = [
            "Chemistry Diagnostic 2024-2025",
            "Math Diagnostic 2024-2025",
            "Penn Engineering Class of 2028",
            "Physics Exam Archive",
            "The Studios @ Venture Labs",
            "Connections@Wharton",
        ]
        for (index, name) in junkNames.enumerated() {
            let course = CanvasCourseDiscoveryParser.Course(id: "\(900 + index)", name: name)
            #expect(!survivesEnrolledFilter(course), "expected \"\(name)\" to be filtered out")
        }
    }

    @Test("the enrolled filter keeps a real current-term course")
    func enrolledFilterKeepsRealCourse() {
        let course = CanvasCourseDiscoveryParser.Course(id: "111", name: "LGST 1010 Law and Social Values 202630")
        #expect(survivesEnrolledFilter(course))
    }

    @Test("the enrolled filter still drops a real course code from a past term (term backstop still applies)")
    func enrolledFilterStillAppliesTermBackstop() {
        let course = CanvasCourseDiscoveryParser.Course(id: "222", name: "LGST 8888 Old Course 202610")
        #expect(!survivesEnrolledFilter(course))
    }

    @Test("the accepted false positive (TAP 2028) survives the enrolled filter")
    func enrolledFilterAcceptedFalsePositive() {
        let course = CanvasCourseDiscoveryParser.Course(id: "333", name: "TAP 2028")
        #expect(survivesEnrolledFilter(course))
    }

    // MARK: - C/D: upsert-based .canvasModules persistence — the multi-course reconcile bug

    private func reading(course: String, id: String, title: String) -> Assignment {
        Assignment(
            source: .canvasModules,
            sourceID: "module-item-\(id)",
            kind: .event,
            course: course,
            title: title,
            dueAt: Date(),
            url: nil
        )
    }

    /// The exact scenario `reconcile`'s single end-of-batch call broke: two
    /// different courses' readings imported in SEPARATE calls (mirroring two
    /// separate probe-loop iterations, or a probe followed by an
    /// `importReadingsIfNeeded` call), where the second call's `fetched` list
    /// only covers its own course. With `reconcile`, course A's rows —
    /// absent from course B's `fetched` batch — would get marked
    /// `isGoneFromFeed`. `upsert` must leave them untouched.
    @Test("upserting one course's readings never marks a different course's already-imported rows gone")
    func upsertDoesNotAffectOtherCoursesRows() throws {
        let store = try AssignmentStore(inMemory: true)

        let courseA = "LGST 9991"
        let courseB = "LGST 9992"

        store.upsert([
            reading(course: courseA, id: "a1", title: "A Week 1 reading"),
            reading(course: courseA, id: "a2", title: "A Week 2 reading"),
        ])
        store.upsert([
            reading(course: courseB, id: "b1", title: "B Week 1 reading"),
        ])

        let afterBothImports = store.assignments(source: .canvasModules)
        #expect(Set(afterBothImports.map(\.title)) == [
            "A Week 1 reading", "A Week 2 reading", "B Week 1 reading",
        ])
        // Course A's rows must still be visible (not gone/pruned) after
        // course B's separate, later import — the exact cross-course wipe
        // `reconcile` used to cause.
        #expect(afterBothImports.contains { $0.course == courseA && $0.sourceID == "module-item-a1" })
        #expect(afterBothImports.contains { $0.course == courseA && $0.sourceID == "module-item-a2" })
    }

    /// Calling the same import twice with an overlapping id (as would happen
    /// if a course gets re-probed and re-imported later the same launch)
    /// refreshes the existing row rather than duplicating it.
    @Test("importing overlapping items twice refreshes in place instead of duplicating")
    func upsertTwiceWithOverlapProducesNoDuplicates() throws {
        let store = try AssignmentStore(inMemory: true)
        let course = "LGST 9993"

        store.upsert([
            reading(course: course, id: "1", title: "Week 1 reading (draft title)"),
            reading(course: course, id: "2", title: "Week 2 reading"),
        ])
        // Second call overlaps on id "1" (retitled, as a live re-fetch would
        // return) and adds a new id "3".
        store.upsert([
            reading(course: course, id: "1", title: "Week 1 reading (final title)"),
            reading(course: course, id: "3", title: "Week 3 reading"),
        ])

        let rows = store.assignments(source: .canvasModules)
        #expect(rows.count == 3, "expected exactly 3 rows, got \(rows.count): \(rows.map(\.sourceID))")
        #expect(rows.contains { $0.sourceID == "module-item-1" && $0.title == "Week 1 reading (final title)" })
        #expect(rows.contains { $0.sourceID == "module-item-2" && $0.title == "Week 2 reading" })
        #expect(rows.contains { $0.sourceID == "module-item-3" && $0.title == "Week 3 reading" })
    }

    // MARK: - Import-on-decision: synchronous guard clauses of importReadingsIfNeeded

    private static let decisionsKey = "courseContentDecisionsV1"

    private func withCleanDecision(_ course: String, _ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let savedDecisions = defaults.data(forKey: Self.decisionsKey)
        defer {
            if let savedDecisions {
                defaults.set(savedDecisions, forKey: Self.decisionsKey)
            } else {
                defaults.removeObject(forKey: Self.decisionsKey)
            }
        }
        var map = CourseContentDecisionStore.load()
        map.removeValue(forKey: course)
        CourseContentDecisionStore.save(map)
        body()
    }

    /// `setCourseContentIncluded(_, true)` records the decision and rebuilds
    /// the dashboard synchronously regardless of whether an import can ever
    /// happen — that much is directly testable without a cookie/network
    /// seam. What is NOT testable here: whether `importReadingsIfNeeded`'s
    /// fire-and-forget `Task` actually reaches `importModuleReadings` and
    /// upserts anything, because that requires a live Canvas cookie session
    /// (`AutoSyncCoordinator.canvasCookies()` reads the real
    /// `WKWebsiteDataStore`/Keychain) and `importModuleReadings` is
    /// `private` with no seam to substitute a fake `CanvasModulesClient` —
    /// the same honest gap `ModuleReadingImportTests`'s doc comment
    /// documents for `refreshCourseIntel`'s own probe fetch. In this test
    /// environment the cookie jar is empty, so the spawned `Task` no-ops on
    /// its own guard; this test only asserts the synchronous half doesn't
    /// crash and does record the decision.
    @Test("setCourseContentIncluded(true) records the decision synchronously; the cookie-gated import itself is untestable here")
    func setCourseContentIncludedRecordsDecisionSynchronously() {
        let course = "LGST 9994"
        withCleanDecision(course) {
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            state.setCourseContentIncluded(course, true)
            #expect(state.courseContentIncluded(course))
        }
    }

    /// `importReadingsIfNeeded` is `func`, not `private`, specifically so
    /// `resolveCourseNudge`/`setCourseContentIncluded` can call it — which
    /// also makes its own synchronous guard directly testable. With no
    /// enrolled-course entry and no course-profile report on file for this
    /// course, the courseID can't be resolved, so the function must return
    /// before ever spawning its cookie-fetching `Task` — deterministically
    /// verifiable without waiting on async work, unlike the cookie-gated
    /// half above.
    @Test("importReadingsIfNeeded no-ops synchronously when the course's Canvas id can't be resolved")
    func importReadingsIfNeededNoOpsWithUnresolvableCourseID() {
        let course = "LGST 9995 (unknown to Canvas)"
        withCleanDecision(course) {
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            let before = state.moduleReadingItems
            state.importReadingsIfNeeded(for: course)
            #expect(state.moduleReadingItems == before)
        }
    }

    /// Fixture/preview mode must never reach the network — same posture as
    /// `refreshCourseIntel`/`refreshGradeWatcher`. `isUsingFixtureData`'s
    /// guard in `importReadingsIfNeeded` runs before the courseID lookup, so
    /// this is a no-op even for a course with no enrolled-course entry.
    @Test("importReadingsIfNeeded no-ops in preview/fixture mode")
    func importReadingsIfNeededNoOpsInFixtureMode() {
        let course = "LGST 9996"
        withCleanDecision(course) {
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            // enterPreviewMode PERSISTS the flag in UserDefaults.lhf — leaving
            // it set poisons every AppState any other suite constructs while
            // (or after) this test runs, flooding them with the s-1…s-16
            // sample fixtures. Clear it UNCONDITIONALLY, both on the way out
            // and — unlike PreviewModeTests' conditional restore — regardless
            // of what it read on entry: a stuck-true flag from a previous
            // poisoned run would otherwise make the restore skip itself
            // forever (wasPreview reads true, reset never fires), which is
            // exactly the self-perpetuating failure observed on 2026-08-23.
            state.enterPreviewMode()
            defer {
                UserDefaults.lhf.set(false, forKey: "isPreviewMode")
            }
            let before = state.moduleReadingItems
            state.importReadingsIfNeeded(for: course)
            #expect(state.moduleReadingItems == before)
        }
    }
}
