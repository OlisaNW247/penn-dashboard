import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Regression coverage for the "past enrollments pollute Grade Watcher"
/// bug: Canvas's `/courses` page lists past and future enrollments
/// alongside current ones (professors often never conclude a course), and
/// the fix has three layers — an HTML-section split in
/// `CanvasCourseDiscoveryParser`, a term-based backstop in `AppState`, and
/// a one-time prune of whatever the old over-inclusive merge already
/// wrote into `canvasCourseIDsByCode`. All fixtures here are synthetic.
@Suite("Canvas course discovery — current enrollment only")
struct CurrentEnrollmentSectionTests {
    private func fixture(current: String, past: String, future: String) -> String {
        """
        <div id="my_courses_table">
          \(current)
        </div>
        <h2>Past Enrollments</h2>
        <div id="past_enrollments_table">
          \(past)
        </div>
        <h2>Future Enrollments</h2>
        <div id="future_enrollments_table">
          \(future)
        </div>
        """
    }

    @Test("only the current-enrollment section's courses come back")
    func onlyCurrentSectionReturned() {
        let html = fixture(
            current: #"<a href="/courses/111">LGST 9999 Current Course 2026A</a>"#,
            past: #"<a href="/courses/222">LGST 8888 Past Course 2020A</a>"#,
            future: #"<a href="/courses/333">LGST 7777 Future Course 2099A</a>"#
        )

        let courses = CanvasCourseDiscoveryParser.currentEnrollmentLinks(from: html)

        #expect(courses.map(\.id) == ["111"])
        #expect(courses.first?.name == "LGST 9999 Current Course 2026A")
    }

    @Test("no past/future markers at all falls back to the whole page")
    func noMarkersReturnsEverything() {
        let html = #"""
        <div id="my_courses_table">
          <a href="/courses/111">LGST 9999 Current Course 2026A</a>
          <a href="/courses/222">LGST 8888 Other Course 2026A</a>
        </div>
        """#

        let sectioned = CanvasCourseDiscoveryParser.currentEnrollmentLinks(from: html)
        let unsectioned = CanvasCourseDiscoveryParser.courseLinks(from: html)

        #expect(Set(sectioned.map(\.id)) == Set(unsectioned.map(\.id)))
        #expect(sectioned.count == 2)
    }

    @Test("a past marker before any course link yields no courses")
    func pastMarkerBeforeAnyLinkReturnsEmpty() {
        let html = #"""
        <h2>Past Enrollments</h2>
        <div id="past_enrollments_table">
          <a href="/courses/222">LGST 8888 Past Course 2020A</a>
        </div>
        <div id="my_courses_table">
          <a href="/courses/111">LGST 9999 Current Course 2026A</a>
        </div>
        """#

        let courses = CanvasCourseDiscoveryParser.currentEnrollmentLinks(from: html)

        #expect(courses.isEmpty)
    }
}

/// `AppState.isEnrolledCourseCurrent` — the term-based backstop behind the
/// HTML-section split above. Pure and internal, so it's testable directly
/// without a live Canvas session.
@MainActor
@Suite("Enrolled-course term backstop")
struct EnrolledCourseTermBackstopTests {
    // A fixed reference "now" (Fall 2026) so this test is not sensitive to
    // the actual run date.
    private let now = Date(timeIntervalSince1970: 1_787_000_000) // 2026-08-17, Fall term

    @Test("a course whose parsed term is strictly before the current term is dropped")
    func parseablePastTermDropped() {
        // 202610 = Spring 2026, strictly before Fall 2026.
        let course = CanvasCourseDiscoveryParser.Course(id: "222", name: "LGST 8888 Old Course 202610")
        #expect(!AppState.isEnrolledCourseCurrent(course, now: now))
    }

    @Test("a course in the current term is kept")
    func currentTermKept() {
        // 202630 = Fall 2026, the current term as of `now`.
        let course = CanvasCourseDiscoveryParser.Course(id: "111", name: "LGST 9999 Current Course 202630")
        #expect(AppState.isEnrolledCourseCurrent(course, now: now))
    }

    @Test("a course with no parseable term passes through")
    func noTermKept() {
        let course = CanvasCourseDiscoveryParser.Course(id: "333", name: "LGST 7777 Undated Course")
        #expect(AppState.isEnrolledCourseCurrent(course, now: now))
    }
}

/// `AppState.pruneStaleCourseIDCacheEntries` — the one-time cleanup of
/// `canvasCourseIDsByCode` entries the earlier over-inclusive `/courses`
/// scrape already wrote to disk. Follows `CourseContentDashboardTests`'
/// established pattern: back up/restore the raw `UserDefaults.lhf` key
/// this state is keyed under, and use an in-memory ledger so nothing
/// leaks across tests or runs.
@MainActor
@Suite("Stale course-id cache pruning", .serialized)
struct StaleCourseIDCachePruneTests {
    private static let byCodeKey = "canvasCourseIDsByCode"

    /// Backs up the course-preferences blob (the canonical record since the
    /// v4 consolidation — the raw `canvasCourseIDsByCode` key is only a
    /// derived projection now, and `AppState` never reads it back), seeds a
    /// fresh store with the given ids so the next `AppState()` construction
    /// picks them up, runs `body`, then restores exactly what was on disk
    /// before — including the legacy projection key, which seeding rewrites.
    private func withSeededCourseIDCache(_ seed: [String: String], _ body: (AppState) -> Void) {
        let defaults = UserDefaults.lhf
        let savedBlob = defaults.data(forKey: CoursePreferencesStore.storageKey)
        let savedLegacy = defaults.dictionary(forKey: Self.byCodeKey)
        defer {
            if let savedBlob {
                defaults.set(savedBlob, forKey: CoursePreferencesStore.storageKey)
            } else {
                defaults.removeObject(forKey: CoursePreferencesStore.storageKey)
            }
            if let savedLegacy {
                defaults.set(savedLegacy, forKey: Self.byCodeKey)
            } else {
                defaults.removeObject(forKey: Self.byCodeKey)
            }
        }
        defaults.removeObject(forKey: CoursePreferencesStore.storageKey)
        let seedStore = CoursePreferencesStore()
        for (course, id) in seed {
            seedStore.setCanvasCourseID(course, id)
        }
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        body(state)
    }

    private func item(course: String) -> Assignment {
        Assignment(source: .canvas, sourceID: "\(course)-item", kind: .assignment,
                   course: course, title: "Item", dueAt: Date(), url: nil)
    }

    @Test("an entry with no feed/Gradescope items and absent from enrolled is removed")
    func staleEntryRemoved() {
        withSeededCourseIDCache(["LGST 0001": "901"]) { state in
            state.pruneStaleCourseIDCacheEntries(currentEnrolledKeys: [])
            #expect(state.canvasCourseIDsByCode["LGST 0001"] == nil)
        }
    }

    @Test("an entry backed by a live Canvas feed item survives")
    func entryWithFeedItemSurvives() {
        withSeededCourseIDCache(["LGST 0002": "902"]) { state in
            state.canvasItems = [item(course: "LGST 0002")]
            state.pruneStaleCourseIDCacheEntries(currentEnrolledKeys: [])
            #expect(state.canvasCourseIDsByCode["LGST 0002"] == "902")
        }
    }

    @Test("an entry backed by a Gradescope item survives")
    func entryWithGradescopeItemSurvives() {
        withSeededCourseIDCache(["LGST 0003": "903"]) { state in
            state.gradescopeItems = [item(course: "LGST 0003")]
            state.pruneStaleCourseIDCacheEntries(currentEnrolledKeys: [])
            #expect(state.canvasCourseIDsByCode["LGST 0003"] == "903")
        }
    }

    @Test("an entry present in this refresh's current enrolled courses survives")
    func entryInCurrentEnrolledSurvives() {
        withSeededCourseIDCache(["LGST 0004": "904"]) { state in
            state.pruneStaleCourseIDCacheEntries(currentEnrolledKeys: ["LGST 0004"])
            #expect(state.canvasCourseIDsByCode["LGST 0004"] == "904")
        }
    }
}
