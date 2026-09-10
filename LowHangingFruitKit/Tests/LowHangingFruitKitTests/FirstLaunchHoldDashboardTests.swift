import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// End-to-end coverage of the first-launch submission hold through a real
/// `AppState.rebuildDashboardItems()` pass — `FirstLaunchHoldTests` already
/// pins the pure rule (`AppState.isCanvasSubmissionVerified`) in isolation;
/// this suite checks that `rebuildDashboardItems` actually wires it in: an
/// overdue Canvas item whose course has never been checked lands in
/// `awaitingCanvasCheck` rather than `assignments`, and the ledger's own
/// submission-observation history (`AssignmentStore
/// .coursesWithCanvasSubmissionObservation()`) releases it.
///
/// `canUseGradeWatcher` needs to be true for the hold to engage at all (see
/// `isCanvasSubmissionVerified`'s "never held if it can never be verified"
/// escape hatch), which normally means a Canvas cookie session. Rather than
/// touching `SessionCookieStore`'s process-wide Keychain state — which is
/// exactly what `GradeWatcherAvailabilityTests`'s doc comment says used to
/// race `SessionCookieStoreTests` across suites — this suite instead seeds
/// the persisted `canvasSessionConfirmedDeadV1` flag directly through
/// `UserDefaults.lhf` (the same seam `AppState.init` itself reads) and calls
/// the already-internal `refreshCanvasSessionExpiredState()`, which ORs that
/// flag in alongside the Keychain check. `canvasSessionExpired` counts as
/// "usable" the same as a live cookie session does, per `canUseGradeWatcher`'s
/// own doc comment, so this reaches the real code path without any Keychain
/// I/O or cross-suite race.
///
/// The fixtures below deliberately carry no Canvas URL. A URL-bearing item
/// would also exercise `AppState.updateCanvasCourseIDCache`, which persists
/// into the process-wide `canvasCourseIDsByCode` — exactly the shared state
/// `CourseContentDashboardTests`' known flake (see that suite's doc comment)
/// already races over. Releasing the hold via the ledger's own observation
/// history instead of a resolved Canvas site id keeps this suite hermetic:
/// no Keychain, no shared `UserDefaults.lhf` course-id map, only an
/// in-memory `AssignmentStore`.
@MainActor
@Suite("First-launch Canvas submission hold — dashboard integration")
struct FirstLaunchHoldDashboardTests {
    private static let sessionDeadKey = "canvasSessionConfirmedDeadV1"
    private static let course = "LHFHOLD 0001"

    /// Backs up and restores `UserDefaults.lhf`'s `canvasSessionConfirmedDeadV1`
    /// flag, the same pattern `CourseContentDashboardTests.withCleanDecision`
    /// uses for its own key, then builds a fresh in-memory-ledger `AppState`
    /// (same injection every other `AppState`-constructing suite here uses)
    /// with Grade Watcher forced usable.
    private func withGradeWatcherUsable(_ body: (AppState) -> Void) {
        let defaults = UserDefaults.lhf
        let saved = defaults.object(forKey: Self.sessionDeadKey) as? Bool
        // `setCourse(_:selected:)` below writes a visibility entry into the
        // shared course-preferences blob; leaving it behind is exactly the
        // cross-suite pollution CLAUDE.md's shared-`UserDefaults` trap
        // describes, so the blob is restored byte-for-byte on the way out.
        let savedPreferences = defaults.data(forKey: CoursePreferencesStore.storageKey)
        defaults.set(true, forKey: Self.sessionDeadKey)
        defer {
            if let saved {
                defaults.set(saved, forKey: Self.sessionDeadKey)
            } else {
                defaults.removeObject(forKey: Self.sessionDeadKey)
            }
            if let savedPreferences {
                defaults.set(savedPreferences, forKey: CoursePreferencesStore.storageKey)
            } else {
                defaults.removeObject(forKey: CoursePreferencesStore.storageKey)
            }
        }
        let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
        state.refreshCanvasSessionExpiredState()
        #expect(state.canUseGradeWatcher, "test setup: this suite requires canUseGradeWatcher == true")
        body(state)
    }

    /// An overdue `.canvas` item with no URL — this suite's release path is
    /// the ledger's observation history, not a resolved Canvas site id, so
    /// nothing here needs one. The UID is shaped like a real plain Canvas
    /// assignment UID on purpose: `applySubmissionState` only stamps rows
    /// whose Canvas assignment id resolves, and with no URL that id can
    /// only come from the `event-assignment-<id>@…` UID fallback. A bare
    /// "hold-1" resolves nothing, is skipped by the stamp, and the release
    /// assertion below can never pass — which is how this test first failed.
    private func overdueItem(id: String = "event-assignment-777@canvas.upenn.edu") -> Assignment {
        Assignment(
            source: .canvas, sourceID: id, kind: .assignment,
            course: Self.course, title: "PSet 1",
            dueAt: Date().addingTimeInterval(-3600),
            url: nil
        )
    }

    @Test("an overdue Canvas item in a never-checked course is held, not shown as owed")
    func overdueItemIsHeldUntilVerified() {
        withGradeWatcherUsable { state in
            let item = overdueItem()
            state.canvasItems = [item]
            state.setCourse(Self.course, selected: true) // forces rebuildDashboardItems()

            #expect(state.awaitingCanvasCheck.contains { $0.id == item.id })
            #expect(!state.assignments.contains { $0.id == item.id })
            #expect(!state.laterAssignments.contains { $0.id == item.id })
        }
    }

    @Test("the ledger observing a Canvas submission answer for the course releases the hold")
    func ledgerObservationReleasesHold() {
        withGradeWatcherUsable { state in
            let item = overdueItem()
            state.canvasItems = [item]
            state.setCourse(Self.course, selected: true)
            #expect(state.awaitingCanvasCheck.contains { $0.id == item.id })

            // Puts the same item on the ledger, then gives Canvas a chance to
            // answer for it — mirroring what a real sync followed by a grade
            // refresh does (`applySubmissionState`'s `observedCanvasAssignmentIDs`
            // defaults to "every id counts as observed", so this stamps
            // `canvasSubmissionObservedAt` even though nothing was actually
            // submitted). `coursesWithCanvasSubmissionObservation()` is exactly
            // the durable signal `isCanvasSubmissionVerified` reads as
            // `observedCourses`.
            guard let store = state.assignmentStore else {
                Issue.record("test setup: expected an in-memory AssignmentStore")
                return
            }
            _ = store.reconcile([item], source: .canvas)
            store.applySubmissionState(submittedCanvasAssignmentIDs: [], scores: [:])
            #expect(store.coursesWithCanvasSubmissionObservation() == [Self.course])

            // Re-trigger the rebuild the same idempotent way.
            state.setCourse(Self.course, selected: true)

            #expect(!state.awaitingCanvasCheck.contains { $0.id == item.id })
            #expect(state.assignments.contains { $0.id == item.id })
        }
    }
}
