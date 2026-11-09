import Foundation

/// The ambassador's "login": the unguessable code at the end of their
/// private page link (`https://…/a/{code}`), handed to them by a founder in a
/// text. There is no account and no password anywhere in this feature, on
/// purpose: the ambassadors are a handful of the founders' friends, and the
/// code is already the thing that protects their page on the web. The app
/// accepts the code in every shape a friend is likely to paste: the bare
/// code, the whole page link (with or without a trailing `/stickers`), or
/// the `smooth://ambassador?code=…` link the page itself offers.
///
/// Pure parsing, in the Kit so a test can pin it without UI or a Keychain.
/// Validation is deliberately looser than the server's own alphabet (which
/// leaves out `0`, `o`, `1`, `l` and `i` so a code can be read off a phone):
/// a founder could change that alphabet without an app release, and the
/// server is the one that decides whether a code is real. What is refused
/// here is only what can never be a code: anything outside lowercase letters,
/// digits and hyphens, or outside 10 to 40 characters.
public enum AmbassadorCode {
    public static let minimumLength = 10
    public static let maximumLength = 40

    /// The code in `raw`, normalised to lowercase, or nil when nothing in it
    /// could be one.
    public static func parse(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "smooth":
                // smooth://ambassador?code=abc… (the page's "open in smooth").
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let code = items.first(where: { $0.name == "code" })?.value {
                    return validated(code)
                }
                return nil
            case "http", "https":
                // https://host/a/{code}[/anything]
                let parts = url.pathComponents.filter { $0 != "/" }
                if let i = parts.firstIndex(of: "a"), parts.indices.contains(i + 1) {
                    return validated(parts[i + 1])
                }
                return nil
            default:
                break
            }
        }
        return validated(trimmed)
    }

    /// Whether `code` has the shape of a code (see the type's note on why the
    /// shape is loose).
    public static func isPlausible(_ code: String) -> Bool {
        validated(code) != nil
    }

    private static func validated(_ candidate: String) -> String? {
        let code = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (minimumLength...maximumLength).contains(code.count) else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard code.allSatisfy({ allowed.contains($0) }) else { return nil }
        return code
    }
}
