import Testing
import Foundation
@testable import LowHangingFruitKit

/// `CoursePreferences` replaced four parallel per-course maps — `hiddenCourseKeys`,
/// `deletedCourseKeys`, `courseNameOverrides`, `canvasCourseIDsByCode` — that
/// `AppState` loaded and persisted by hand. The consolidation is only safe if
/// three things hold, and each is a section below:
///
/// 1. **A course with no record is a course on defaults**, not an unknown course.
///    Every read goes through `preferences(for:)`, so getting this wrong would
///    hide every class the student has never touched a setting on.
/// 2. **The legacy fold is idempotent**, because `LegacyStateMigration` gates it
///    on a version number that a restored-from-backup device can present stale.
/// 3. **The legacy keys keep being written**, because `LedgerWidgetReader` runs
///    in another process and reads them by name. Consolidating the app's copy
///    while silently orphaning the widget's would show hidden and deleted
///    classes on the Home Screen.
@MainActor
@Suite("Course preferences")
struct CoursePreferencesTests {

    /// A throwaway domain. Never `.standard` — these tests write the same
    /// selection keys the app does, and the shared-suite hazard in HANDOFF.md is
    /// real: leaked state fails the *next* suite, not this one.
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "lhf.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func destroy(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    // MARK: Absence means defaults, not absence

    @Test("A course with no record reads as every default, not as missing")
    func unconfiguredCourseIsDefaulted() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = CoursePreferencesStore(defaults: defaults)

        // CIS 1200 has never been touched. It must still be a visible,
        // notifying, un-deleted class — the state a student expects of a course
        // they have simply never opened a setting for.
        #expect(store.isVisible("CIS 1200"))
        #expect(store.isSelected("CIS 1200"))
        #expect(!store.isDeleted("CIS 1200"))
        #expect(store.notificationsEnabled("CIS 1200"))
        #expect(!store.isArchived("CIS 1200"))
        #expect(store.canvasCourseID(for: "CIS 1200") == nil)

        // And it contributes nothing to storage: `configuredCourseKeys` is not
        // the class list, it is the list of courses carrying a non-default.
        #expect(store.configuredCourseKeys.isEmpty)
    }

    // MARK: nil lead offsets mean "inherit"

    @Test("nil leadOffsets inherit the global setting; a set overrides it")
    func leadOffsetsInherit() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = CoursePreferencesStore(defaults: defaults)
        let global: Set<LeadOffset> = [.h24, .h1]

        // Untouched: inherits. This is what lets a student configure two
        // courses and leave the rest alone without the global control going
        // dead the moment per-course settings exist.
        #expect(store.effectiveLeadOffsets(for: "CIS 1200", global: global) == global)

        store.setLeadOffsets("CIS 1200", [.d7])
        #expect(store.effectiveLeadOffsets(for: "CIS 1200", global: global) == [.d7])

        // Explicitly empty is a real answer — "notify me at no lead time" —
        // and must not fall back to the global set.
        store.setLeadOffsets("CIS 1200", [])
        #expect(store.effectiveLeadOffsets(for: "CIS 1200", global: global).isEmpty)

        // Back to nil restores inheritance rather than freezing the last value.
        store.setLeadOffsets("CIS 1200", nil)
        #expect(store.effectiveLeadOffsets(for: "CIS 1200", global: global) == global)
    }

    // MARK: Durability

    @Test("Settings survive a fresh handle on the same domain")
    func roundTripsThroughDefaults() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        let store = CoursePreferencesStore(defaults: defaults)
        store.setVisible("CIS 1200", false)
        store.setDisplayName("CIS 1600", to: "Discrete Math")
        store.setCanvasCourseID("CIS 1600", "1234567")
        store.setNotificationsEnabled("CIS 2400", false)
        store.setLeadOffsets("CIS 2400", [.d7])
        store.setArchivedTerm("CIS 1100", Term(year: 2026, season: .spring))

        // A separate instance, as a relaunch would build.
        let reloaded = CoursePreferencesStore(defaults: defaults)
        #expect(!reloaded.isVisible("CIS 1200"))
        #expect(reloaded.displayName(for: "CIS 1600") == "Discrete Math")
        #expect(reloaded.canvasCourseID(for: "CIS 1600") == "1234567")
        #expect(!reloaded.notificationsEnabled("CIS 2400"))
        #expect(reloaded.leadOffsets(for: "CIS 2400") == [.d7])
        #expect(reloaded.archivedTerm(for: "CIS 1100") == Term(year: 2026, season: .spring))
        #expect(reloaded.isArchived("CIS 1100"))
    }

    @Test("A mutation cannot re-key the record it is editing")
    func updateCannotRekey() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = CoursePreferencesStore(defaults: defaults)

        // Re-keying through `update` would file a record under one key while it
        // claims to be another, and every read would then disagree about it.
        store.update("CIS 1200") { prefs in
            prefs.courseKey = "CIS 9999"
            prefs.isVisible = false
        }

        #expect(!store.isVisible("CIS 1200"))
        #expect(store.isVisible("CIS 9999"))
        #expect(store.preferences(for: "CIS 1200").courseKey == "CIS 1200")
    }

    // MARK: The legacy fold

    /// The world the previous build left behind: four separate keys.
    private func seedLegacyMaps(_ defaults: UserDefaults) {
        defaults.set(["CIS 1200"], forKey: SharedDefaults.hiddenCoursesKey)
        defaults.set(["CIS 1100"], forKey: SharedDefaults.deletedCoursesKey)
        defaults.set(["CIS 1600": "Discrete Math"], forKey: SharedDefaults.courseNameOverridesKey)
        defaults.set(
            ["CIS 1600": "1234567", "CIS 2400": "7654321"],
            forKey: CoursePreferencesStore.legacyCanvasCourseIDsKey
        )
    }

    @Test("The fold carries all four legacy maps across")
    func importsEveryLegacyMap() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        seedLegacyMaps(defaults)

        let changed = CoursePreferencesStore.importLegacyCourseState(in: defaults)
        #expect(changed > 0)

        let store = CoursePreferencesStore(defaults: defaults)
        #expect(!store.isVisible("CIS 1200"))     // was hidden
        #expect(store.isDeleted("CIS 1100"))      // was deleted, still restorable
        #expect(store.displayName(for: "CIS 1600") == "Discrete Math")
        #expect(store.canvasCourseID(for: "CIS 1600") == "1234567")
        #expect(store.canvasCourseID(for: "CIS 2400") == "7654321")

        // A course that appeared in only one legacy map keeps defaults everywhere
        // else — the fold must not invent settings it never read.
        #expect(store.isVisible("CIS 2400"))
        #expect(store.notificationsEnabled("CIS 2400"))
    }

    @Test("Re-running the fold changes nothing")
    func foldIsIdempotent() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        seedLegacyMaps(defaults)

        _ = CoursePreferencesStore.importLegacyCourseState(in: defaults)
        let before = CoursePreferencesStore(defaults: defaults).byCourseKey

        // The version gate lives in `LegacyStateMigration`, and a device
        // restored from backup can present a stale version — so the fold itself
        // has to be safe to run twice, not merely gated against it.
        let secondRun = CoursePreferencesStore.importLegacyCourseState(in: defaults)
        #expect(secondRun == 0)
        #expect(CoursePreferencesStore(defaults: defaults).byCourseKey == before)
    }

    @Test("A fresh install has nothing to fold and says so")
    func freshInstallFoldsNothing() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        #expect(CoursePreferencesStore.importLegacyCourseState(in: defaults) == 0)
        #expect(CoursePreferencesStore(defaults: defaults).configuredCourseKeys.isEmpty)
    }

    @Test("The fold never overwrites a newer value with a legacy one")
    func foldDoesNotClobberNewerSettings() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        // The student hid CIS 2400 in the new world...
        let store = CoursePreferencesStore(defaults: defaults)
        store.setVisible("CIS 2400", false)

        // ...while a stale legacy map still says it was visible. Re-running the
        // fold — which a stale version marker can cause — must not resurrect it.
        defaults.set([String](), forKey: SharedDefaults.hiddenCoursesKey)
        _ = CoursePreferencesStore.importLegacyCourseState(in: defaults)

        #expect(!CoursePreferencesStore(defaults: defaults).isVisible("CIS 2400"))
    }

    // MARK: The widget still reads the old key names

    @Test("Writing a preference keeps the widget-readable legacy keys in sync")
    func legacyProjectionStaysCurrent() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = CoursePreferencesStore(defaults: defaults)

        store.setVisible("CIS 1200", false)
        store.setDeleted("CIS 1100", true)
        store.setDisplayName("CIS 1600", to: "Discrete Math")
        store.setCanvasCourseID("CIS 1600", "1234567")

        // `LedgerWidgetReader` is a separate process and reads these by name. If
        // consolidating the app's copy orphaned the widget's, hidden and deleted
        // classes would keep appearing on the Home Screen.
        let hidden = Set(defaults.stringArray(forKey: SharedDefaults.hiddenCoursesKey) ?? [])
        let deleted = Set(defaults.stringArray(forKey: SharedDefaults.deletedCoursesKey) ?? [])
        let names = defaults
            .dictionary(forKey: SharedDefaults.courseNameOverridesKey) as? [String: String] ?? [:]
        let ids = defaults
            .dictionary(forKey: CoursePreferencesStore.legacyCanvasCourseIDsKey) as? [String: String] ?? [:]

        #expect(hidden == ["CIS 1200"])
        #expect(deleted == ["CIS 1100"])
        #expect(names == ["CIS 1600": "Discrete Math"])
        #expect(ids == ["CIS 1600": "1234567"])
    }

    @Test("The projection makes the fold a fixed point")
    func projectionMakesFoldAFixedPoint() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        // Because every write projects back onto the four legacy keys, those
        // keys always describe the canonical store — so folding them in again
        // folds the store into itself. Idempotence by construction rather than
        // by a pile of don't-clobber rules.
        let store = CoursePreferencesStore(defaults: defaults)
        store.setVisible("CIS 1200", false)
        store.setDisplayName("CIS 1600", to: "Discrete Math")
        let before = CoursePreferencesStore(defaults: defaults).byCourseKey

        #expect(CoursePreferencesStore.importLegacyCourseState(in: defaults) == 0)
        #expect(CoursePreferencesStore(defaults: defaults).byCourseKey == before)
    }
}
