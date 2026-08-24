import Testing
import Foundation
@testable import LowHangingFruitKit

/// Coverage for the CloudKit-readiness plumbing added to `StoredAssignment`
/// and `AssignmentStore` (sync-off-by-default; see
/// `docs/LAPTOP_INTEGRATION_PLAN.md`, Tier 2).
///
/// **What this file cannot prove.** CloudKit itself — actually mirroring a row
/// into a private database, resolving a conflict there, receiving a push —
/// is unreachable from `swift test`: there is no code signing, no iCloud
/// account, and no entitlement in this environment (the same class of gap as
/// the SwiftData ledger migrations, which also need a device build; see
/// CLAUDE.md). Nothing here exercises `ModelConfiguration(cloudKitDatabase:)`
/// end to end, and nothing here should be read as having done so.
///
/// **What IS testable, and what these tests actually check:**
/// - That `StoredAssignment`'s schema — every non-optional stored property now
///   carrying a default — still *compiles* and behaves identically for real
///   rows. There is no parameterless/memberwise initializer for a Swift
///   Testing target to call directly (the designated `init` still requires
///   every field), so the true test of "every property has a default" is the
///   build itself: if any non-optional, non-defaulted stored property had
///   survived, `swift build`/`swift test` would still succeed (Swift doesn't
///   require @Model defaults) but CloudKit's own schema validation at
///   container-open time on a real device would reject it — that failure mode
///   is structurally outside this harness's reach. What this file adds
///   instead is a regression canary: three behaviors that depend on the
///   defaulted fields being harmless when unused (`isGoneFromFeed`,
///   `canvasSubmitted`, `gradescopeSubmitted`, `firstSeen`/`lastSeenInFeed`)
///   and on the designated `init` still overriding every default for a real
///   row, so a future accidental change to a default value would be caught
///   here even though the CloudKit rejection itself would not be.
/// - `AssignmentStore.makeDefault(syncEnabled:)`'s in-process branching: that
///   `syncEnabled: false` reproduces today's exact behavior, and that the
///   test-runner guard (`SharedDefaults.isTestRunner`) still wins over
///   `syncEnabled: true` — i.e. no test run ever touches a real App Group
///   ledger or attempts a CloudKit connection, sync flag or not.
@MainActor
struct CloudReadyLedgerTests {

    // MARK: Fixtures

    private func canvas(_ id: String, course: String = "CLOUD 1000", title: String = "HW", due: Date? = nil) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    // MARK: Schema-regression canary
    //
    // Three behaviors that only hold if (a) StoredAssignment's designated
    // init still assigns every property explicitly for a real row, and (b)
    // the CloudKit-compliance defaults added alongside it stayed neutral
    // (empty string / false / epoch) rather than something that could leak
    // into a real read. None of this exercises CloudKit — it is a guard
    // against the defaults change itself silently altering ledger behavior.

    @Test("reconcile still inserts and round-trips a real row after the CloudKit defaults were added")
    func reconcileRoundTrips() throws {
        let store = try AssignmentStore(inMemory: true)
        let due = Date(timeIntervalSince1970: 2_000_000_000)
        let result = store.reconcile([canvas("1", due: due)], source: .canvas)

        #expect(result.items.count == 1)
        #expect(!result.wasSuspectedPartial)
        let item = try #require(result.items.first)
        // Confirms the designated init actually wrote the real value, not the
        // schema default epoch/empty-string this row would carry if init ever
        // stopped assigning a field explicitly.
        #expect(item.dueAt == due)
        #expect(item.course == "CLOUD 1000")
        #expect(item.sourceID == "1")
    }

    @Test("a gone-from-feed item ages out on schedule, not immediately from a default")
    func agingStillRespectsRealLifecycleFields() throws {
        let store = try AssignmentStore(inMemory: true)
        let longAgo = Date(timeIntervalSince1970: 1_000_000_000)
        _ = store.reconcile([canvas("1", due: longAgo)], source: .canvas)
        // Second sync that omits item "1" but is non-empty (so the
        // partial-fetch guard doesn't intervene): "1" is marked gone-from-feed.
        // If `isGoneFromFeed`'s new `= false` default ever somehow won out over
        // the value `reconcile` sets here, this item would never be flagged
        // gone at all, and the assertions below would fail.
        let result = store.reconcile([canvas("2")], source: .canvas)
        #expect(!result.wasSuspectedPartial)
        // Long overdue and gone from the feed: the grace period has elapsed,
        // so "1" must no longer be part of the active/visible set — only "2"
        // remains.
        let now = Date()
        #expect(store.currentAssignments(now: now).map(\.sourceID) == ["2"])
        // And it's not merely hidden — `reconcile` already ran `pruneAgedOut`,
        // so the aged-out row for "1" was deleted outright.
        #expect(store.rowCount() == 1)
    }

    @Test("completion truth survives on a row created after the CloudKit defaults were added")
    func completionRoundTrips() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1")], source: .canvas)
        let id = Assignment.Source.canvas.rawValue + ":1"

        store.setCompleted(ids: [id], at: Date(timeIntervalSince1970: 500))
        let record = store.completionRecord()

        // `userCompleted`/`canvasSubmitted`/`gradescopeSubmitted` all gained
        // `= false` defaults; this proves a real completion still flips
        // `userCompleted` to true rather than reading back the default.
        #expect(record.ids.contains(id))
        #expect(record.dates[id] == Date(timeIntervalSince1970: 500))
    }

    // MARK: makeDefault(syncEnabled:)

    @Test("makeDefault(syncEnabled: false) is byte-for-byte today's behavior")
    func syncDisabledMatchesLegacyBehavior() throws {
        let store = try #require(AssignmentStore.makeDefault(syncEnabled: false))
        let legacy = try #require(AssignmentStore.makeDefault())

        // Both must take the test-runner's in-memory fallback path — this
        // process is `swift test`, so `SharedDefaults.isTestRunner` is true
        // regardless of the sync flag, and neither call may reach for the
        // real App Group container or a CloudKit connection.
        #expect(store.isPersistent == false)
        #expect(legacy.isPersistent == false)
        #expect(store.isPersistent == legacy.isPersistent)
        #expect(store.storageFailureReason == legacy.storageFailureReason)
        #expect(store.storageFailureReason == nil)
    }

    @Test("makeDefault(syncEnabled: true) still takes the test-runner in-memory path, never CloudKit")
    func syncEnabledStillHermeticUnderTestRunner() throws {
        let store = try #require(AssignmentStore.makeDefault(syncEnabled: true))

        // The test-runner guard in `makeDefault` is checked before the
        // `syncEnabled` branch is ever consulted, so this must be identical
        // to the disabled path above — never a cloud-backed store, never a
        // failure banner about sync.
        #expect(store.isPersistent == false)
        #expect(store.storageFailureReason == nil)
    }
}
