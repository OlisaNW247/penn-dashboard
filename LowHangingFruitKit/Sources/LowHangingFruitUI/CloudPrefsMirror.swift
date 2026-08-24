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

    private var observerToken: NSObjectProtocol?

    /// Fired after an external (other-device) change pulled fresh values for
    /// one or more mirrored keys into `UserDefaults.lhf`. `AppState` uses
    /// this to re-read the affected in-memory state and rebuild the
    /// dashboard — see `AppState.reloadMirroredPreferences`.
    var onExternalChange: (([String]) -> Void)?

    /// - Parameter enabled: the user's Settings toggle state at the point
    ///   this instance was constructed (`AppState.cloudSyncEnabledAtLaunch`,
    ///   not the live, possibly-just-toggled `cloudSyncEnabled`) — mirroring
    ///   only starts at the next launch after the toggle is flipped, the
    ///   same "not worth swapping live state" reasoning `AppState
    ///   .setCloudSyncEnabled` documents for the assignment ledger itself.
    init(enabled: Bool) {
        self.isActive = enabled && !SharedDefaults.isTestRunner
        guard isActive else { return }

        let store = NSUbiquitousKeyValueStore.default
        // Documented kickstart: `synchronize()` asks the daemon to fetch any
        // changes made on other devices since this process last ran, ahead
        // of the first `didChangeExternallyNotification` (which otherwise
        // only fires for changes seen *after* this call).
        store.synchronize()
        // Seeds iCloud with this device's current values on every launch
        // sync is on. Whole-value last-writer-wins (see the type doc above)
        // makes this safe even if a genuinely newer value from another
        // device is mid-flight: that device's own next
        // `didChangeExternallyNotification` still wins the very next update,
        // it's just delayed by however long this round trip takes.
        pushAll()

        observerToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            self?.handleExternalChange(notification)
        }
    }

    deinit {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
    }

    /// Pushes every mirrored key's current `UserDefaults.lhf` value up to
    /// iCloud. Called once at construction (see `init`); also usable
    /// directly (e.g. by a future "force resync" affordance).
    func pushAll() {
        guard isActive else { return }
        for key in Self.mirroredKeys {
            push(key: key)
        }
    }

    /// Pushes one mirrored key's current `UserDefaults.lhf` value to iCloud.
    /// Callers are the exact functions in `AppState` that persist these keys
    /// locally (`persistHiddenCourses`, `persistDeletedCourses`,
    /// `renameCourse`, `setCourseContentDecision`) — one call added at the
    /// point each already writes to `UserDefaults.lhf`, guarded on
    /// `AppState.cloudSyncEnabled` at the call site. A key outside
    /// `mirroredKeys` is silently ignored rather than pushed — this class
    /// only ever touches its own frozen allowlist, on purpose.
    func push(key: String) {
        guard isActive, Self.mirroredKeys.contains(key) else { return }
        let store = NSUbiquitousKeyValueStore.default
        if let value = UserDefaults.lhf.object(forKey: key) {
            store.set(value, forKey: key)
        } else {
            // Absence is itself meaningful for these keys (e.g. "no course
            // has been renamed"), so a locally-cleared key removes the
            // iCloud copy too, rather than leaving a stale value behind for
            // the next pull to resurrect.
            store.removeObject(forKey: key)
        }
    }

    /// Pulls whichever mirrored keys changed on another device into
    /// `UserDefaults.lhf`, then notifies `onExternalChange` so the in-memory
    /// state derived from them gets rebuilt. Keys outside `mirroredKeys`
    /// (there shouldn't be any, since nothing else is ever pushed under this
    /// app's iCloud key-value container, but a future key added elsewhere in
    /// the same container is a possibility worth not reacting to) are
    /// ignored.
    private func handleExternalChange(_ notification: Notification) {
        guard isActive,
              let userInfo = notification.userInfo,
              let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
        else { return }

        let relevant = changedKeys.filter { Self.mirroredKeys.contains($0) }
        guard !relevant.isEmpty else { return }

        let store = NSUbiquitousKeyValueStore.default
        for key in relevant {
            if let value = store.object(forKey: key) {
                UserDefaults.lhf.set(value, forKey: key)
            } else {
                UserDefaults.lhf.removeObject(forKey: key)
            }
        }
        onExternalChange?(relevant)
    }
}
