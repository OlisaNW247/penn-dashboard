import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Preview mode is the App Store reviewer's only way through the app — Penn
/// SSO can't be passed from Apple's side. These pin down the states a reviewer
/// actually lands in, because a broken demo reads as a broken app.
///
/// `AppState` persists into the process-wide `UserDefaults`, so every test here
/// restores what it touched — see the note in `GradeWatcherCourseResolutionTests`.
@MainActor
@Suite("Preview mode")
struct PreviewModeTests {

    private func withPreviewMode(_ body: (AppState) -> Void) {
        let state = AppState()
        let wasPreview = state.isPreviewMode
        state.enterPreviewMode()
        defer {
            if !wasPreview {
                state.restartOnboarding()
                UserDefaults.lhf.set(false, forKey: "isPreviewMode")
            }
        }
        body(state)
    }

    /// The regression this exists for: sample assignments carry no Canvas
    /// URLs, so no course id ever resolved and Grade Watcher rendered
    /// "Can't reach Canvas for your classes" — with a Reconnect button that
    /// ejected the reviewer into the login they can't complete.
    @Test("preview mode resolves courses for Grade Watcher")
    func coursesResolve() {
        withPreviewMode { state in
            let courses = state.selectedCanvasCourseIDs()
            #expect(!courses.isEmpty)
            #expect(courses.keys.contains("900001"))
        }
    }

    @Test("preview mode seeds real grade snapshots, so the report runs its actual code path")
    func snapshotsSeeded() {
        withPreviewMode { state in
            #expect(state.gradeWatcher.snapshots.count == SampleData.gradeSnapshots().count)
            #expect(state.gradeWatcher.error == nil)
            #expect(state.gradeWatcher.lastRefreshed != nil)
        }
    }

    @Test("a refresh in preview mode never sets the 'no Canvas session' banner")
    func refreshStaysQuiet() async {
        let state = AppState()
        let wasPreview = state.isPreviewMode
        state.enterPreviewMode()
        defer {
            if !wasPreview {
                state.restartOnboarding()
                UserDefaults.lhf.set(false, forKey: "isPreviewMode")
            }
        }

        await state.refreshGradeWatcher(cookies: [])
        #expect(state.gradeWatcher.error == nil)
        #expect(state.gradeWatcher.isSessionExpired == false)
        #expect(!state.gradeWatcher.snapshots.isEmpty)
    }

    @Test("every fixture course computes a grade and a projection")
    func fixturesProduceGrades() {
        withPreviewMode { state in
            let store = state.gradeWatcher
            for courseID in SampleData.previewCourseIDsByID.keys {
                let breakdown = store.breakdown(courseID: courseID)
                #expect(breakdown != nil, "no breakdown for \(courseID)")
                #expect(breakdown?.currentPercent != nil, "no grade for \(courseID)")
                #expect(store.projection(courseID: courseID) != nil, "no projection for \(courseID)")
            }
        }
    }

    /// The term summary only appears with 2+ graded classes; the fixtures must
    /// clear that bar or the demo's opening number is missing.
    @Test("fixtures support the term GPA summary")
    func termSummaryHasEnoughCourses() {
        withPreviewMode { state in
            let graded = SampleData.previewCourseIDsByID.keys.compactMap {
                state.gradeWatcher.breakdown(courseID: $0)?.currentPercent
            }
            #expect(graded.count >= 2)
        }
    }

    @Test("preview course ids are never persisted into the real course cache")
    func previewIDsDoNotLeak() {
        withPreviewMode { state in
            // The fixtures are served in memory; writing them to
            // `canvasCourseIDsByCode` would outlive the demo and later point a
            // real refresh at course ids that don't exist on Canvas.
            #expect(state.canvasCourseIDsByCode["CIS 1210"] != "900001")
        }
    }
}
