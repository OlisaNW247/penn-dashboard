import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Round 2 of course exclusion: a student's own choice (`setCourseExcluded`,
/// persisted) layered over a registrar-derived default
/// (`setAutomaticExclusions`, in-memory, pushed every sync by
/// `AppState.pushGradeWatcherFacts`) — see `GradeWatcherStore.courseCountsChoice`'s
/// doc comment for the precedence rule this suite pins: manual always wins,
/// in either direction, over automatic.
///
/// Also covers the round-1 → round-2 migration (`gradeWatcherExcludedCourses`
/// → `gradeWatcherCourseCountsChoice`) and `suggestedScheme`/
/// `applySuggestedScheme`, the pooled-syllabus-profile suggestion that reuses
/// `attachSyllabus`'s own storage and side effects.
///
/// `.serialized`, and every test restores every key it touches — same
/// shared-`UserDefaults.lhf` trap `GradeWatcherStoreOverridesTests` guards
/// against (see that suite's doc comment).
@MainActor
@Suite("Grade Watcher exclusion and suggested syllabus", .serialized)
struct GradeWatcherExclusionTests {
    private static let touchedKeys = [
        "gradeWatcherCourseCountsChoice",
        "gradeWatcherExcludedCourses",
        "gradeWatcherSyllabusSchemes",
        "gradeWatcherWatchedCourses",
    ]

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

    private func makeProfile(courseID: String, weights: [CourseGradingProfile.Weight]) -> CourseGradingProfile {
        CourseGradingProfile(
            courseID: courseID,
            weights: weights,
            components: [],
            extractedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Automatic vs. manual precedence

    @Test("a course with no manual choice reads as excluded once automatic exclusion applies")
    func automaticExclusionAppliesWithNoChoice() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            #expect(!store.isCourseExcluded(courseID: "1001"))

            store.setAutomaticExclusions(["1001"])
            #expect(store.isCourseExcluded(courseID: "1001"))
            #expect(store.courseExclusionSource(courseID: "1001") == "from the registrar")
        }
    }

    @Test("choosing \"counts\" overrides an automatic exclusion")
    func manualCountsOverridesAutomatic() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.setAutomaticExclusions(["1001"])
            #expect(store.isCourseExcluded(courseID: "1001"))

            store.setCourseExcluded(courseID: "1001", false)
            #expect(!store.isCourseExcluded(courseID: "1001"))
            #expect(store.courseExclusionSource(courseID: "1001") == nil)

            // The automatic set itself is untouched — only the manual choice
            // layered on top of it changed.
            #expect(store.automaticExclusions.contains("1001"))
        }
    }

    @Test("a manual exclusion persists across a fresh store instance")
    func manualExclusionPersists() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.setCourseExcluded(courseID: "1001", true)

            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.isCourseExcluded(courseID: "1001"))
            #expect(reloaded.courseExclusionSource(courseID: "1001") == "you chose")
            // No automatic facts have been pushed to this fresh instance —
            // the manual choice alone accounts for the exclusion.
            #expect(reloaded.automaticExclusions.isEmpty)
        }
    }

    // MARK: - Legacy migration

    @Test("the round-1 excluded set migrates to a false choice and removes the old key")
    func legacyExclusionMigrates() {
        isolated {
            UserDefaults.lhf.set(["9001", "9002"], forKey: "gradeWatcherExcludedCourses")

            let store = GradeWatcherStore(historyStore: nil)
            #expect(store.isCourseExcluded(courseID: "9001"))
            #expect(store.isCourseExcluded(courseID: "9002"))
            #expect(store.courseExclusionSource(courseID: "9001") == "you chose")
            #expect(UserDefaults.lhf.object(forKey: "gradeWatcherExcludedCourses") == nil)

            // Migrated once — a second launch reads the already-migrated
            // choice map, not a legacy key that no longer exists.
            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.isCourseExcluded(courseID: "9001"))
        }
    }

    // MARK: - Suggested scheme from a pooled profile

    @Test("suggestedScheme is nil once a syllabus is already attached")
    func suggestedSchemeNilWhenAttached() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            let profile = makeProfile(courseID: "1001", weights: [
                CourseGradingProfile.Weight(name: "Homework", percent: 60),
                CourseGradingProfile.Weight(name: "Exams", percent: 40),
            ])
            store.setGradingProfiles([profile])
            #expect(store.suggestedScheme(courseID: "1001") != nil)

            let scheme = SyllabusGradingScheme(
                categories: [SyllabusCategory(id: "hw", name: "Homework", weightPercent: 100)],
                confidence: .high,
                rawWeightSum: 100
            )
            store.attachSyllabus(AttachedSyllabus(scheme: scheme, source: .pasted), courseID: "1001")

            #expect(store.suggestedScheme(courseID: "1001") == nil)
        }
    }

    @Test("suggestedScheme reads a two-weight profile summing to 100 as a scheme with .sharedProfile source")
    func suggestedSchemeFromProfile() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            let profile = makeProfile(courseID: "1001", weights: [
                CourseGradingProfile.Weight(name: "Homework", percent: 60),
                CourseGradingProfile.Weight(name: "Exams", percent: 40),
            ])
            store.setGradingProfiles([profile])

            let suggestion = store.suggestedScheme(courseID: "1001")
            #expect(suggestion != nil)
            #expect(suggestion?.source == .sharedProfile)
            #expect(suggestion?.scheme.categories.count == 2)
            #expect(suggestion?.scheme.rawWeightSum == 100)
        }
    }

    @Test("applySuggestedScheme attaches the suggestion with source .sharedProfile and starts watching")
    func applySuggestedSchemeAttaches() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            let profile = makeProfile(courseID: "1001", weights: [
                CourseGradingProfile.Weight(name: "Homework", percent: 60),
                CourseGradingProfile.Weight(name: "Exams", percent: 40),
            ])
            store.setGradingProfiles([profile])
            #expect(store.syllabus(courseID: "1001") == nil)
            #expect(!store.isWatching("1001"))

            store.applySuggestedScheme(courseID: "1001")

            let attached = store.syllabus(courseID: "1001")
            #expect(attached?.source == .sharedProfile)
            #expect(attached?.scheme.categories.count == 2)
            #expect(store.isWatching("1001"))

            // Persists like any other attached syllabus.
            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(reloaded.syllabus(courseID: "1001")?.source == .sharedProfile)
        }
    }
}
