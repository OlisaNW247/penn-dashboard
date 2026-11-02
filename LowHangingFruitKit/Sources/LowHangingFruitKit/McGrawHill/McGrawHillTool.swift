import Foundation

/// Recognises a Canvas assignment that launches McGraw Hill Connect or ALEKS,
/// from the host of its `external_tool_tag_attributes.url` (decoded by
/// `CanvasGradesClient` into `GradeItem.externalToolHost`).
///
/// **Why the host and nothing else.** An instructor who deploys Connect work
/// into Canvas creates an ordinary Canvas assignment whose submission type is
/// `external_tool`, and Canvas launches the tool at that URL. The title is
/// the instructor's ("Chapter 4 Homework") and says nothing; the submission
/// type says only "some LTI tool", which Ed, Gradescope, Pearson and a dozen
/// others share. The launch host is the one field that names the vendor.
///
/// **The host list is a guess until recon.** Nobody on this project has yet
/// seen a real Penn Connect assignment's launch URL (`docs/mcgraw-hill/`, brief
/// 1). The list below is every McGraw Hill host the research found named in
/// public material (`research_notes/McGraw Hill access for Smooth/`): the
/// `mheducation.com` family (Connect, LTI Advantage, `caas`, the SSO router),
/// `aleks.com`, and the older `mcgraw-hill.com` and `mhcampus.com`. Matching
/// is on whole DNS labels (`host == root || host.hasSuffix("." + root)`), so
/// `notmheducation.com` and `mheducation.com.evil.example` are not McGraw
/// Hill. When recon names the real host, add it here with its date; do not
/// widen the rule to a substring match, which is how an attacker-named host
/// would get in.
///
/// What a recognised assignment changes today (2026-11-02): only that the
/// Smooth Sweeper leaves it alone (`AppState.completionNotVisible`), because
/// Canvas may never record `submitted_at` for finished Connect work and the
/// alarm would then ring for work already done. It does not change the card,
/// its due date or its done state, and nothing about it leaves the phone.
public enum McGrawHillTool {
    /// Which McGraw Hill product an assignment launches. Decides only the
    /// card's label ("in connect" / "in aleks").
    public enum Product: String, Sendable, Equatable, Codable {
        case connect
        case aleks

        /// The card label, in the app's lowercase register (Marco's copy
        /// rule: the least text that works).
        public var label: String {
            switch self {
            case .connect: return "in connect"
            case .aleks: return "in aleks"
            }
        }
    }

    /// Registrable roots. See the type's note on why whole labels only.
    static let aleksRoots = ["aleks.com"]
    static let connectRoots = ["mheducation.com", "mcgraw-hill.com", "mhcampus.com"]

    /// The product an external-tool host belongs to, or nil for any host that
    /// is not McGraw Hill (Ed, Gradescope, Pearson, an empty string).
    public static func product(forHost host: String?) -> Product? {
        guard let host = normalized(host) else { return nil }
        if aleksRoots.contains(where: { matches(host, root: $0) }) { return .aleks }
        // ALEKS can also be served from a McGraw Hill subdomain; the label
        // follows the product name when the host carries it.
        if connectRoots.contains(where: { matches(host, root: $0) }) {
            return host.split(separator: ".").contains("aleks") ? .aleks : .connect
        }
        return nil
    }

    public static func isMcGrawHill(host: String?) -> Bool {
        product(forHost: host) != nil
    }

    /// The host alone, lowercased, from a launch URL string. Only the host is
    /// kept anywhere: a launch URL can carry resource-link ids and query
    /// tokens, and the host is all the recognition needs.
    public static func host(fromLaunchURL raw: String?) -> String? {
        guard let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return normalized(url.host)
    }

    private static func normalized(_ host: String?) -> String? {
        guard var host = host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else { return nil }
        // A fully-qualified host may end in a dot.
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    private static func matches(_ host: String, root: String) -> Bool {
        host == root || host.hasSuffix("." + root)
    }
}
