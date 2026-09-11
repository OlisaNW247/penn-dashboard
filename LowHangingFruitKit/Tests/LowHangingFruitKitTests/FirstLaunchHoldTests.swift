import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for `AppState.isCanvasSubmissionVerified`, the pure rule behind
/// the first-launch submission hold: on a fresh install the dashboard's first
/// frame is built from the Canvas ICS feed alone (which knows nothing about
/// submission state), while Grade Watcher's per-course grade fetch — the
/// thing that actually knows whether an item was turned in — starts
/// afterwards and finishes one course at a time. An overdue Canvas item whose
/// course has never been checked must be held out of "overdue" rather than
/// shown as owed, or a brand-new student's first impression is a page of
/// work they may have already submitted.
@MainActor
@Suite("First-launch Canvas submission hold")
struct FirstLaunchHoldTests {
    private let launch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("unverified when nothing has checked this course and the hold window hasn't elapsed")
    func unverifiedWithinWindow() {
        #expect(!AppState.isCanvasSubmissionVerified(
            course: "CIS 1200",
            siteIDs: ["101"],
            checkedSiteIDs: [],
            observedCourses: [],
            gradeWatcherUsable: true,
            launchedAt: launch,
            now: launch.addingTimeInterval(30)
        ))
    }

    @Test("verified once this launch's grade refresh has an outcome for one of the course's sites")
    func verifiedByCheckedSite() {
        // Even an error outcome counts — Grade Watcher answered "did we
        // check", and a failing fetch must not hold an item hostage forever
        // (that's what the time-based valve is for).
        #expect(AppState.isCanvasSubmissionVerified(
            course: "CIS 1200",
            siteIDs: ["101", "202"],
            checkedSiteIDs: ["202"],
            observedCourses: [],
            gradeWatcherUsable: true,
            launchedAt: launch,
            now: launch.addingTimeInterval(30)
        ))
    }

    @Test("verified when the ledger recorded a Canvas submission observation for this course on a previous launch")
    func verifiedByLedgerHistory() {
        #expect(AppState.isCanvasSubmissionVerified(
            course: "CIS 1200",
            siteIDs: ["101"],
            checkedSiteIDs: [],
            observedCourses: ["CIS 1200"],
            gradeWatcherUsable: true,
            launchedAt: launch,
            now: launch.addingTimeInterval(30)
        ))
    }

    @Test("verified once the safety-valve window has elapsed, even with nothing checked")
    func verifiedAfterWindow() {
        #expect(!AppState.isCanvasSubmissionVerified(
            course: "CIS 1200",
            siteIDs: ["101"],
            checkedSiteIDs: [],
            observedCourses: [],
            gradeWatcherUsable: true,
            launchedAt: launch,
            now: launch.addingTimeInterval(5 * 60),
            holdWindow: 5 * 60
        ))
        #expect(AppState.isCanvasSubmissionVerified(
            course: "CIS 1200",
            siteIDs: ["101"],
            checkedSiteIDs: [],
            observedCourses: [],
            gradeWatcherUsable: true,
            launchedAt: launch,
            now: launch.addingTimeInterval(5 * 60 + 1),
            holdWindow: 5 * 60
        ))
    }

    @Test("verified immediately when Grade Watcher can never run at all (e.g. a link-only Canvas connection)")
    func verifiedWhenGradeWatcherUnusable() {
        // Holding forever here would be a worse failure than the guess this
        // whole feature exists to avoid — a course that can never be
        // verified must never be held in the first place.
        #expect(AppState.isCanvasSubmissionVerified(
            course: "CIS 1200",
            siteIDs: ["101"],
            checkedSiteIDs: [],
            observedCourses: [],
            gradeWatcherUsable: false,
            launchedAt: launch,
            now: launch.addingTimeInterval(1)
        ))
    }

    @Test("a course with no known Canvas site ids is still governed by the same rule, not vacuously verified")
    func noSiteIDsStillHeldWithinWindow() {
        #expect(!AppState.isCanvasSubmissionVerified(
            course: "CIS 1200",
            siteIDs: [],
            checkedSiteIDs: ["some-other-course-site"],
            observedCourses: [],
            gradeWatcherUsable: true,
            launchedAt: launch,
            now: launch.addingTimeInterval(30)
        ))
    }
}
