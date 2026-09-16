import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Pins `AppState.needsGradescopeConnection` and `.canvasIsLinkOnly`, the two
/// predicates behind `ContentView`'s "you're not fully connected" banner
/// (see that file's `connectionNoticeBanner`). Onboarding blocks the
/// dashboard until Canvas is connected, so "nothing connected at all" is not
/// a reachable state and isn't tested here — what these two properties exist
/// to catch is the pair of states that ARE reachable past onboarding:
/// Gradescope never having been connected (nothing requires it), and Canvas
/// having been connected by a pasted calendar link that carries no cookie
/// session.
///
/// The single most important case here is `needsGradescopeConnection`
/// staying false in preview/fixture mode: that mode is the one way through
/// this app for someone who can't pass Penn SSO — notably an App Store
/// reviewer — and it is not backed by a real Gradescope connection. Getting
/// the guard wrong would show a "connect your accounts" nag on the one
/// screen that's supposed to just work.
///
/// `AppState` persists into the process-wide `UserDefaults.lhf`, so every
/// test here restores what it touched — see the note in `IntroFlowTests` and
/// `PreviewModeTests`. `canvasIsLinkOnly`'s two cases below need no such
/// bookkeeping: `isCanvasConnected` is backed by `ICSFeedURLStore`'s Keychain
/// item, which no test in this file (or, so far, anywhere in the suite)
/// writes to, so a freshly constructed `AppState` starts with an empty
/// `canvasICSURL` for free. Deliberately not adding Keychain-writing
/// infrastructure here to manufacture the "Canvas connected by link" case
/// directly — the existing suites don't do that either, and `canvasIsLinkOnly
/// == isCanvasConnected && !canUseGradeWatcher` is already exercised on its
/// `canUseGradeWatcher` half by `GradeWatcherAvailabilityTests` and
/// `SessionCookieStoreTests`, so this file only needs to add the
/// `isCanvasConnected` half against states that don't need the Keychain.
@MainActor
@Suite("Connection notice")
struct ConnectionNoticeTests {

    private static let gradescopeConnectedKey = "gradescopeConnected"
    private static let onboardedKey = "hasCompletedOnboarding"
    private static let introKey = "hasSeenIntro"
    private static let previewKey = "isPreviewMode"
    private static let touchedKeys = [gradescopeConnectedKey, onboardedKey, introKey, previewKey]

    /// Same in-memory-store injection as `IntroFlowTests` and
    /// `GradeWatcherAvailabilityTests`, so this suite can't contend with a
    /// real on-disk ledger from a machine that has actually run the app.
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    /// Snapshots every `UserDefaults.lhf` key this suite (or the `AppState`
    /// methods it calls) can touch, runs `body`, then puts the real values
    /// back exactly as found — `nil` meaning "the key was absent," restored
    /// by removing it rather than writing some placeholder. Mirrors
    /// `IntroFlowTests.withFlags`.
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

    @Test("needsGradescopeConnection is true when Gradescope has never been connected")
    func gradescopeGapIsFlagged() {
        withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(false)

            #expect(!state.isUsingFixtureData)
            #expect(state.needsGradescopeConnection)
        }
    }

    @Test("needsGradescopeConnection stays false in preview/fixture mode, even unconnected")
    func gradescopeGapHiddenInPreview() {
        withRestoredDefaults {
            let state = makeState()
            state.setGradescopeConnected(false)
            state.enterPreviewMode()

            #expect(state.isUsingFixtureData)
            #expect(!state.isGradescopeConnected)
            #expect(!state.needsGradescopeConnection)
        }
    }

    @Test("canvasIsLinkOnly is false in preview/fixture mode")
    func canvasLinkOnlyHiddenInPreview() {
        withRestoredDefaults {
            let state = makeState()
            state.enterPreviewMode()

            #expect(state.isUsingFixtureData)
            #expect(state.canUseGradeWatcher)
            #expect(!state.canvasIsLinkOnly)
        }
    }

    @Test("canvasIsLinkOnly is false when Canvas isn't connected at all")
    func canvasLinkOnlyFalseWithNoCanvasConnection() {
        withRestoredDefaults {
            let state = makeState()

            #expect(!state.isCanvasConnected)
            #expect(!state.canvasIsLinkOnly)
        }
    }
}
