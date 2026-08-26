import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Settings → "Sync between my devices" (docs/LAPTOP_INTEGRATION_PLAN.md
/// Tier 2). `UserDefaults.lhf` is process-wide, so every test here backs up
/// and restores the exact key it touches — the same discipline
/// `CourseContentDecisionStoreTests` and `PreviewModeTests` use for their own
/// keys. `.serialized` for the same reason as `CourseContentDecisionStoreTests`:
/// tests racing a backup/restore of this one shared key against each other
/// under Swift Testing's default parallel execution could lose each other's
/// writes.
@MainActor
@Suite("Cloud sync toggle", .serialized)
struct CloudSyncToggleTests {
    /// `AppState.cloudSyncEnabledKey` is `private`; hardcoded here the same
    /// way `CourseContentDecisionStoreTests` hardcodes
    /// `"courseContentDecisionsV1"` rather than reaching into a private
    /// implementation detail.
    private static let key = "cloudSyncEnabledV1"

    private func withCleanFlag(_ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let saved = defaults.object(forKey: Self.key)
        defer {
            if let saved {
                defaults.set(saved, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
        defaults.removeObject(forKey: Self.key)
        body()
    }

    @Test("default is off when nothing is persisted")
    func defaultsToOff() {
        withCleanFlag {
            let state = AppState()
            #expect(state.cloudSyncEnabled == false)
            #expect(state.cloudSyncEnabledAtLaunch == false)
        }
    }

    @Test("setCloudSyncEnabled persists and republishes immediately")
    func toggleRoundTrips() {
        withCleanFlag {
            let state = AppState()
            #expect(state.cloudSyncEnabled == false)

            state.setCloudSyncEnabled(true)
            #expect(state.cloudSyncEnabled == true)
            #expect(UserDefaults.lhf.bool(forKey: Self.key) == true)

            state.setCloudSyncEnabled(false)
            #expect(state.cloudSyncEnabled == false)
            #expect(UserDefaults.lhf.bool(forKey: Self.key) == false)
        }
    }

    @Test("toggling produces a mismatch against the launch value, which Settings' status line depends on")
    func toggledDiffersFromLaunchValue() {
        withCleanFlag {
            let state = AppState()
            // Nothing was toggled yet this session, so the live value and
            // the launch snapshot must agree.
            #expect(state.cloudSyncEnabled == state.cloudSyncEnabledAtLaunch)

            state.setCloudSyncEnabled(true)
            // `cloudSyncEnabledAtLaunch` is a `let` — it must NOT move just
            // because the toggle did, or Settings' "takes effect after you
            // quit and reopen" line could never fire.
            #expect(state.cloudSyncEnabledAtLaunch == false)
            #expect(state.cloudSyncEnabled != state.cloudSyncEnabledAtLaunch)
        }
    }

    @Test("a fresh AppState reads the persisted flag at init; the in-memory ledger stays in-memory regardless")
    func makeDefaultReadsPersistedFlagUnderTestRunnerGuard() {
        withCleanFlag {
            UserDefaults.lhf.set(true, forKey: Self.key)

            let state = AppState()
            // The flag itself round-trips into AppState's published state...
            #expect(state.cloudSyncEnabled == true)
            #expect(state.cloudSyncEnabledAtLaunch == true)
            // ...but `AssignmentStore.makeDefault(syncEnabled:)` still takes
            // the in-memory, non-persistent path: `SharedDefaults
            // .isTestRunner` is checked before the `syncEnabled` branch is
            // ever consulted (see `CloudReadyLedgerTests
            // .syncEnabledStillHermeticUnderTestRunner`), so `swift test`
            // never reaches a real CloudKit container even with the flag on.
            #expect(state.assignmentStore?.isPersistent == false)
            #expect(state.assignmentStore?.storageFailureReason == nil)
        }
    }

    @Test("CloudPrefsMirror is inert under the test-runner guard even when constructed enabled")
    func mirrorInertUnderTestRunnerGuard() {
        // This process IS `swift test`, so this must always hold — it's the
        // precondition the rest of this test (and `AppState`'s own mirror,
        // checked below) relies on.
        #expect(SharedDefaults.isTestRunner)

        let mirror = CloudPrefsMirror(enabled: true)
        // `isActive` is what every push/pull path in `CloudPrefsMirror`
        // checks FIRST. Asserting it directly — rather than trying to
        // observe whether a write reached the real
        // `NSUbiquitousKeyValueStore`, which isn't meaningfully reachable or
        // observable from this sandboxed `swift test` process — is the
        // honest thing this test can check: it confirms the guard that
        // keeps this class from ever touching iCloud under test, not that
        // iCloud itself stayed untouched.
        #expect(mirror.isActive == false)

        // Both entry points are documented no-ops when inactive, not a
        // crash and not a silent reach into iCloud.
        mirror.push(key: "hiddenCourseKeys")
        mirror.pushAll()
    }

    @Test("AppState's own cloudPrefsMirror is inert too, even with the flag persisted on")
    func appStateOwnedMirrorIsInert() {
        withCleanFlag {
            UserDefaults.lhf.set(true, forKey: Self.key)
            let state = AppState()
            #expect(state.cloudPrefsMirror.isActive == false)
        }
    }
}
