import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The intro panes are gated on their own `hasSeenIntro` flag rather than on
/// `hasCompletedOnboarding`, and these pin down why that distinction matters:
/// `restartOnboarding()` is what the Settings *reconnect* buttons call, so a
/// shared flag would replay the whole product pitch at someone who only wanted
/// to reconnect Canvas.
///
/// `AppState` persists into the process-wide `UserDefaults`, so every test here
/// restores what it touched — see the note in `PreviewModeTests`.
@MainActor
@Suite("Intro flow")
struct IntroFlowTests {

    private static let introKey = "hasSeenIntro"
    private static let onboardedKey = "hasCompletedOnboarding"
    private static let previewKey = "isPreviewMode"
    private static let touchedKeys = [introKey, onboardedKey, previewKey]

    /// Runs `body` against a known set of persisted flags, then puts the user's
    /// real values back. `seenIntro: nil` removes the key outright — the state
    /// an existing user upgrading into this build actually starts from.
    private func withFlags(
        onboarded: Bool = false,
        seenIntro: Bool? = false,
        _ body: () -> Void
    ) {
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

        defaults.set(onboarded, forKey: Self.onboardedKey)
        defaults.set(false, forKey: Self.previewKey)
        if let seenIntro {
            defaults.set(seenIntro, forKey: Self.introKey)
        } else {
            defaults.removeObject(forKey: Self.introKey)
        }

        body()
    }

    /// Every `AppState` here is built on its own in-memory ledger. The default
    /// (`AssignmentStore.makeDefault()`) is documented as falling back to an
    /// in-memory store under test, but that only holds when the App Group
    /// container is absent — on any machine that has actually run the app it
    /// resolves to the real on-disk store, and a suite full of `AppState()`
    /// then contends on one SQLite file. Injecting keeps these tests hermetic
    /// and fast; none of the flags under test involve the ledger at all.
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    @Test("a first run opens on the intro, not the connect checklist")
    func firstRunShowsIntro() {
        withFlags {
            let state = makeState()
            #expect(state.needsIntro)
            #expect(state.needsOnboarding)
        }
    }

    @Test("finishing or skipping the intro sticks, and hands off to the checklist")
    func completingIntroPersists() {
        withFlags {
            let state = makeState()
            state.completeIntro()

            #expect(!state.needsIntro)
            // Still onboarding — the intro hands off to the connect checklist
            // rather than standing in for it.
            #expect(state.needsOnboarding)
            // And it survives a relaunch.
            #expect(!makeState().needsIntro)
        }
    }

    /// The regression this suite exists for. `restartOnboarding()` deliberately
    /// clears `hasCompletedOnboarding` to send the user back to the connect
    /// checklist; it must leave `hasSeenIntro` alone.
    @Test("reconnecting from Settings never replays the intro")
    func reconnectSkipsIntro() {
        withFlags(onboarded: true, seenIntro: true) {
            let state = makeState()
            state.restartOnboarding()

            #expect(state.needsOnboarding)   // back to the checklist…
            #expect(!state.needsIntro)       // …but not through the pitch
            #expect(!makeState().needsIntro)
        }
    }

    /// Preview is entered from the intro's first pane, so it counts as having
    /// seen it — including for a reviewer who later switches to real Canvas.
    @Test("entering preview mode counts as having seen the intro")
    func previewMarksIntroSeen() {
        withFlags {
            let state = makeState()
            state.enterPreviewMode()
            #expect(!state.needsIntro)

            state.restartOnboarding()
            #expect(state.needsOnboarding)
            #expect(!state.needsIntro)
        }
    }

    /// Upgrade path: a user who onboarded before the intro shipped has no
    /// `hasSeenIntro` key at all. Without the backfill in `AppState.init`,
    /// their next Settings reconnect would drop them into a first-run pitch.
    @Test("a user who onboarded before the intro existed is never shown it")
    func existingUserIsBackfilled() {
        withFlags(onboarded: true, seenIntro: nil) {
            let state = makeState()
            #expect(!state.needsIntro)
            #expect(!state.needsOnboarding)

            state.restartOnboarding()
            #expect(state.needsOnboarding)
            #expect(!state.needsIntro)
        }
    }

    /// The backfill keys off onboarding specifically — a fresh install with no
    /// keys at all is still a first run and must see the intro.
    @Test("a fresh install with no stored flags still gets the intro")
    func freshInstallIsNotBackfilled() {
        withFlags(onboarded: false, seenIntro: nil) {
            let state = makeState()
            #expect(state.needsIntro)
            #expect(state.needsOnboarding)
        }
    }
}
