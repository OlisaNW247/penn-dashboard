import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The migrations as a **user actually experiences them**: all of them, in
/// order, on a single launch.
///
/// Two independent one-time migrations landed in this release, and each is
/// covered on its own elsewhere (`SharedDefaultsMigrationTests`). That is not
/// enough. A student upgrading from the previous build runs both in sequence
/// inside one `AppState.init`, and the interesting failures live in the seam:
///
/// - `SharedDefaultsMigration` copies preferences out of the app's private
///   domain into the App Group suite.
/// - `LegacyStateMigration` then drains completions and grade history out of
///   that same suite and onto SwiftData.
///
/// The order matters and is not incidental. `UserDefaults.lhf` is a lazy
/// `static let` whose initializer performs the first migration, so touching it
/// at all guarantees the copy has happened before the drain reads anything.
/// Point the drain at the private domain instead and an upgrading user's
/// completions and entire observed-grade trail vanish silently — the data is
/// in the shared suite and nothing looks for it there. That is the specific
/// regression this file exists to prevent.
@MainActor
@Suite("Migration chain (upgrade path)")
struct MigrationChainTests {

    // MARK: Scratch domains

    /// A throwaway defaults domain. Never `.standard`: these tests write
    /// completion and selection keys, and the suite hazard in HANDOFF.md is
    /// real — a run that leaked state would fail the *next* suite, not this one.
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "lhf.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func destroy(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    private func stores() throws -> (AssignmentStore, GradeHistoryStore) {
        (try AssignmentStore(inMemory: true), try GradeHistoryStore(inMemory: true))
    }

    // MARK: The legacy world, as the previous build left it

    private let completedIDs = ["canvas:101", "canvas:202", "gradescope:303"]

    private func seedLegacyData(_ defaults: UserDefaults, completedAt: Date) throws {
        // Completions: the set, plus timestamps for only *some* of them —
        // pre-timestamp completions are real and must stay dateless.
        defaults.set(completedIDs, forKey: "completedAssignmentIDs")
        let dates = ["canvas:101": completedAt, "canvas:202": completedAt.addingTimeInterval(-86_400)]
        defaults.set(try JSONEncoder().encode(dates), forKey: "completionDates")

        // Observed grade history.
        let history: [String: [GradeHistoryStore.Observation]] = [
            "CIS 1200": [
                .init(date: completedAt.addingTimeInterval(-172_800), percent: 88.0),
                .init(date: completedAt.addingTimeInterval(-86_400), percent: 91.5),
            ],
            "MATH 1400": [.init(date: completedAt, percent: 74.25)],
        ]
        defaults.set(try JSONEncoder().encode(history), forKey: "gradeWatcherHistory")

        // A representative slice of the ~24 preferences that stay in defaults.
        defaults.set("Marco", forKey: "userName")
        defaults.set(["canvas:CIS1200"], forKey: "hiddenCourseKeys")
        defaults.set(["gradescope:OLD"], forKey: "deletedCourseKeys")
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(Data("scheme".utf8), forKey: "gradeWatcherSyllabusSchemes")
        defaults.set(Data("weights".utf8), forKey: "gradeWatcherManualWeights")
        defaults.set(["CIS 1200"], forKey: "gradeWatcherWatchedCourses")
    }

    /// One launch: both migrations, in the order `AppState.init` runs them.
    @discardableResult
    private func launch(
        legacy: UserDefaults,
        shared: UserDefaults?,
        assignmentStore: AssignmentStore?,
        gradeHistoryStore: GradeHistoryStore?,
        now: Date = Date()
    ) -> LegacyStateMigration.Summary {
        SharedDefaultsMigration.run(from: legacy, to: shared)
        // Production reads `UserDefaults.lhf`, which *is* the shared suite when
        // the entitlement exists and `.standard` when it doesn't.
        return LegacyStateMigration.runIfNeeded(
            defaults: shared ?? legacy,
            assignmentStore: assignmentStore,
            gradeHistoryStore: gradeHistoryStore,
            now: now
        )
    }

    // MARK: Fresh install

    @Test("a fresh install runs every migration and finds nothing to move")
    func freshInstall() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        let (ledger, history) = try stores()

        let summary = launch(legacy: legacy, shared: shared,
                             assignmentStore: ledger, gradeHistoryStore: history)

        #expect(summary.didRun)
        #expect(summary.completionsImported == 0)
        #expect(summary.observationsImported == 0)
        #expect(ledger.completionRecord().ids.isEmpty)
        #expect(history.allHistory().isEmpty)
        // Both migrations must record that they ran, or every later launch
        // re-scans a domain that will never have anything in it.
        #expect(shared.bool(forKey: SharedDefaultsMigration.markerKey))
        #expect(shared.integer(forKey: LegacyStateMigration.versionKey) == LegacyStateMigration.currentVersion)
    }

    // MARK: Upgrade with a populated store

    @Test("an upgrading user keeps completions, grade history and every preference")
    func upgradeWithPopulatedStore() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        let (ledger, history) = try stores()
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try seedLegacyData(legacy, completedAt: completedAt)

        let summary = launch(legacy: legacy, shared: shared,
                             assignmentStore: ledger, gradeHistoryStore: history)

        // Completions reached SwiftData — all three, including the two sources.
        #expect(summary.completionsImported == 3)
        let record = ledger.completionRecord()
        #expect(record.ids == Set(completedIDs))

        // Timestamps survive, and the one that never had a timestamp still
        // doesn't — synthesising one would move the card in Done and inflate
        // the weekly ring.
        #expect(record.dates["canvas:101"] == completedAt)
        #expect(record.dates["gradescope:303"] == nil)

        // Grade history reached its own store, both courses, every observation.
        #expect(summary.observationsImported == 3)
        #expect(history.history(courseID: "CIS 1200").count == 2)
        #expect(history.history(courseID: "MATH 1400").first?.percent == 74.25)

        // …and the preferences that are *not* superseded came across intact.
        #expect(shared.string(forKey: "userName") == "Marco")
        #expect(shared.stringArray(forKey: "hiddenCourseKeys") == ["canvas:CIS1200"])
        #expect(shared.stringArray(forKey: "deletedCourseKeys") == ["gradescope:OLD"])
        #expect(shared.bool(forKey: "hasCompletedOnboarding"))
        #expect(shared.data(forKey: "gradeWatcherSyllabusSchemes") != nil)
        #expect(shared.data(forKey: "gradeWatcherManualWeights") != nil)
        #expect(shared.stringArray(forKey: "gradeWatcherWatchedCourses") == ["CIS 1200"])
    }

    /// The regression guard for the task 3 / task 5 collision.
    ///
    /// The legacy blobs exist **only** in the private domain, exactly as they do
    /// on a real upgrading device. If the ledger drain were pointed at that
    /// private domain while the App Group copy had already moved the keys — or
    /// if the copy stopped carrying these three keys — this is the test that
    /// goes red instead of a student silently losing every completion.
    @Test("completions survive even though the drain reads the shared suite, not the private one")
    func completionsSurviveTheDomainHandover() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        let (ledger, history) = try stores()
        try seedLegacyData(legacy, completedAt: Date(timeIntervalSince1970: 1_700_000_000))

        // Nothing is in the shared suite yet — the handover has not happened.
        #expect(shared.stringArray(forKey: "completedAssignmentIDs") == nil)

        launch(legacy: legacy, shared: shared,
               assignmentStore: ledger, gradeHistoryStore: history)

        #expect(ledger.completionRecord().ids == Set(completedIDs))
        #expect(history.allHistory().count == 2)
    }

    // MARK: Relaunch

    @Test("relaunching re-runs both migrations without double-applying")
    func relaunchIsIdempotent() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try seedLegacyData(legacy, completedAt: completedAt)

        // Launch 1 — on stores that persist across the simulated relaunch.
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-chain-\(UUID().uuidString).store")
        let historyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-chain-h-\(UUID().uuidString).store")
        do {
            let ledger = try AssignmentStore(url: ledgerURL)
            let history = try GradeHistoryStore(url: historyURL)
            launch(legacy: legacy, shared: shared, assignmentStore: ledger, gradeHistoryStore: history)
            #expect(ledger.completionRecord().ids.count == 3)
        }

        // Launch 2 — same defaults, same stores on disk.
        let ledger = try AssignmentStore(url: ledgerURL)
        let history = try GradeHistoryStore(url: historyURL)
        let second = launch(legacy: legacy, shared: shared,
                            assignmentStore: ledger, gradeHistoryStore: history)

        // The version gate short-circuits the drain entirely.
        #expect(!second.didRun)
        #expect(second.completionsImported == 0)

        // And nothing doubled: three completions, not six; two courses of
        // history with their original observation counts, not four.
        #expect(ledger.completionRecord().ids.count == 3)
        #expect(ledger.stats().duplicateIDs == 0)
        #expect(history.allHistory().count == 2)
        #expect(history.history(courseID: "CIS 1200").count == 2)
    }

    @Test("a relaunch cannot resurrect a preference the user has since changed")
    func relaunchDoesNotClobberNewerValues() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        let (ledger, history) = try stores()
        try seedLegacyData(legacy, completedAt: Date())

        launch(legacy: legacy, shared: shared, assignmentStore: ledger, gradeHistoryStore: history)

        // The user renames themselves after upgrading. The stale original is
        // still sitting in the private domain.
        shared.set("Olisa", forKey: "userName")
        #expect(legacy.string(forKey: "userName") == "Marco")

        let (ledger2, history2) = try stores()
        launch(legacy: legacy, shared: shared, assignmentStore: ledger2, gradeHistoryStore: history2)

        #expect(shared.string(forKey: "userName") == "Olisa")
    }

    // MARK: No App Group entitlement

    @Test("with no App Group the chain still migrates and never crashes")
    func noAppGroupEntitlement() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (ledger, history) = try stores()
        try seedLegacyData(legacy, completedAt: Date(timeIntervalSince1970: 1_700_000_000))

        // `shared: nil` is the unit-test / preview / unsigned-binary case.
        let summary = launch(legacy: legacy, shared: nil,
                             assignmentStore: ledger, gradeHistoryStore: history)

        // Degraded, not broken: everything still lands on the ledger, read out
        // of the only domain there is.
        #expect(summary.completionsImported == 3)
        #expect(ledger.completionRecord().ids == Set(completedIDs))
        #expect(history.allHistory().count == 2)

        // Crucially the App Group marker is NOT set, so a later launch that
        // does have the entitlement still performs the copy.
        #expect(!legacy.bool(forKey: SharedDefaultsMigration.markerKey))
    }

    @Test("a launch with no ledger at all leaves the data to be migrated later")
    func noStoreDefersTheMigration() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        try seedLegacyData(legacy, completedAt: Date())

        // Both stores failed to open — there is nowhere to migrate to.
        launch(legacy: legacy, shared: shared, assignmentStore: nil, gradeHistoryStore: nil)
        #expect(shared.integer(forKey: LegacyStateMigration.versionKey) == 0)

        // A later launch that can open them still gets the data across.
        let (ledger, history) = try stores()
        let summary = launch(legacy: legacy, shared: shared,
                             assignmentStore: ledger, gradeHistoryStore: history)
        #expect(summary.completionsImported == 3)
        #expect(history.allHistory().count == 2)
    }

    /// Pins the coupling the whole upgrade path rests on.
    ///
    /// These three keys are *superseded* — nothing writes them any more, they
    /// live on the ledger now. The tempting cleanup is therefore to strike them
    /// off the App Group copy list, since "the App Group migration doesn't own
    /// them". Doing that breaks the handover: the drain reads the shared suite,
    /// so a key the copy no longer carries is a key it will never see, and an
    /// upgrading student loses the data with no error anywhere.
    ///
    /// If this test is what's failing, the fix is *not* to delete it.
    @Test("the superseded keys stay on the App Group copy list")
    func supersededKeysRemainOnTheCopyList() {
        for key in ["completedAssignmentIDs", "completionDates", "gradeWatcherHistory"] {
            #expect(
                SharedDefaultsMigration.legacyKeys.contains(key),
                "\(key) must keep travelling to the shared suite — LegacyStateMigration drains it from there"
            )
        }
    }

    // MARK: Interaction with the ledger's own rows

    @Test("a migrated completion attaches to the real row once its feed syncs")
    func migratedCompletionPromotesInPlace() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        let (ledger, history) = try stores()
        try seedLegacyData(legacy, completedAt: Date(timeIntervalSince1970: 1_700_000_000))

        launch(legacy: legacy, shared: shared, assignmentStore: ledger, gradeHistoryStore: history)

        // Nothing has synced yet, so the migrated completions are held on
        // completion-only rows and stay out of the visible ledger.
        #expect(ledger.currentAssignments().isEmpty)

        // Canvas syncs and one of the completed items comes back.
        let real = Assignment(source: .canvas, sourceID: "101", kind: .assignment,
                              course: "CIS 1200", title: "HW 3",
                              dueAt: Date(timeIntervalSince1970: 1_699_000_000), url: nil)
        _ = ledger.reconcile([real], source: .canvas)

        // The row is promoted in place, keeping the completion that was
        // waiting for it — and without duplicating.
        let visible = ledger.currentAssignments()
        #expect(visible.count == 1)
        #expect(visible.first?.id == "canvas:101")
        #expect(ledger.completionRecord().ids.contains("canvas:101"))
        #expect(ledger.stats().duplicateIDs == 0)
    }

    @Test("an already-completed ledger row is not re-imported over")
    func existingCompletionWins() throws {
        let (legacy, ln) = scratchDefaults(); defer { destroy(ln) }
        let (shared, sn) = scratchDefaults(); defer { destroy(sn) }
        let (ledger, history) = try stores()

        // The ledger already knows this item is done, with a known timestamp.
        let real = Assignment(source: .canvas, sourceID: "101", kind: .assignment,
                              course: "CIS 1200", title: "HW 3", dueAt: nil, url: nil)
        _ = ledger.reconcile([real], source: .canvas)
        let authoritative = Date(timeIntervalSince1970: 1_710_000_000)
        ledger.setCompleted(ids: ["canvas:101"], at: authoritative)

        // The legacy blob claims a different, older date for the same id.
        try seedLegacyData(legacy, completedAt: Date(timeIntervalSince1970: 1_700_000_000))
        launch(legacy: legacy, shared: shared, assignmentStore: ledger, gradeHistoryStore: history)

        #expect(ledger.completionRecord().dates["canvas:101"] == authoritative)
    }
}
