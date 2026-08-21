import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Pins the availability rule behind Grade Watcher's entry points
/// (`AppState.canUseGradeWatcher`): a Canvas connection made by pasting a
/// calendar feed link has no cookie session and must never be offered a
/// feature that can only fail, while preview/fixture mode and an
/// expired-but-once-real session both stay available — see
/// `canUseGradeWatcher`'s doc comment for why each of those is deliberate.
///
/// This suite used to also cover the calendar-link-only and expired-session
/// cases above, but both of those touch `SessionCookieStore`'s Keychain
/// state for the `.canvas` service, which is process-wide. Being their own
/// `.serialized` suite only serialized them against each other — Swift
/// Testing runs distinct suites in parallel by default, so they still raced
/// against `SessionCookieStoreTests`'s own `.canvas` tests over the same
/// Keychain item. That residual cross-suite race has now been fixed by
/// folding those two tests into `SessionCookieStoreTests`'s `.serialized`
/// suite instead of keeping a second one alive — see that file's doc
/// comment. The remaining test here, `previewModeCanUseGradeWatcher`,
/// touches no Keychain state at all (preview mode has no cookie session to
/// race over), so it has nothing to serialize against and is safe to keep
/// on its own, unserialized.
///
/// `AppState` persists into the process-wide `UserDefaults`, so the test
/// below restores what it touched — see the note in `PreviewModeTests` and
/// `SessionCookieStoreTests`.
@MainActor
@Suite("Grade Watcher availability")
struct GradeWatcherAvailabilityTests {

    /// Same in-memory-store injection as `IntroFlowTests`, so this suite
    /// can't contend with a real on-disk ledger from a machine that has
    /// actually run the app.
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    @Test("preview/fixture mode can always use Grade Watcher")
    func previewModeCanUseGradeWatcher() {
        let state = makeState()
        let wasPreview = state.isPreviewMode
        state.enterPreviewMode()
        defer {
            if !wasPreview {
                state.restartOnboarding()
                UserDefaults.lhf.set(false, forKey: "isPreviewMode")
            }
        }

        #expect(state.isUsingFixtureData)
        #expect(state.canUseGradeWatcher)
    }
}
