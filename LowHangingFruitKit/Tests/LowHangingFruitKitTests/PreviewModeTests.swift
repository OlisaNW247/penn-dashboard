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

    /// The regression this closes: every test above proves `enterPreviewMode()`
    /// does the right thing once called, and none of them noticed that nothing
    /// in the shipped UI ever called it — `git grep enterPreviewMode` had zero
    /// hits outside test targets, so no user, and no App Store reviewer
    /// following `docs/appstore/REVIEW_NOTES.md`, could reach the door at all.
    /// Views can't be driven headlessly here (no UI-testing target in this
    /// package), so this scans source text instead, the same seam
    /// `SharedDefaultsMigrationTests.uiSourcesUseTheSharedAccessor()` uses for
    /// an equivalent "is this actually wired up" question. It requires a call
    /// in BOTH `IntroView.swift` and `OnboardingView.swift`, not just one —
    /// see `c999c38`'s commit message for why one placement stranded a
    /// reviewer who tapped the intro's ordinary "Skip" button: that sets
    /// `hasSeenIntro` permanently and routes to `OnboardingView` forever, so
    /// a door only on the intro is a door that can vanish for good.
    @Test("the reviewer's preview door is called from both the intro and onboarding")
    func previewDoorIsWiredIntoShippedUI() throws {
        let sources = URL(fileURLWithPath: #filePath)      // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()                    // .../Tests/LowHangingFruitKitTests
            .deletingLastPathComponent()                    // .../Tests
            .deletingLastPathComponent()                    // .../LowHangingFruitKit
            .appendingPathComponent("Sources/LowHangingFruitUI")
        // A prebuilt test bundle run away from the checkout has nothing to scan.
        guard FileManager.default.fileExists(atPath: sources.path) else { return }

        for filename in ["IntroView.swift", "OnboardingView.swift"] {
            let file = sources.appendingPathComponent(filename)
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                text.contains("state.enterPreviewMode()"),
                "\(filename) has no reachable call to enterPreviewMode() — a reviewer landing here has no way past Penn SSO"
            )
        }
    }
}
