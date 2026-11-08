import Foundation

/// The agent sign-in page's QR payload: `smooth://link?c=<id>`
/// (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md §3, the phone's half).
///
/// `c` is the browser's pending authorization. The phone looks it up, shows
/// the student what is asking to connect, and approves or denies it.
///
/// Parsing is deliberately strict and returns nil for everything else, for the
/// reason `PairingLink` gives: the scheme is a custom one, so any app or web
/// page can hand this app a `smooth://` URL, and the phone is about to ask
/// "let this agent read your work?" on the strength of it. A half-valid link
/// (a second `c=`, a fragment, a path) is a bug or an attack, never something
/// to be guessed into shape. The code's shape is checked loosely (the same
/// `PairingLink.isPlausibleCode` rule) so the server can lengthen it; the
/// server is the judge of whether it is real (`404 not_found`).
///
/// The id is never shown and never logged. It is the pending authorization
/// itself: whoever holds it can ask the server to approve it. The student
/// identifies the request by the typed code and the number on the page, not
/// by this id.
public struct AgentLinkRequest: Equatable, Sendable {
    public let pendingID: String

    public init?(url: URL) {
        self.init(text: url.absoluteString)
    }

    public init?(text: String) {
        guard let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "smooth",
              parts.host?.lowercased() == "link",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty,
              parts.fragment == nil
        else { return nil }
        guard let items = parts.queryItems, items.count == 1,
              items[0].name == "c", let id = items[0].value,
              PairingLink.isPlausibleCode(id)
        else { return nil }
        self.pendingID = id
    }
}

/// The code the sign-in page shows and the student types when the QR cannot
/// be scanned. Mirrors the server's `normalizeUserCode`: case, spaces and
/// dashes are ignored; the rest must be exactly 8 letters from an alphabet
/// with no vowels or look-alikes.
public enum AgentUserCode {
    static let alphabet: Set<Character> = Set("BCDFGHJKLMNPQRSTVWXZ")

    public static func normalize(_ typed: String) -> String? {
        let cleaned = typed.uppercased().filter { $0 != " " && $0 != "-" }
        guard cleaned.count == 8, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }
}
