import Foundation
import LowHangingFruitKit

/// Where to find LHF's own backend, and how to authenticate to it as an
/// anonymous caller. See `backend/PROTOCOL.md` for the wire contract this
/// points at.
///
/// The two values here are deliberately public, not secret: a Supabase
/// "anon" key is the same kind of thing a web app ships baked into its own
/// bundled JavaScript — it identifies the *project*, not a user, and every
/// permission it grants is enforced server-side by row-level-security
/// policies, not by keeping the key hidden. That is a different trust model
/// from `AnthropicKeyStore`'s API key, which is a bearer credential that
/// spends the key owner's own money with no further proof of identity; this
/// is why the anon key lives in source (like a web app's) while a real
/// per-student credential — the refresh token `BackendIdentityStore` holds —
/// still goes in the Keychain and nowhere else.
struct BackendConfiguration: Sendable {
    let url: URL
    let anonKey: String

    /// Paste the project's URL and anon (publishable) key here after running
    /// `supabase link` against the deployed project — see
    /// `backend/PROTOCOL.md`. Until then `isConfigured` is false and
    /// `current` returns `nil`, which is what keeps every build before that
    /// step, and every test run regardless of it, fully on-device: nothing
    /// in this Kit calls a hostname that still reads "REPLACE-ME".
    static let production = BackendConfiguration(
        url: URL(string: "https://REPLACE-ME.supabase.co")!,
        anonKey: "REPLACE-ME"
    )

    var isConfigured: Bool {
        !url.absoluteString.contains("REPLACE-ME") && !anonKey.contains("REPLACE-ME")
    }

    /// The configuration this process should use, or `nil` when it should
    /// behave as if there were no backend at all.
    ///
    /// `nil` here is not an edge case to special-case away — it is the
    /// *normal* state for every unit test (`SharedDefaults.isTestRunner`,
    /// the same guard `SessionCookieStore.merge` and the App Group
    /// resolution in `SharedDefaults` use to keep a `swift test` run from
    /// touching anything real) and for any build of this source before the
    /// owner has pasted in a real `production` value. Both cases must fall
    /// back to on-device answering rather than attempting a network call
    /// against a placeholder host.
    static var current: BackendConfiguration? {
        guard !SharedDefaults.isTestRunner else { return nil }
        #if DEBUG
        // `-LHFBackendURL <url> -LHFBackendAnonKey <key>` launch-argument
        // overrides, in the same spirit as `-LHFDemoData` and friends
        // (CLAUDE.md's `Commands` section) but read through
        // `UserDefaults.standard` rather than `ProcessInfo.arguments`
        // directly: Foundation registers "-Key Value" launch arguments into
        // `UserDefaults.standard`'s volatile argument domain automatically,
        // which is what lets `xcrun simctl launch ... -LHFBackendURL
        // https://localhost:54321` (a local `supabase start` stack) reach
        // this code without a rebuild. DEBUG-only so a Release build can
        // never be redirected by a stray launch argument.
        if let override = debugOverride, override.isConfigured {
            return override
        }
        #endif
        return production.isConfigured ? production : nil
    }

    #if DEBUG
    private static var debugOverride: BackendConfiguration? {
        let defaults = UserDefaults.standard
        guard let urlString = defaults.string(forKey: "LHFBackendURL"),
              let anonKey = defaults.string(forKey: "LHFBackendAnonKey"),
              let url = URL(string: urlString)
        else { return nil }
        return BackendConfiguration(url: url, anonKey: anonKey)
    }
    #endif
}
