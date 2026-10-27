import Foundation

/// A one-time "tell us how it's going" card the update manifest can switch on
/// without a release: an id, a title, an optional subtitle and the link the
/// card opens.
///
/// It rides in the same file as `UpdatePolicy`, which is the security
/// boundary for a link this app tells the student to tap, so every field is
/// sanitized here before anything downstream holds it:
///
/// - `id` is non-empty, at most 64 characters, `[A-Za-z0-9._-]` only. It
///   becomes part of a `UserDefaults` key (the "already handled" mark), so it
///   must not be able to carry anything surprising.
/// - `title` and `subtitle` have control characters collapsed to single
///   spaces and are capped at 80 characters by truncation.
/// - `url` must be `https` on exactly `docs.google.com` or `forms.gle`. A
///   forged manifest cannot point the card at an arbitrary page.
///
/// Unlike `UpdatePolicy`'s own fields, a bad required field here fails the
/// whole notice (it throws) rather than being patched up: half a card is
/// worse than no card. `UpdatePolicy` turns that throw into "no notice" so it
/// never costs the policy its `minimumVersion`.
public struct FeedbackNotice: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let url: URL

    public init(id: String, title: String, subtitle: String? = nil, url: URL) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawID = try container.decode(String.self, forKey: .id)
        guard Self.isValidID(rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "invalid feedback notice id"
            )
        }

        let rawTitle = try container.decode(String.self, forKey: .title)
        guard let cleanTitle = Self.sanitizedText(rawTitle) else {
            throw DecodingError.dataCorruptedError(
                forKey: .title, in: container, debugDescription: "empty feedback notice title"
            )
        }

        let rawURL = try container.decode(String.self, forKey: .url)
        guard let cleanURL = Self.allowedURL(rawURL) else {
            throw DecodingError.dataCorruptedError(
                forKey: .url, in: container, debugDescription: "feedback notice url not allowed"
            )
        }

        id = rawID
        title = cleanTitle
        // A bad subtitle is cosmetic: it is dropped, and the notice stays.
        subtitle = Self.sanitizedText(try? container.decodeIfPresent(String.self, forKey: .subtitle))
        url = cleanURL
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encode(url.absoluteString, forKey: .url)
    }

    // MARK: Sanitizers

    private static let maximumIDLength = 64
    private static let maximumTextLength = 80
    private static let allowedHosts: Set<String> = ["docs.google.com", "forms.gle"]

    private static func isValidID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= maximumIDLength else { return false }
        return raw.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)      // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)  // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)  // a-z
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    /// Same collapsing as `UpdatePolicy`'s message: control characters become
    /// spaces, whitespace runs become one space, then truncate.
    private static func sanitizedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let spaced = String(raw.map { char -> Character in
            char.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                ? " "
                : char
        })
        let collapsed = spaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maximumTextLength))
    }

    private static func allowedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host) else {
            return nil
        }
        return url
    }
}
