import Foundation
import LowHangingFruitKit

/// Mirrors a small, fixed allowlist of `UserDefaults.lhf` preference keys
/// into the user's own `NSUbiquitousKeyValueStore` when iCloud sync is
/// turned on (Settings → "Sync between my devices",
/// docs/LAPTOP_INTEGRATION_PLAN.md Tier 2 item 2). `NSUbiquitousKeyValueStore`
/// is cross-platform (unlike WidgetKit or `PageTabViewStyle`), so this file
/// needs no `#if os(iOS)` guard to keep `swift test`'s macOS build green —
/// but it MUST be inert whenever `SharedDefaults.isTestRunner` is true, or a
/// `swift test` run would reach for real iCloud key-value sync the same way
/// `SharedDefaults.sharedSuite()` used to reach the real Mac app's App Group
/// container before that guard existed.
///
/// **Removals and first meetings (hardening plan B11, DAT-09).** Two rules
/// sit on top of the semantics below, both decided by pure functions in
/// `CloudPrefsMerge` so they can be tested without iCloud. A removal is never
/// inferred from absence: the launch seed pushes only the values this device
/// has, and a key is removed from iCloud only through `pushRemoval`, an
/// explicit act (disconnecting Canvas clears the content decisions). And the
/// first launch with sync on merges this device's copy of each key with
/// iCloud's instead of overwriting either. Both fix the same bug: a second
/// device switching sync on had no preferences of its own, so the old seed
/// deleted every key the first device had pushed, and the first device then
/// pulled those deletions.
///
/// **Conflict semantics: whole-value, last-writer-wins.** Every mirrored key
/// holds one small JSON blob or a short array/dictionary — the entire
/// decision map, the entire deleted-courses set, the entire rename map, the
/// entire hidden-courses set — never a per-item record. So there is nothing
/// to merge at the key-value layer: when a change arrives from
/// `didChangeExternallyNotification`, the incoming value simply *replaces*
/// whatever this device had for that key, exactly the way a second device's
/// Settings screen replaced its own copy when the user acted there. That is
/// safe here specifically because these are small, whole, user-authored
/// preference maps — losing an in-flight edit to a race is, at worst, "redo
/// one tap" on whichever device typed second, never a silently dropped
/// assignment (the assignment ledger itself does NOT go through this class;
/// it mirrors via SwiftData's own CloudKit configuration and merges through
/// `absorb(_:)`, which has real per-row conflict handling).
///
/// Not a `@MainActor` type on purpose: `NSUbiquitousKeyValueStore` is
/// documented thread-safe, and `didChangeExternallyNotification` can arrive
/// on a background queue depending on how the system delivers it. The
/// `queue: .main` passed to the observer below is what actually gets
/// `onExternalChange`'s callback (and therefore `AppState.reloadMirroredPreferences`,
/// which touches `@Published` properties) back onto the main actor.
///
/// `@unchecked Sendable`, not `@MainActor`: this package builds under Swift 6
/// language mode (`Package.swift` is tools-version 6.0), so a class captured
/// by `NotificationCenter`'s `addObserver(using:)` — an escaping closure the
/// system can invoke off whatever thread it likes, even though `queue: .main`
/// is what we pass below — must be `Sendable`. The `@unchecked` opt-out is
/// safe here because every stored property this type mutates after `init`
/// (`observerToken`, `onExternalChange`) is, in practice, only ever touched
/// from the main actor: `AppState` (a `@MainActor` type) is this class's only
/// owner, constructs it and assigns `onExternalChange` entirely within its
/// own `init`, and the `didChangeExternallyNotification` observer below is
/// explicitly registered with `queue: .main`.
///
/// The one call this class makes back into `AppState` — `onExternalChange` —
/// is itself wrapped in `Task { @MainActor in ... }` at the call site (see
/// `AppState.init`), which is what actually re-enters the main actor to call
/// `AppState.reloadMirroredPreferences()` safely; nothing in this file calls
/// MainActor-isolated code directly from a non-isolated context.
final class CloudPrefsMirror: @unchecked Sendable {
    /// The exact, frozen set of `UserDefaults.lhf` keys this class ever
    /// touches — deliberately small. Real key names, as found in
    /// `AppState.swift` / `CourseContentDecisions.swift`:
    ///   - `"courseContentDecisionsV1"` — `CourseContentDecisionStore`'s key
    ///     for the readings/silent-course opt-in map (`[String:
    ///     CourseContentDecision]`, stored as `Data`).
    ///   - `"deletedCourseKeys"` — `AppState.deletedCoursesKey`, the deleted
    ///     classes list (`[String]`).
    ///   - `"courseNameOverrides"` — `AppState.courseNameOverridesKey`, the
    ///     per-course rename map (`[String: String]`).
    ///   - `"hiddenCourseKeys"` — `AppState.hiddenCoursesKey`, the backing
    ///     set for `AppState.isCourseSelected`'s class-picker on/off state
    ///     (`[String]`).
    /// Credentials (`canvasICSURL`, session cookies) are never in this list —
    /// see `SharedDefaultsMigration.legacyKeys`'s comment for why the feed
    /// URL in particular is a bearer credential that must never leave the
    /// Keychain.
    static let mirroredKeys: [String] = [
        // The canonical per-course record (v4's consolidated
        // `CoursePreferencesStore` blob, stored as `Data`). The three legacy
        // keys below are that blob's widget-visible projection — mirroring
        // them too keeps the *receiving* device's widget correct immediately,
        // since a pull writes the keys but runs no `persist()` there.
        CoursePreferencesStore.storageKey,
        "courseContentDecisionsV1",
        "deletedCourseKeys",
        "courseNameOverrides",
        "hiddenCourseKeys",
    ]

    /// True only when this instance was constructed with `enabled: true` AND
    /// this process is not a test runner. Every push/pull entry point below
    /// checks this FIRST — that ordering is what a test can actually observe
    /// (see `CloudSyncToggleTests`), since there is no way to assert "no
    /// write happened" against the real `NSUbiquitousKeyValueStore` from a
    /// sandboxed `swift test` run.
    let isActive: Bool

    /// Set once this device has merged with iCloud for the first time since
    /// sync was last off. A launch with sync OFF clears it, so turning sync
    /// off and on again is a first meeting again. `UserDefaults.lhf`, and not
    /// in `mirroredKeys`: a second device has its own.
    static let firstMergeDoneKey = "cloudPrefsFirstMergeDoneV1"

    /// How long a first enable waits for iCloud's initial download before it
    /// merges with whatever it has. The download normally lands in seconds;
    /// the wait only matters when it never does (no iCloud data yet, or no
    /// connection), where a late merge is better than seeding blind.
    static let initialSyncGrace: TimeInterval = 20

    private var observerToken: NSObjectProtocol?

    /// True between a first enable that found iCloud empty and the moment its
    /// initial download (or the grace period) lets the merge run. Guarded by
    /// `stateLock`: set on the launching thread, cleared from the observer
    /// (main queue) and the grace timer.
    private var firstMergePending = false
    private let stateLock = NSLock()

    /// Fired after an external (other-device) change pulled fresh values for
    /// one or more mirrored keys into `UserDefaults.lhf`. `AppState` uses
    /// this to re-read the affected in-memory state and rebuild the
    /// dashboard — see `AppState.reloadMirroredPreferences`. Also fired, on the
    /// main queue after `init` returns, when the first-enable merge adopted
    /// values from iCloud, since `AppState` assigns it just after construction.
    var onExternalChange: (([String]) -> Void)?

    /// - Parameter enabled: the user's Settings toggle state at the point
    ///   this instance was constructed (`AppState.cloudSyncEnabledAtLaunch`,
    ///   not the live, possibly-just-toggled `cloudSyncEnabled`) — mirroring
    ///   only starts at the next launch after the toggle is flipped, the
    ///   same "not worth swapping live state" reasoning `AppState
    ///   .setCloudSyncEnabled` documents for the assignment ledger itself.
    init(enabled: Bool) {
        self.isActive = enabled && !SharedDefaults.isTestRunner
        guard isActive else {
            // Sync is off this launch, so the next time it is on is a first
            // meeting again. Never under a test runner, whose `.lhf` is the
            // process-wide `.standard`.
            if !enabled && !SharedDefaults.isTestRunner {
                UserDefaults.lhf.removeObject(forKey: Self.firstMergeDoneKey)
            }
            return
        }

        let store = NSUbiquitousKeyValueStore.default
        // Documented kickstart: `synchronize()` asks the daemon to fetch any
        // changes made on other devices since this process last ran, ahead
        // of the first `didChangeExternallyNotification` (which otherwise
        // only fires for changes seen *after* this call).
        store.synchronize()

        // Registered before the seed so a download that lands during it is
        // not missed.
        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            self?.handleExternalChange(notification)
        }

        let remoteHasAny = Self.mirroredKeys.contains { store.object(forKey: $0) != nil }
        switch CloudPrefsMerge.launchAction(
            markerSet: UserDefaults.lhf.bool(forKey: Self.firstMergeDoneKey),
            remoteHasAny: remoteHasAny
        ) {
        case .seedOnly:
            // Seeds iCloud with this device's current values on every launch
            // sync is on, present values only (see `pushAll`).
            pushAll()
        case .mergeNow:
            runFirstMerge()
        case .deferMerge:
            setFirstMergePending(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialSyncGrace) { [weak self] in
                self?.finishDeferredMergeIfPending()
            }
        }
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    /// Pushes every mirrored key's current `UserDefaults.lhf` value up to
    /// iCloud — the values this device HAS, and only those. A key it has no
    /// value for is skipped, never removed from iCloud (see `CloudPrefsMerge`:
    /// absence is not authorship). Called once at construction on an ordinary
    /// launch (see `init`); also usable directly (e.g. by a future "force
    /// resync" affordance).
    func pushAll() {
        guard isActive else { return }
        let steps = CloudPrefsMerge.seedSteps(
            keys: Self.mirroredKeys,
            local: localValues(),
            remote: remoteValues(NSUbiquitousKeyValueStore.default)
        )
        _ = apply(steps, to: NSUbiquitousKeyValueStore.default)
    }

    /// Pushes one mirrored key's current `UserDefaults.lhf` value to iCloud.
    /// Callers are the exact functions in `AppState` that persist these keys
    /// locally (`CoursePreferencesStore.didChange`,
    /// `renameCourse`, `setCourseContentDecision`) — one call added at the
    /// point each already writes to `UserDefaults.lhf`, guarded on
    /// `AppState.cloudSyncEnabled` at the call site. A key outside
    /// `mirroredKeys` is silently ignored rather than pushed — this class
    /// only ever touches its own frozen allowlist, on purpose.
    ///
    /// **Never a removal.** A key with no local value is a no-op here. The one
    /// place that used to push removals from this method was the launch seed,
    /// where "no local value" meant "this device never had one", not "the
    /// student cleared it". An explicit clear goes through `pushRemoval`.
    /// Skipped while the first-enable merge is still waiting for iCloud's
    /// download: the merge pushes the current local value itself, and pushing
    /// now would write over data this device has not received.
    func push(key: String) {
        guard isActive, Self.mirroredKeys.contains(key) else { return }
        guard !isFirstMergePending else { return }
        guard let value = UserDefaults.lhf.object(forKey: key) else { return }
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
    }

    /// Removes one mirrored key from iCloud, because THIS device's student just
    /// cleared it (`AppState.disconnectCanvas` wipes the content decisions, and
    /// without this the next pull would resurrect them). The only removal the
    /// mirror makes; callers state it explicitly so that a missing local value
    /// can never be mistaken for one.
    func pushRemoval(key: String) {
        guard isActive, Self.mirroredKeys.contains(key) else { return }
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }

    /// Pulls whichever mirrored keys changed on another device into
    /// `UserDefaults.lhf`, then notifies `onExternalChange` so the in-memory
    /// state derived from them gets rebuilt. Keys outside `mirroredKeys`
    /// (there shouldn't be any, since nothing else is ever pushed under this
    /// app's iCloud key-value container, but a future key added elsewhere in
    /// the same container is a possibility worth not reacting to) are
    /// ignored.
    ///
    /// While the first-enable merge is pending, whatever arrives is merged
    /// with this device's copy instead of replacing it, and the merge is
    /// finished by the initial-sync delivery (or the grace timer).
    private func handleExternalChange(_ notification: Notification) {
        guard isActive,
              let userInfo = notification.userInfo,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        else { return }

        let relevant = changedKeys.filter { Self.mirroredKeys.contains($0) }
        guard !relevant.isEmpty else { return }

        if isFirstMergePending {
            let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            runFirstMerge(finishing: reason == NSUbiquitousKeyValueStoreInitialSyncChange)
            return
        }

        let store = NSUbiquitousKeyValueStore.default
        for key in relevant {
            if let value = store.object(forKey: key) {
                UserDefaults.lhf.set(value, forKey: key)
            } else {
                // Another device cleared this key (`pushRemoval`), so this one
                // follows. Not the launch seed: that never removes anything.
                UserDefaults.lhf.removeObject(forKey: key)
            }
        }
        onExternalChange?(relevant)
    }

    // MARK: - First-enable merge

    private var isFirstMergePending: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return firstMergePending
    }

    private func setFirstMergePending(_ value: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        firstMergePending = value
    }

    /// Merges this device's mirrored keys with iCloud's (`CloudPrefsMerge
    /// .mergeSteps`) and writes each side what it lacks. Idempotent, so it can
    /// run again as more of iCloud's data arrives. `finishing` ends the
    /// pending state and records that this device has now met iCloud.
    private func runFirstMerge(finishing: Bool = true) {
        let store = NSUbiquitousKeyValueStore.default
        let steps = CloudPrefsMerge.mergeSteps(
            keys: Self.mirroredKeys,
            local: localValues(),
            remote: remoteValues(store)
        )
        let adopted = apply(steps, to: store)
        if finishing {
            setFirstMergePending(false)
            UserDefaults.lhf.set(true, forKey: Self.firstMergeDoneKey)
        }
        // `AppState` assigns `onExternalChange` after it constructs this
        // object, so a merge that ran inside `init` tells it on the next turn
        // of the main queue.
        if !adopted.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onExternalChange?(adopted)
            }
        }
    }

    /// The grace timer's half: the initial download never announced itself, so
    /// merge with what the cache holds now (seeding iCloud if it is still
    /// empty), unless the delivery already finished the job.
    private func finishDeferredMergeIfPending() {
        guard isFirstMergePending else { return }
        runFirstMerge()
    }

    /// Performs `steps`, returning the keys written to this device's defaults.
    private func apply(_ steps: [CloudPrefsMerge.Step], to store: NSUbiquitousKeyValueStore) -> [String] {
        var adopted: [String] = []
        for step in steps {
            switch step {
            case let .setRemote(key, value):
                store.set(value, forKey: key)
            case let .setLocal(key, value):
                UserDefaults.lhf.set(value, forKey: key)
                adopted.append(key)
            }
        }
        return adopted
    }

    private func localValues() -> [String: Any] {
        var values: [String: Any] = [:]
        for key in Self.mirroredKeys {
            if let value = UserDefaults.lhf.object(forKey: key) { values[key] = value }
        }
        return values
    }

    private func remoteValues(_ store: NSUbiquitousKeyValueStore) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in Self.mirroredKeys {
            if let value = store.object(forKey: key) { values[key] = value }
        }
        return values
    }
}
