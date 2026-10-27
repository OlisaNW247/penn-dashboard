import Foundation

/// The `X-Smooth-Version` header every request to the Supabase backend
/// carries, so the server can tell which build is calling and refuse one below
/// the enforced floor.
///
/// The value is the marketing version (`CFBundleShortVersionString`, e.g.
/// `3.2.1`) and nothing else: no build number, no device or user identifier.
/// It is the same string the App Store shows. Only the three request builders
/// that talk to the backend (`BackendClient.askStream`, `BackendClient.send`,
/// `BackendSession.authRequest`) call `apply`; Canvas, Gradescope, Ed, the
/// update manifest and anything else must not, because those are other
/// parties' servers.
///
/// A missing or blank version omits the header rather than sending an empty
/// or invented one. That matches the gate's fail-open rule: an unreadable
/// version must never turn into a block, and the server treats an absent
/// header as "unknown", not "old".
enum BackendVersionHeader {
    static let name = "X-Smooth-Version"

    /// The running bundle's marketing version, or nil if it is missing/blank.
    static func value(bundle: Bundle = .main) -> String? {
        normalized(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
    }

    /// The pure half of `value(bundle:)`, split out so tests reach it without
    /// building a bundle: anything that is not a non-blank string is nil.
    static func normalized(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func apply(to request: inout URLRequest, bundle: Bundle = .main) {
        guard let value = value(bundle: bundle) else { return }
        request.setValue(value, forHTTPHeaderField: name)
    }
}
