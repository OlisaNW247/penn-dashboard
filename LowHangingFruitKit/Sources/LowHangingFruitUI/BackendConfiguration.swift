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
        url: URL(string: "https://ynetfjixexksxqrrkwsg.supabase.co")!,
        anonKey: "sb_publishable_jOEUk139Kvir7R3CfxI0SA_bQv87jqt"
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
        // overrides, read from `ProcessInfo.arguments` the way `-LHFDemoData`
        // and friends are (CLAUDE.md's `Commands` section). Foundation would
        // also surface these through the standard defaults' argument domain,
        // and that was the first version of this code — but
        // `SharedDefaultsMigrationTests` scans this module for any read of
        // the app-private defaults domain (even in a comment), because a
        // preference read that lands there is invisible to the widget, and
        // it has no way to tell a launch-arg lookup from a real preference.
        // Walking the argument list is the same one line of work and keeps
        // that guard honest. DEBUG-only so a Release build can never be
        // redirected by a stray launch argument.
        if let override = debugOverride, override.isConfigured {
            return override
        }
        #endif
        return production.isConfigured ? production : nil
    }

    #if DEBUG
    private static var debugOverride: BackendConfiguration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let urlString = value(following: "-LHFBackendURL", in: arguments),
              let anonKey = value(following: "-LHFBackendAnonKey", in: arguments),
              let url = URL(string: urlString)
        else { return nil }
        return BackendConfiguration(url: url, anonKey: anonKey)
    }

    /// The token after `flag` in the argument list, if there is one.
    private static func value(following flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.endIndex else { return nil }
        let candidate = arguments[index + 1]
        return candidate.hasPrefix("-") ? nil : candidate
    }
    #endif
}
