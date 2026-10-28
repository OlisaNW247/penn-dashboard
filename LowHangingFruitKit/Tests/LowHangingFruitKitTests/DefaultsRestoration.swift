import Foundation
@testable import LowHangingFruitKit

/// Puts `UserDefaults.lhf` back the way a test found it, when the suite
/// instance that owns it goes away: give the suite
/// `private let defaultsGuard = LHFDefaultsGuard()`.
///
/// Under `swift test` that domain is the test runner's `.standard`, shared by
/// every suite in the run and, on a dev Mac, by any other `swift test` running
/// at the same time. A test that builds an `AppState` writes into it without
/// meaning to: `rebuildDashboardItems` merges every Canvas course id it sees
/// into the `coursePreferences` blob, `disconnectCanvas` removes a dozen keys,
/// and `init` stamps first-run markers. A suite that backs up only the keys it
/// knows about leaves the rest behind, and the next suite then reads "TWIN 7001"
/// as one of the student's classes (the shared-`UserDefaults` trap in
/// CLAUDE.md; it is how `ProfileTabTests` and `AskKnowledgeWiringTests` come
/// to fail with another suite's class codes in their lists).
///
/// swift-testing makes a fresh instance of a suite type for every test, so a
/// stored property that snapshots in `init` and restores in `deinit` brackets
/// each test with no per-test code. It snapshots the whole domain and restores
/// exactly the keys the test changed: a key it added is removed, one it
/// changed or removed is put back, and keys it left alone, including everything
/// inherited from the global domain, are not touched. Nothing here is per-key
/// knowledge, so it cannot go stale as `AppState` grows new keys. It cannot
/// cover a task a test leaves running that writes later.
///
/// A `TestScoping` suite trait would say this more directly, and was tried
/// first: with this toolchain it traps the whole test process on launch
/// (signal 5) for `@MainActor` suites, so the guard is an object instead.
final class LHFDefaultsGuard: @unchecked Sendable {
    private let snapshot = DefaultsSnapshot()
    deinit { snapshot.restore() }
}

/// The app-visible contents of `UserDefaults.lhf` at one moment.
/// `@unchecked Sendable`: a plain dictionary of property-list values, copied
/// at the time it is taken and never mutated.
struct DefaultsSnapshot: @unchecked Sendable {
    private let values: [String: Any]

    init(of defaults: UserDefaults = .lhf) {
        values = defaults.dictionaryRepresentation()
    }

    /// Restores `defaults` to this snapshot, touching only the keys that differ.
    func restore(to defaults: UserDefaults = .lhf) {
        let after = defaults.dictionaryRepresentation()
        for key in Set(values.keys).union(after.keys) {
            switch (values[key], after[key]) {
            case let (old?, new?):
                if !(old as AnyObject).isEqual(new) { defaults.set(old, forKey: key) }
            case let (old?, nil):
                defaults.set(old, forKey: key)
            case (nil, _?):
                defaults.removeObject(forKey: key)
            case (nil, nil):
                break
            }
        }
    }
}
