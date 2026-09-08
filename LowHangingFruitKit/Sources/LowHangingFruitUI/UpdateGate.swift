import Foundation
import LowHangingFruitKit

/// Where the hosted update manifest lives.
///
/// **This ships `nil` on purpose.** Nobody has hosted the manifest file yet,
/// and `nil` is the one value that keeps the whole feature inert until
/// someone does: `UpdateGateStore` never fetches when `manifestURL` is `nil`,
/// so every launch simply resolves to `.ok` (or, offline, to whatever the
/// cache already remembers). That is exactly the "fail open" behavior this
/// gate is built around, so shipping the constant unset is safe — it is not
/// a TODO left half-wired, it is the deliberate off position of a switch that
/// only a maintainer who has actually stood up hosting should flip.
///
/// When that day comes, the expected shape is a small, publicly-readable
/// static JSON file — e.g. a raw file served off `raw.githubusercontent.com`
/// (`https://raw.githubusercontent.com/<owner>/<repo>/main/update-manifest.json`)
/// decoding to the four fields `UpdatePolicy` knows how to sanitize. The
/// request `UpdateManifestClient` makes carries no query parameters, no
/// custom headers and no device identifier of any kind — the whole point of
/// this feature is a version check, not a phone-home, and the app must keep
/// sending nothing that identifies the student or the device even once this
/// is turned on.
enum UpdateManifestSource {
    static let url: URL? = nil
}

/// Decides, once per launch and again on every foreground, whether the
/// running build is fine, could update, or must stop — and owns the two bits
/// of state SwiftUI needs to render that decision (`RootView.swift` reads
/// both). This is the only place in `LowHangingFruitUI` that talks to
/// `UpdateManifestClient`/`UpdatePolicyCache`; `UpdateRequiredView` and
/// `UpdateAvailableBanner` are both pure presentation over whatever this
/// store publishes.
///
/// **Fail open is the load-bearing property of this type, not an
/// afterthought.** This app holds the student's only copy of their own
/// academic record, and a version check that cannot complete — no network,
/// captive-portal wifi, DNS failure, a 404 on the manifest, a timeout,
/// malformed JSON, an unset `manifestURL`, an unparseable installed version —
/// must never turn into a block. `refresh()` below only ever *advances*
/// `verdict` toward whatever a successfully-decoded policy says; on any
/// thrown error it leaves the previous verdict exactly as it was. That
/// asymmetry is deliberate: it is fine (expected, even) for a flaky network
/// to fail to *clear* a block a maintainer genuinely shipped, but it must
/// never be able to *invent* one nobody configured, and it must never
/// downgrade a real block into `.ok` just because the retry that would have
/// confirmed it happened to drop.
@MainActor
final class UpdateGateStore: ObservableObject {
    @Published private(set) var verdict: UpdateVerdict = .ok

    /// The most recently known policy's `appStoreURL`, tracked alongside
    /// `verdict` rather than inside it. `UpdateVerdict.updateRequired` only
    /// carries `minimum` and `message` — see `UpdatePolicy.swift` in the
    /// Kit, which is frozen for this task — because the verdict type's job
    /// is a pure version comparison, not a UI payload. `UpdateRequiredView`
    /// still needs a link to send the student to, so the store surfaces the
    /// one extra field it requires as its own published property instead of
    /// smuggling a whole `UpdatePolicy` through an enum case that was never
    /// meant to carry it.
    @Published private(set) var appStoreURL: URL?

    private let installedVersion: AppVersion?
    private let manifestURL: URL?
    private let session: URLSession
    private let cache: UpdatePolicyCache
    private let now: () -> Date
    private let defaults: UserDefaults

    /// True for every state where a network call could only make things
    /// worse: demo/reviewer mode (a wall is an automatic App Review
    /// rejection), a `#if DEBUG` forced test state (a real fetch would race
    /// with, and could silently clobber, the state a developer is trying to
    /// look at), or an installed version this process couldn't parse (see
    /// `AppVersion`'s own doc comment on why that must never be coerced into
    /// something that compares as real). All three make `refresh()` a no-op.
    private let neverFetches: Bool

    /// In-memory only, and deliberately not a new persisted key: the
    /// timestamp recorded here is always the exact same `Date` handed to
    /// `cache.save(_:at:)` in the same call, not a second, independently-read
    /// clock value that could drift out of sync with what the cache actually
    /// has on disk. Its only job is throttling repeated `scenePhase`-driven
    /// refreshes within one running process; a fresh launch constructs a
    /// fresh store (this starts `nil` again), so a cold launch always
    /// attempts a check regardless of how recently a previous run succeeded.
    private var lastFetchDate: Date?

    /// How long a successful fetch is trusted before `refresh()` will try
    /// again on its own. A student foregrounding the app repeatedly inside
    /// the same hour shouldn't re-hit the manifest every time.
    private static let throttleInterval: TimeInterval = 60 * 60

    /// Launch arguments that force a fixed verdict for manual testing.
    /// `#if DEBUG` only — see the type's own doc comment on why a Release
    /// build must not even contain the string comparisons, let alone honor
    /// them.
    private static let forceWallArgument = "-LHFForceUpdateWall"
    private static let forceBannerArgument = "-LHFForceUpdateBanner"

    /// A version no real build will ever ship past, used only to synthesize
    /// the two forced DEBUG test states above. It never touches the cache.
    private static let forcedVersion = AppVersion("9999.0.0")!

    /// The link the `-LHFForceUpdateWall` state hands the wall. A forced
    /// verdict is synthesized rather than decoded, so without this the
    /// forced wall would render with no "update now" button at all (the
    /// button is hidden whenever `appStoreURL` is `nil` — see
    /// `UpdateRequiredView`), and the one launch argument that exists to let
    /// someone *look* at the wall couldn't show them its primary control.
    /// A placeholder id is fine: this is DEBUG-only and never reaches a
    /// shipping build, and tapping it lands on the App Store's own
    /// "not available" page rather than anywhere misleading.
    private static let forcedAppStoreURL = URL(string: "https://apps.apple.com/app/id0000000000")

    init(
        installedVersion: AppVersion? = AppVersion(bundle: .main),
        manifestURL: URL? = UpdateManifestSource.url,
        session: URLSession = .shared,
        cache: UpdatePolicyCache = UpdatePolicyCache(),
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .lhf
    ) {
        self.installedVersion = installedVersion
        self.manifestURL = manifestURL
        self.session = session
        self.cache = cache
        self.now = now
        self.defaults = defaults

        // `-LHFDemoData` is the reviewer/screenshot "preview with sample
        // data" seam (see `AppState.isUsingFixtureData` for the same
        // pattern): DEBUG-only, and outside DEBUG this always reads false so
        // the check has zero effect in a shipping build. A reviewer hitting
        // an undismissable update wall on the one path that's supposed to
        // just work is an automatic rejection, so this mode is permanently
        // `.ok` and never touches the network.
        let isDemoMode: Bool = {
            #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("-LHFDemoData")
            #else
            return false
            #endif
        }()

        var forcedVerdict: UpdateVerdict?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains(Self.forceWallArgument) {
            forcedVerdict = .updateRequired(
                minimum: Self.forcedVersion,
                message: "Forced by \(Self.forceWallArgument) for local testing."
            )
        } else if arguments.contains(Self.forceBannerArgument) {
            forcedVerdict = .updateAvailable(latest: Self.forcedVersion)
        }
        #endif

        // An explicit force flag is checked BEFORE demo mode, not after.
        // Both orders are safe for App Review — the force flags are `#if
        // DEBUG` only, so a shipping build cannot contain them at all, which
        // is what makes demo mode's protection unconditional where it counts.
        // But demo mode winning here would mean the two could never be
        // combined, and `-LHFDemoData` is exactly what you need to see the
        // banner sitting over a *populated* dashboard rather than over
        // onboarding: without the sample courses there's no dashboard to
        // overlay. That pairing ("demo data, plus land me on this screen") is
        // the documented convention for every other flag in this app, so the
        // gate follows it too. A developer typing `-LHFForceUpdateBanner` has
        // stated unambiguous intent; demo mode shouldn't silently discard it.
        if let forcedVerdict {
            self.neverFetches = true
            self.verdict = forcedVerdict
            self.appStoreURL = Self.forcedAppStoreURL
        } else if isDemoMode {
            self.neverFetches = true
            self.verdict = .ok
        } else if let installedVersion {
            // Synchronous, no network: a launch with no connectivity still
            // has to honor a block it already knows about from a previous
            // successful fetch.
            self.neverFetches = false
            if let cached = cache.load(now: now()) {
                self.verdict = cached.verdict(forInstalled: installedVersion)
                self.appStoreURL = cached.appStoreURL
            }
        } else {
            // Unparseable bundle version: inert rather than guessing. See
            // `AppVersion`'s doc comment — this is the same "never coerce a
            // failed parse into something that compares as real" rule,
            // applied to the install side of the comparison instead of the
            // manifest side.
            self.neverFetches = true
            self.verdict = .ok
        }
    }

    /// Fetches the manifest, and on success saves it to the cache and
    /// recomputes `verdict`/`appStoreURL` from it. On any thrown error this
    /// leaves both untouched — see the type's doc comment on why that is the
    /// entire point of this method, not an edge case of it.
    func refresh() async {
        guard !neverFetches, let manifestURL, let installedVersion else { return }

        if case .updateRequired = verdict {
            // Someone is stuck behind the wall right now: check eagerly,
            // ignoring the throttle, because a maintainer relaxing the
            // floor is the only way they get out, and making them wait up
            // to an hour to find that out would be a self-inflicted version
            // of the exact lockout this whole feature exists to avoid.
        } else if let lastFetchDate, now().timeIntervalSince(lastFetchDate) < Self.throttleInterval {
            return
        }

        let client = UpdateManifestClient(manifestURL: manifestURL, session: session)
        do {
            let policy = try await client.fetchPolicy()
            let fetchedAt = now()
            cache.save(policy, at: fetchedAt)
            lastFetchDate = fetchedAt
            verdict = policy.verdict(forInstalled: installedVersion)
            appStoreURL = policy.appStoreURL
        } catch {
            // Fail open: no state changes at all. Deliberately not even
            // updating `lastFetchDate` here — the throttle only ever
            // measures the last *successful* fetch, so a network blip
            // doesn't buy itself an hour of silence; the very next
            // `scenePhase` flip to `.active` tries again.
        }
    }

    /// Where per-version banner dismissal is recorded. Keyed by the
    /// version string (not a constant key) so dismissing the notice for
    /// 2.1.0 has no effect on 2.2.0 — see `UpdateAvailableBanner`'s doc
    /// comment for why that, and not the `ContentView` connection-notice
    /// precedent of never persisting a dismissal, is the right call here.
    private static func bannerDismissedKey(for version: AppVersion) -> String {
        "lhf.updateBannerDismissed.\(version.description)"
    }

    func dismissAvailableBanner() {
        guard case .updateAvailable(let latest) = verdict else { return }
        // `isAvailableBannerDismissed` is a computed property, not
        // `@Published`, because it depends on both `verdict` and a defaults
        // read — there is no single stored value for Combine to watch.
        // `objectWillChange.send()` is what tells SwiftUI to re-evaluate it
        // right after this write.
        objectWillChange.send()
        defaults.set(true, forKey: Self.bannerDismissedKey(for: latest))
    }

    var isAvailableBannerDismissed: Bool {
        guard case .updateAvailable(let latest) = verdict else { return false }
        return defaults.bool(forKey: Self.bannerDismissedKey(for: latest))
    }
}
