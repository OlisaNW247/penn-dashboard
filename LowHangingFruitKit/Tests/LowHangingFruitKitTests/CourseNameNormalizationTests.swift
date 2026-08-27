import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Canvas descriptors like "BAN_CIS-2400-001 202630" used to fail to parse
/// and got stored verbatim as `course` strings — in ledger rows and as
/// preference keys (hidden/deleted sets, renames, content decisions). This
/// suite covers the migration that rewrites already-stored data once the
/// parser can turn a raw descriptor into a clean code, so the same course
/// stops appearing under both strings at once.
///
/// `UserDefaults.lhf` is process-wide, so the `AppState`-level test below
/// backs up and restores every key it touches — the same discipline
/// `CourseContentDecisionStoreTests` and `IntroFlowTests` use for their own
/// keys. `.serialized` for the same reason `CourseContentDecisionStoreTests`
/// gives: a backup/restore of a shared key racing another test's write to
/// the same key (under Swift Testing's default parallel execution) could
/// lose a write, not just read something unexpected.
@MainActor
@Suite("Course name normalization", .serialized)
struct CourseNameNormalizationTests {

    // MARK: - AssignmentStore.normalizeCourseNames — pure ledger sweep
    //
    // Uses a hardcoded fake transform (a dictionary-backed lookup), NOT
    // `CourseCode`, so this half of the suite stays decoupled from the
    // parser fix landing in parallel on `CourseCode.swift`.

    private static let fakeRawCourse = "BAN_CIS-2400-001 202630"
    private static let fakeCleanCourse = "CIS 2400"

    private func fakeTransform(_ name: String) -> String {
        name == Self.fakeRawCourse ? Self.fakeCleanCourse : name
    }

    private func canvas(_ id: String, course: String, title: String = "HW") -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: Date(), url: nil)
    }

    @Test("rewrites only the rows whose course actually changes, and returns the count")
    func normalizesChangedRowsOnly() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([
            canvas("1", course: Self.fakeRawCourse),
            canvas("2", course: Self.fakeCleanCourse),
        ], source: .canvas)

        let changed = store.normalizeCourseNames(fakeTransform)
        #expect(changed == 1)

        let courses = Set(store.assignments(source: .canvas).map(\.course))
        #expect(courses == [Self.fakeCleanCourse])
        #expect(store.rowCount() == 2)   // rewritten in place, not duplicated
    }

    @Test("a second run touches nothing — idempotent")
    func secondRunIsIdempotent() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("1", course: Self.fakeRawCourse)], source: .canvas)

        #expect(store.normalizeCourseNames(fakeTransform) == 1)
        #expect(store.normalizeCourseNames(fakeTransform) == 0)
        #expect(store.assignments(source: .canvas).first?.course == Self.fakeCleanCourse)
    }

    // MARK: - AppState.init — real CourseCode.parse, seeded preferences
    //
    // DEPENDS ON THE PARALLEL PARSER FIX: this exercises the real
    // `CourseCode.parse`, not a fake, so it only passes once
    // `CourseCode.parse("BAN_CIS-2400-001 202630").code` actually returns
    // "CIS 2400". If that fix hasn't landed yet, `CourseCode.parse` falls
    // back to the trimmed raw string and every assertion below fails — an
    // intended, documented coupling, not a bug in this file or in
    // `AppState.normalizeStoredCourseNames`.

    private static let rawCourse = "BAN_CIS-2400-001 202630"
    private static let cleanCourse = "CIS 2400"

    private static let touchedKeys = [
        CoursePreferencesStore.storageKey,
        "hiddenCourseKeys", "deletedCourseKeys", "courseNameOverrides", "courseContentDecisionsV1",
    ]

    /// Snapshots whatever is currently at the keys this migration touches,
    /// seeds synthetic data keyed on the raw registrar string, runs `body`,
    /// then restores exactly what was there before — including "nothing was
    /// there," which `removeObject` reproduces rather than writing back an
    /// empty-but-present value.
    ///
    /// Hidden/deleted/rename are seeded through `CoursePreferencesStore` —
    /// the canonical record since the v4 consolidation; the three raw keys
    /// are only its widget-facing projection, and `AppState` never reads
    /// them back. Content decisions still live in their own store, so that
    /// half seeds exactly as it did on `v3.5`.
    private func withSeededRawCourseState(_ body: () throws -> Void) rethrows {
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

        defaults.removeObject(forKey: CoursePreferencesStore.storageKey)
        let prefs = CoursePreferencesStore()
        prefs.setVisible(Self.rawCourse, false)
        prefs.setDeleted(Self.rawCourse, true)
        prefs.setDisplayName(Self.rawCourse, to: "My Class")
        CourseContentDecisionStore.save([
            Self.rawCourse: CourseContentDecision(
                choice: .include, fingerprint: "readings:1", decidedAt: Date()
            ),
        ])

        try body()
    }

    @Test("AppState.init migrates hidden/deleted/renamed/content-decision keys off a raw course string")
    func appStateInitMigratesPreferences() throws {
        try withSeededRawCourseState {
            let ledger = try AssignmentStore(inMemory: true)
            _ = ledger.reconcile([canvas("1", course: Self.rawCourse)], source: .canvas)

            let state = AppState(assignmentStore: ledger)

            // The clean code inherited every preference the raw string held.
            #expect(!state.isCourseSelected(Self.cleanCourse))   // hidden AND deleted
            #expect(state.isCourseDeleted(Self.cleanCourse))
            #expect(state.courseDisplayName(Self.cleanCourse) == "My Class")
            // `courseContentIncluded` is now true by default, so assert the
            // re-keyed decision at the store level — the migration, not the
            // default, is what's under test here.
            #expect(CourseContentDecisionStore.load()[Self.cleanCourse]?.choice == .include)

            // Nothing is left keyed on the raw string.
            #expect(state.isCourseSelected(Self.rawCourse))
            #expect(!state.isCourseDeleted(Self.rawCourse))
            #expect(state.courseDisplayName(Self.rawCourse) == Self.rawCourse)

            // The ledger row itself was rewritten too.
            let courses = Set((state.assignmentStore?.assignments(source: .canvas) ?? []).map(\.course))
            #expect(courses == [Self.cleanCourse])
        }
    }
}
