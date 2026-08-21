import Foundation
import Testing
@testable import LowHangingFruitKit

/// Moving preferences into the App Group suite is the change that lets the
/// widget see completions, hidden classes and manual assignments at all. The
/// risk it carries is the opposite one: an upgrading user whose completions,
/// class selection or grade history don't come across, or come across and then
/// get overwritten by the stale copies still sitting in `.standard`.
///
/// Every test here works in its own throwaway suites — it never touches
/// `.standard` or the real App Group — so it can't leave the state behind that
/// `GradeWatcherCourseResolutionTests` warns about.
@Suite("Shared defaults migration")
struct SharedDefaultsMigrationTests {

    private func withTempSuites(_ body: (UserDefaults, UserDefaults) -> Void) {
        let legacyName = "lhf.test.legacy.\(UUID().uuidString)"
        let sharedName = "lhf.test.shared.\(UUID().uuidString)"
        guard let legacy = UserDefaults(suiteName: legacyName),
              let shared = UserDefaults(suiteName: sharedName)
        else { Issue.record("could not create test suites"); return }
        defer {
            legacy.removePersistentDomain(forName: legacyName)
            shared.removePersistentDomain(forName: sharedName)
        }
        body(legacy, shared)
    }

    // MARK: - The upgrade path

    /// The whole point: a user who already has data keeps it, across every
    /// value type the app actually stores.
    @Test("an upgrading user's preferences arrive in the shared suite intact")
    func copiesExistingPreferences() {
        withTempSuites { legacy, shared in
            let completionDates = try? JSONEncoder().encode(["a1": Date(timeIntervalSince1970: 100)])
            legacy.set("Marco", forKey: "userName")
            legacy.set(true, forKey: "hasCompletedOnboarding")
            legacy.set(["CIS 3200", "MATH 1400"], forKey: "hiddenCourseKeys")
            legacy.set(["a1", "a2"], forKey: "completedAssignmentIDs")
            legacy.set(completionDates, forKey: "completionDates")
            legacy.set(["CIS 3200": "900001"], forKey: "canvasCourseIDsByCode")
            legacy.set(9, forKey: "notif.digestHour")
            legacy.set(Data([0x01]), forKey: "gradeWatcherHistory")

            let outcome = SharedDefaultsMigration.run(from: legacy, to: shared)

            guard case .migrated(let keys) = outcome else {
                Issue.record("expected a migration, got \(outcome)")
                return
            }
            #expect(keys.count == 8)

            #expect(shared.string(forKey: "userName") == "Marco")
            #expect(shared.bool(forKey: "hasCompletedOnboarding"))
            #expect(shared.stringArray(forKey: "hiddenCourseKeys") == ["CIS 3200", "MATH 1400"])
            #expect(shared.stringArray(forKey: "completedAssignmentIDs") == ["a1", "a2"])
            #expect(shared.data(forKey: "completionDates") == completionDates)
            #expect(shared.dictionary(forKey: "canvasCourseIDsByCode") as? [String: String]
                    == ["CIS 3200": "900001"])
            #expect(shared.integer(forKey: "notif.digestHour") == 9)
            #expect(shared.data(forKey: "gradeWatcherHistory") == Data([0x01]))
        }
    }

    /// Only the declared keys travel. Anything else in the app's domain — system
    /// keys, third-party keys — has no business in the shared container.
    @Test("unrelated keys are left where they are")
    func ignoresUnknownKeys() {
        withTempSuites { legacy, shared in
            legacy.set("yes", forKey: "someUnrelatedKey")
            SharedDefaultsMigration.run(from: legacy, to: shared)
            #expect(shared.object(forKey: "someUnrelatedKey") == nil)
        }
    }

    /// The originals stay put, so a user who rolls back to the previous build
    /// still finds their data.
    @Test("the legacy domain is copied from, not emptied")
    func doesNotDeleteLegacyValues() {
        withTempSuites { legacy, shared in
            legacy.set("Marco", forKey: "userName")
            SharedDefaultsMigration.run(from: legacy, to: shared)
            #expect(legacy.string(forKey: "userName") == "Marco")
        }
    }

    @Test("a fresh install has nothing to copy but still records that it ran")
    func freshInstallMarksDone() {
        withTempSuites { legacy, shared in
            #expect(SharedDefaultsMigration.run(from: legacy, to: shared) == .migrated(keys: []))
            #expect(shared.bool(forKey: SharedDefaultsMigration.markerKey))
        }
    }

    // MARK: - Already migrated

    @Test("a second run is a no-op")
    func secondRunIsANoOp() {
        withTempSuites { legacy, shared in
            legacy.set("Marco", forKey: "userName")
            SharedDefaultsMigration.run(from: legacy, to: shared)

            #expect(SharedDefaultsMigration.run(from: legacy, to: shared) == .alreadyMigrated)
        }
    }

    /// The failure this guards against: the user renames a class (or ticks work
    /// off) *after* migrating, and a later launch re-copies the stale original
    /// over the top. The marker stops it — and so, independently, does the
    /// never-overwrite rule.
    @Test("re-running cannot clobber values written after the migration")
    func doesNotClobberNewerValues() {
        withTempSuites { legacy, shared in
            legacy.set(["a1"], forKey: "completedAssignmentIDs")
            SharedDefaultsMigration.run(from: legacy, to: shared)

            // The user has since finished more work; the stale legacy copy still
            // holds only the original id.
            shared.set(["a1", "a2", "a3"], forKey: "completedAssignmentIDs")

            SharedDefaultsMigration.run(from: legacy, to: shared)
            #expect(shared.stringArray(forKey: "completedAssignmentIDs") == ["a1", "a2", "a3"])
        }
    }

    /// Belt-and-braces check with the marker deliberately cleared, proving the
    /// never-overwrite rule holds on its own rather than only via the guard.
    @Test("an existing value survives even with the marker missing")
    func neverOverwritesWithoutTheMarker() {
        withTempSuites { legacy, shared in
            legacy.set("Old", forKey: "userName")
            shared.set("New", forKey: "userName")

            let outcome = SharedDefaultsMigration.run(from: legacy, to: shared)

            #expect(outcome == .migrated(keys: []))
            #expect(shared.string(forKey: "userName") == "New")
        }
    }

    // MARK: - No App Group available

    /// Unit tests, previews and unsigned builds have no entitlement. Nothing
    /// must be written — above all not the marker, or a later launch that *does*
    /// have the group would find itself already "migrated" and strand the data.
    @Test("no shared suite migrates nothing and records nothing")
    func noSharedSuiteIsInert() {
        withTempSuites { legacy, _ in
            legacy.set("Marco", forKey: "userName")

            #expect(SharedDefaultsMigration.run(from: legacy, to: nil) == .noSharedSuite)
            #expect(legacy.object(forKey: SharedDefaultsMigration.markerKey) == nil)
        }
    }

    /// When the group is unavailable the accessor falls back to `.standard`,
    /// which makes source and destination the same domain. That is not a
    /// migration and must not be marked as one.
    @Test("migrating a domain onto itself is not a migration")
    func sameDomainIsNotAMigration() {
        withTempSuites { legacy, _ in
            #expect(SharedDefaultsMigration.run(from: legacy, to: legacy) == .noSharedSuite)
            #expect(legacy.object(forKey: SharedDefaultsMigration.markerKey) == nil)
        }
    }

    // MARK: - The accessor

    /// The fallback contract: with or without an App Group, `UserDefaults.lhf`
    /// resolves to a usable store rather than crashing or dropping writes.
    @Test("the accessor always yields a usable store")
    func accessorRoundTrips() {
        let key = "lhf.test.roundTrip.\(UUID().uuidString)"
        defer { UserDefaults.lhf.removeObject(forKey: key) }
        UserDefaults.lhf.set("ok", forKey: key)
        #expect(UserDefaults.lhf.string(forKey: key) == "ok")
    }

    /// The reason for the whole change: a value the app writes is readable by a
    /// *separately opened* handle on the App Group suite — which is all the
    /// widget extension ever gets. Where there's no entitlement there is no
    /// shared suite to check, and the fallback is covered by the test above.
    @Test("a value written by the app is visible to another process's handle")
    func sharedSuiteIsReadableFromAFreshHandle() {
        guard let suite = SharedDefaults.sharedSuite() else { return }
        let key = "lhf.test.crossProcess.\(UUID().uuidString)"
        defer { suite.removeObject(forKey: key) }
        suite.set("visible", forKey: key)

        let reopened = UserDefaults(suiteName: SharedDefaults.appGroupID)
        #expect(reopened?.string(forKey: key) == "visible")
    }

    // MARK: - Coverage of the key list

    /// The migration list has to be *complete as of this change* — a key left
    /// off is silently abandoned data for every existing user. Pinned against
    /// the three files that declared them.
    ///
    /// `canvasICSURL` is the one deliberate omission: it was on this list when
    /// preferences moved to the App Group, but the Canvas login hardening then
    /// moved the feed URL — a bearer credential embedding a per-user token —
    /// out of UserDefaults entirely and into the Keychain via
    /// `ICSFeedURLStore`. It migrates by that route instead, so it must be
    /// absent here rather than copied into unencrypted, backed-up storage.
    @Test("every key the app persisted is on the migration list")
    func keyListIsComplete() {
        let expected: Set<String> = [
            "userName", "completedAssignmentIDs", "completionDates",
            "hiddenCourseKeys", "deletedCourseKeys", "recurringTasks", "manualAssignments",
            "canvasDiscoveryConnected", "gradescopeConnected", "hasCompletedOnboarding",
            "isPreviewMode", "appearanceMode", "courseNameOverrides",
            "canvasCourseIDsByCode", "gradeBaselinedCourses",
            "gradeWatcherManualWeights", "gradeWatcherConfirmedGradescopeMappings",
            "gradeWatcherHistory", "gradeWatcherWatchedCourses",
            "gradeWatcherSyllabusSchemes", "gradeWatcherConfirmedCategoryMappings",
            "notif.enabled", "notif.leadOffsets", "notif.digestEnabled",
            "notif.digestHour", "notif.digestMinute",
        ]
        #expect(Set(SharedDefaultsMigration.legacyKeys) == expected)
        // No duplicates — a repeat would double-count the migrated key list.
        #expect(SharedDefaultsMigration.legacyKeys.count == expected.count)
        // Guard against a future regression re-adding the credential to the
        // copy list: `canvasICSURL` must never travel through the shared
        // suite, only through `ICSFeedURLStore` into the Keychain.
        #expect(
            !SharedDefaultsMigration.legacyKeys.contains("canvasICSURL"),
            "canvasICSURL is a bearer credential (Canvas feed token embedded in the URL) and must migrate via ICSFeedURLStore into the Keychain, not be copied into the shared App Group suite"
        )
    }

    /// The migration is worthless if a read still goes to the app's private
    /// domain, because the widget can't follow it there. Scans the UI sources
    /// rather than trusting review. Skipped when the checkout isn't alongside
    /// the tests (a prebuilt test bundle).
    ///
    /// `ICSFeedURLStore.swift` is a named, narrow exception: `canvasICSURL` is
    /// no longer migrated through the shared suite at all (see
    /// `keyListIsComplete()`), so that file has to fall back to
    /// `UserDefaults.standard` itself, once, to pick up a pre-hardening value
    /// left in the app-private domain before copying it into the Keychain.
    /// Every other UI source must still fail this check.
    @Test("no preference read is left pointing at the private domain")
    func uiSourcesUseTheSharedAccessor() throws {
        // The one file allowed to reference `UserDefaults.standard`, and only
        // for the one-time migration read described above.
        let filesAllowedToUseStandardDefaults: Set<String> = ["ICSFeedURLStore.swift"]

        let sources = URL(fileURLWithPath: #filePath)      // .../Tests/LowHangingFruitKitTests/<this>
            .deletingLastPathComponent()                    // .../Tests/LowHangingFruitKitTests
            .deletingLastPathComponent()                    // .../Tests
            .deletingLastPathComponent()                    // .../LowHangingFruitKit
            .appendingPathComponent("Sources/LowHangingFruitUI")
        // A prebuilt test bundle run away from the checkout has nothing to scan.
        guard FileManager.default.fileExists(atPath: sources.path) else { return }

        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if filesAllowedToUseStandardDefaults.contains(file.lastPathComponent) {
                // The exception earns its place: the file's `.standard` usage
                // must actually be the documented legacy-migration read, not
                // some unrelated preference that snuck in later.
                #expect(
                    text.contains("UserDefaults.standard"),
                    "\(file.lastPathComponent) is listed as the migration exception but no longer reads UserDefaults.standard at all — remove it from the exception list"
                )
                #expect(
                    text.contains("legacyUserDefaultsKey"),
                    "\(file.lastPathComponent) reads UserDefaults.standard but isn't tied to the documented legacy migration key — this looks like a new, undocumented private-domain read rather than the one-time canvasICSURL migration"
                )
                continue
            }
            #expect(
                !text.contains("UserDefaults.standard"),
                "\(file.lastPathComponent) still reads the app-private defaults domain"
            )
        }
    }
}
