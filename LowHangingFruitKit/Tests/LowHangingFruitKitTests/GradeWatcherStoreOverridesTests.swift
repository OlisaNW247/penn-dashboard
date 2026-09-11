import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Pins the four student-owned override tiers `GradeWatcherStore` persists
/// alongside `manualWeights` (docs/grades.md-style: small, non-secret,
/// JSON-encoded into `UserDefaults.lhf` — never the SwiftData ledger, never
/// the Keychain): hand-typed expected item counts, per-item score
/// corrections, a forced grading mode, and per-course exclusion from "the"
/// grade / GPA estimate.
///
/// The contract that actually matters for each setter is persistence, not
/// just the `@Published` value changing — a correction that only lives in
/// memory would look fine for the rest of the launch and silently vanish on
/// the next one. So every round-trip test reads back through a **second,
/// freshly constructed** `GradeWatcherStore`, the same way a real relaunch
/// would.
///
/// `.serialized`, and every test restores every key it touches: `UserDefaults
/// .lhf` resolves to the process-wide `UserDefaults.standard` domain under
/// `swift test` (no App Group entitlement in an unsandboxed test run — see
/// `SharedDefaults.isTestRunner`'s doc comment), so an unrestored key here
/// would leak into every other suite that constructs a `GradeWatcherStore`,
/// exactly the shared-`UserDefaults` trap this repo has been bitten by
/// before.
@MainActor
@Suite("Grade Watcher overrides", .serialized)
struct GradeWatcherStoreOverridesTests {
    /// Every key any test in this suite writes to, including the ones two of
    /// them reach only indirectly through `attachSyllabus` (which also
    /// persists the syllabus itself and flips the course to "watching").
    private static let touchedKeys = [
        "gradeWatcherExpectedCounts",
        "gradeWatcherItemOverrides",
        "gradeWatcherModeOverrides",
        "gradeWatcherExcludedCourses",
        "gradeWatcherCourseCountsChoice",
        "gradeWatcherManualWeights",
        "gradeWatcherSyllabusSchemes",
        "gradeWatcherWatchedCourses",
        "gradeWatcherConfirmedCategoryMappings",
    ]

    /// Backs up every touched key's exact prior value (not just "clears it"),
    /// runs `body` against a clean slate, then restores exactly what was
    /// there before — on the way in as well as out, so an interrupted earlier
    /// run can't leave this suite starting from stale state either.
    private func isolated<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.lhf
        let backups = Self.touchedKeys.map { ($0, defaults.object(forKey: $0)) }
        for key in Self.touchedKeys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in backups {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        return try body()
    }

    private func makeSnapshot(courseID: String, category: GradeCategory) -> CourseGradeSnapshot {
        CourseGradeSnapshot(
            courseID: courseID,
            courseUsesWeights: true,
            categories: [category],
            canvasComputedCurrentScore: nil,
            submissions: [],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Expected counts

    @Test("setExpectedCount persists across a fresh store instance")
    func expectedCountPersists() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.setExpectedCount(courseID: "1001", categoryID: "cat1", count: 7)

            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.manualExpectedCounts(courseID: "1001") == ["cat1": 7])
        }
    }

    @Test("setExpectedCount removes on nil or a count below 1")
    func expectedCountRemoves() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.setExpectedCount(courseID: "1001", categoryID: "cat1", count: 7)
            store.setExpectedCount(courseID: "1001", categoryID: "cat1", count: nil)
            #expect(store.manualExpectedCounts(courseID: "1001").isEmpty)

            store.setExpectedCount(courseID: "1001", categoryID: "cat1", count: 3)
            store.setExpectedCount(courseID: "1001", categoryID: "cat1", count: 0)
            #expect(store.manualExpectedCounts(courseID: "1001").isEmpty)

            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.manualExpectedCounts(courseID: "1001").isEmpty)
        }
    }

    // MARK: - Item overrides

    @Test("setItemOverride persists across a fresh store instance")
    func itemOverridePersists() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            let override = GradeItemOverride(score: 9, pointsPossible: nil, isExcluded: false)
            store.setItemOverride(courseID: "1001", itemID: "item1", override: override)

            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.itemOverrides(courseID: "1001") == ["item1": override])
        }
    }

    @Test("setItemOverride removes on nil or an empty override")
    func itemOverrideRemoves() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            let override = GradeItemOverride(score: 9, pointsPossible: nil, isExcluded: false)
            store.setItemOverride(courseID: "1001", itemID: "item1", override: override)
            store.setItemOverride(courseID: "1001", itemID: "item1", override: nil)
            #expect(store.itemOverrides(courseID: "1001").isEmpty)

            store.setItemOverride(courseID: "1001", itemID: "item1", override: override)
            // A default-initialized override changes nothing (`isEmpty`) and
            // is treated as if it weren't present at all — same rule the
            // engine itself applies before this ever reaches `GradeEngine`.
            store.setItemOverride(courseID: "1001", itemID: "item1", override: GradeItemOverride())
            #expect(store.itemOverrides(courseID: "1001").isEmpty)

            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.itemOverrides(courseID: "1001").isEmpty)
        }
    }

    // MARK: - Mode override

    @Test("setModeOverride persists and nil clears it")
    func modeOverridePersists() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.setModeOverride(courseID: "1001", mode: .points)

            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.modeOverride(courseID: "1001") == .points)

            reloaded.setModeOverride(courseID: "1001", mode: nil)
            #expect(reloaded.modeOverride(courseID: "1001") == nil)

            let reloadedAgain = GradeWatcherStore(historyStore: nil)
            #expect(reloadedAgain.modeOverride(courseID: "1001") == nil)
        }
    }

    // MARK: - Course exclusion

    @Test("setCourseExcluded round-trips across a fresh store instance")
    func courseExclusionPersists() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            #expect(!store.isCourseExcluded(courseID: "1001"))

            store.setCourseExcluded(courseID: "1001", true)
            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.isCourseExcluded(courseID: "1001"))

            reloaded.setCourseExcluded(courseID: "1001", false)
            let reloadedAgain = GradeWatcherStore(historyStore: nil)
            #expect(!reloadedAgain.isCourseExcluded(courseID: "1001"))
        }
    }

    // MARK: - Expected-count precedence (manual over syllabus)

    /// Mirrors `effectiveWeights`' own precedence rule and, deliberately,
    /// its test setup: a confirmed syllabus whose one category exact-matches
    /// the course's one Canvas category, so coverage is complete and
    /// `syllabusExpectedCounts` isn't gated to empty. `attachSyllabus` is the
    /// real seam the UI uses (SyllabusSetupView), not a private test hook.
    @Test("effectiveExpectedCounts: manual override wins over the syllabus")
    func effectiveExpectedCountsPrecedence() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            let category = GradeCategory(id: "cat1", name: "Homework", weight: 100)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", category: category)])

            let scheme = SyllabusGradingScheme(
                categories: [
                    SyllabusCategory(id: "hw", name: "Homework", weightPercent: 100, expectedItemCount: 10),
                ],
                confidence: .high,
                rawWeightSum: 100
            )
            store.attachSyllabus(AttachedSyllabus(scheme: scheme, source: .pasted), courseID: "1001")

            // Sanity check on the fixture itself: coverage really is complete,
            // otherwise the rest of this test would be proving nothing.
            #expect(store.syllabusMatch(courseID: "1001")?.isCompleteCoverage == true)
            #expect(store.syllabusExpectedCounts(courseID: "1001") == ["cat1": 10])
            #expect(store.effectiveExpectedCounts(courseID: "1001") == ["cat1": 10])

            store.setExpectedCount(courseID: "1001", categoryID: "cat1", count: 5)
            #expect(store.effectiveExpectedCounts(courseID: "1001") == ["cat1": 5])
            // The syllabus number is still there underneath — only the
            // *effective* (merged) view changes.
            #expect(store.syllabusExpectedCounts(courseID: "1001") == ["cat1": 10])
        }
    }

    // MARK: - Explanation

    @Test("explanation(courseID:) is nil before a fetch and non-nil once a snapshot is loaded")
    func explanationNonNilOnceLoaded() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            #expect(store.explanation(courseID: "1001") == nil)

            let category = GradeCategory(id: "cat1", name: "Homework", weight: 100)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", category: category)])

            #expect(store.explanation(courseID: "1001") != nil)
        }
    }
}
