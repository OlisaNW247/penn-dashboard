import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `CourseContentDecisionStore` (docs/READINGS_COURSES_PLAN.md Phase 2) is the
/// JSON-blob persistence for the readings/silent-course opt-in decision, kept
/// under `UserDefaults.lhf` — never `.standard` — at "courseContentDecisionsV1".
///
/// `UserDefaults.lhf` is process-wide, so every test here backs up and restores
/// the exact key it touches (the same discipline `IntroFlowTests.withFlags` and
/// `PreviewModeTests` use for their own keys). The suite is `.serialized`
/// because the whole map is re-encoded as one blob on every `save` — two tests
/// racing a backup/restore of that single key against each other (rather than
/// against some *other* file's tests, which never touch this key) could lose
/// each other's writes under Swift Testing's default parallel execution, the
/// same reasoning `SessionCookieStoreTests` documents for its own shared
/// process-wide resource.
@Suite("Course content decision store", .serialized)
struct CourseContentDecisionStoreTests {
    private static let key = "courseContentDecisionsV1"

    /// Snapshots whatever is currently at the key, runs `body` against a
    /// cleared slate, then restores exactly what was there before — including
    /// "nothing was there," which `removeObject` reproduces rather than a
    /// `save([:])` (which would instead persist an empty-but-present blob).
    private func withCleanStore(_ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let saved = defaults.data(forKey: Self.key)
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

    // Synthetic-only fixtures (project rule) — fake course code, no real ids.
    private static let course = "LGST 9999"

    @Test("save then load round-trips choice, fingerprint, and decidedAt")
    func roundTrip() {
        withCleanStore {
            let decidedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let decision = CourseContentDecision(
                choice: .include,
                fingerprint: "readings:10",
                decidedAt: decidedAt
            )
            CourseContentDecisionStore.save([Self.course: decision])

            let loaded = CourseContentDecisionStore.load()
            let roundTripped = loaded[Self.course]
            #expect(roundTripped?.choice == .include)
            #expect(roundTripped?.fingerprint == "readings:10")
            // Default JSON date encoding round-trips through a Double
            // (timeIntervalSinceReferenceDate); allow a hair of tolerance
            // rather than assuming bit-for-bit float equality.
            #expect(abs((roundTripped?.decidedAt ?? .distantPast).timeIntervalSince(decidedAt)) < 0.001)
        }
    }

    @Test("multiple courses persist independently")
    func multipleCoursesRoundTrip() {
        withCleanStore {
            let decisions: [String: CourseContentDecision] = [
                Self.course: CourseContentDecision(choice: .include, fingerprint: "readings:5", decidedAt: Date()),
                "CIS 9999": CourseContentDecision(choice: .exclude, fingerprint: "silent:0", decidedAt: Date()),
            ]
            CourseContentDecisionStore.save(decisions)

            let loaded = CourseContentDecisionStore.load()
            #expect(loaded[Self.course]?.choice == .include)
            #expect(loaded["CIS 9999"]?.choice == .exclude)
        }
    }

    @Test("clear() empties the store")
    func clearEmpties() {
        withCleanStore {
            CourseContentDecisionStore.save([
                Self.course: CourseContentDecision(choice: .exclude, fingerprint: "silent:none", decidedAt: Date()),
            ])
            #expect(!CourseContentDecisionStore.load().isEmpty)

            CourseContentDecisionStore.clear()
            #expect(CourseContentDecisionStore.load().isEmpty)
        }
    }

    @Test("no stored value loads as an empty map")
    func missingKeyLoadsEmpty() {
        withCleanStore {
            #expect(CourseContentDecisionStore.load().isEmpty)
        }
    }

    @Test("garbage data at the key loads as empty rather than crashing")
    func garbageDataIsIgnored() {
        withCleanStore {
            UserDefaults.lhf.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: Self.key)
            #expect(CourseContentDecisionStore.load().isEmpty)
        }
    }

    @Test("a value of the wrong type at the key loads as empty rather than crashing")
    func wrongTypeIsIgnored() {
        withCleanStore {
            // `load()` expects `Data`; a stray String at the same key (e.g. from
            // a hand-edited defaults plist) must degrade to "no decisions,"
            // never a crash.
            UserDefaults.lhf.set("not data", forKey: Self.key)
            #expect(CourseContentDecisionStore.load().isEmpty)
        }
    }
}
