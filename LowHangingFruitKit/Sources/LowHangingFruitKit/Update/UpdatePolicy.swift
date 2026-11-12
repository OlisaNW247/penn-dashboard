import Foundation

/// A hosted, versioned policy describing whether the running build must stop
/// (a required update) or merely could update. Decoded from a small JSON file
/// LHF fetches at launch — see `UpdateManifestClient`.
///
/// **This is the security boundary, and it is worth being paranoid about.**
/// The verdict this type produces is surfaced as a full-screen wall the
/// student cannot dismiss (a separate UI task builds that screen), and one of
/// its fields — `appStoreURL` — is a link this app will *tell the student to
/// tap*. If the host serving the manifest is ever compromised, or a CDN edge
/// serves a cached/mutated copy, or a misconfigured redirect points the
/// manifest URL somewhere else entirely, the naive approach — "trust it, it's
/// my own file, I control the content" — turns that single JSON response into
/// a phishing surface with the App's own credibility behind it: an
/// undismissable screen telling a Penn student "update now" with a link to an
/// attacker's page that looks like the App Store. So every field is
/// sanitized on the way in, in `init(from:)`, before this type ever holds a
/// value anything downstream can act on:
///
/// - `appStoreURL` survives only if it is `https` or `itms-apps` pointing at
///   exactly `apps.apple.com` or `itunes.apple.com`.
///   Everything else — a different host, plain `http`, `javascript:`,
///   `data:`, or a string that doesn't even parse as a URL — is silently
///   dropped to `nil`. Silently, not by throwing: a forged or broken URL is
///   exactly the one field we can afford to lose, and refusing to decode the
///   rest of an otherwise-good policy over it would be a worse outcome (see
///   the note on partial validity below).
/// - `message` is trimmed, has its control characters and newlines collapsed
///   to single spaces (a wall of text or an embedded terminal escape doesn't
///   belong on a screen the user can't leave), and capped at 300 characters
///   by truncation rather than rejection.
/// - `minimumVersion`/`latestVersion` that fail `AppVersion.init?` become
///   `nil` for that field, not a decode failure — see `AppVersion`'s own
///   documentation for why a bad version must never be coerced into
///   something that compares as real.
///
/// **Why sanitize instead of throw, field by field.** A single malformed
/// field must not take down the whole policy. If a typo in `appStoreURL`
/// caused the entire decode to fail, the fallback (see `UpdateManifestClient`
/// and `UpdatePolicyCache`) is "use the last cached policy, or none at all" —
/// which silently *disables* a `minimumVersion` block the maintainer actually
/// meant to ship, the one field that exists to stop a broken build from
/// reaching Canvas. Losing the least important field (a bad link) must not
/// cost the most important one (the gate itself).
public struct UpdatePolicy: Codable, Sendable, Equatable {
    public var minimumVersion: AppVersion?
    public var latestVersion: AppVersion?
    public var message: String?
    public var appStoreURL: URL?
    /// The optional one-time feedback card (`FeedbackNotice`). Nothing in the
    /// version verdict reads it.
    public var feedback: FeedbackNotice?
    /// The short list of what this release changed, shown under the line on
    /// the update wall and the banner ("sweeper button and page", "connect an
    /// agent"). Already sanitized (`sanitizedChanges`); empty means no list.
    /// Nothing in the version verdict reads it.
    public var changes: [String]

    public init(
        minimumVersion: AppVersion? = nil,
        latestVersion: AppVersion? = nil,
        message: String? = nil,
        appStoreURL: URL? = nil,
        feedback: FeedbackNotice? = nil,
        changes: [String] = []
    ) {
        self.minimumVersion = minimumVersion
        self.latestVersion = latestVersion
        self.message = message
        self.appStoreURL = appStoreURL
        self.feedback = feedback
        self.changes = Self.sanitizedChanges(changes)
    }

    private enum CodingKeys: String, CodingKey {
        case minimumVersion, latestVersion, message, appStoreURL, feedback, changes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        minimumVersion = Self.sanitizedVersion(
            try container.decodeIfPresent(String.self, forKey: .minimumVersion)
        )
        latestVersion = Self.sanitizedVersion(
            try container.decodeIfPresent(String.self, forKey: .latestVersion)
        )
        message = Self.sanitizedMessage(
            try container.decodeIfPresent(String.self, forKey: .message)
        )
        appStoreURL = Self.sanitizedAppStoreURL(
            try container.decodeIfPresent(String.self, forKey: .appStoreURL)
        )
        // `try?`, never `try`: a malformed or forged `feedback` object must
        // not make this whole decode throw, because a thrown decode falls
        // back to the cached policy or none, which silently disables a
        // `minimumVersion` block the maintainer meant to ship. The feedback
        // card is the least important field in the file; it is flattened to
        // nil on any problem.
        feedback = try? container.decodeIfPresent(FeedbackNotice.self, forKey: .feedback)
        // `try?` for the same reason as `feedback`: `changes` as a number, an
        // object or a string must cost the list, never the floor. Inside a
        // well-formed array a non-string item is skipped on its own
        // (`LossyStrings`), so one stray `null` does not lose the other lines.
        changes = Self.sanitizedChanges(
            (try? container.decodeIfPresent(LossyStrings.self, forKey: .changes))?.values ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(minimumVersion, forKey: .minimumVersion)
        try container.encodeIfPresent(latestVersion, forKey: .latestVersion)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(appStoreURL?.absoluteString, forKey: .appStoreURL)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        if !changes.isEmpty {
            try container.encode(changes, forKey: .changes)
        }
    }

    // MARK: Sanitizers

    /// Marco's rule for this list: very, very concise. Six lines at most, 40
    /// characters each, so a whole update reads at a glance and no maintainer
    /// can turn the wall into release notes.
    static let maximumChangeCount = 6
    static let maximumChangeLength = 40

    /// Trims each line, collapses control characters and whitespace runs to
    /// one space, lowercases it (the app's register), and drops the line
    /// outright when it is empty, longer than 40 characters or carries a
    /// link; then keeps the first six. A long line is dropped rather than
    /// cut: a change list that ends mid-word says something the release did
    /// not. A link is dropped rather than shown inert because a URL on an
    /// undismissable screen invites the student to go type it somewhere,
    /// which is the phishing surface this file exists to close. Idempotent,
    /// so the cache's encode-then-decode returns the same list.
    static func sanitizedChanges(_ raw: [String]) -> [String] {
        var kept: [String] = []
        for line in raw {
            guard kept.count < maximumChangeCount else { break }
            let spaced = String(line.map { char -> Character in
                char.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                    ? " "
                    : char
            })
            let collapsed = spaced
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .lowercased()
            guard !collapsed.isEmpty,
                  collapsed.count <= maximumChangeLength,
                  !containsLink(collapsed) else { continue }
            kept.append(collapsed)
        }
        return kept
    }

    private static func containsLink(_ text: String) -> Bool {
        if text.contains("://") || text.contains("www.") { return true }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range) != nil
    }

    /// An array whose string items are kept and whose other items (numbers,
    /// objects, nulls, nested arrays) are skipped one by one.
    private struct LossyStrings: Decodable {
        let values: [String]

        /// Decodes any JSON value and keeps nothing; used to step past an
        /// item that is not a string.
        private struct Skip: Decodable {
            init(from decoder: Decoder) throws {}
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var values: [String] = []
            while !container.isAtEnd {
                if let value = try? container.decode(String.self) {
                    values.append(value)
                } else if (try? container.decode(Skip.self)) == nil {
                    break
                }
            }
            self.values = values
        }
    }

    private static func sanitizedVersion(_ raw: String?) -> AppVersion? {
        guard let raw else { return nil }
        return AppVersion(raw)
    }

    private static let maximumMessageLength = 300

    private static func sanitizedMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Collapse every control character (including newlines, tabs, and
        // stray ANSI/terminal escapes) to a single space, then re-collapse
        // any runs of whitespace that produces down to one space each, so a
        // hostile or merely careless multi-line message doesn't reformat the
        // wall it's shown on.
        let collapsedControls = String(trimmed.map { char -> Character in
            char.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                ? " "
                : char
        })
        let collapsed = collapsedControls
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > maximumMessageLength {
            // Trimmed after the cut: it can land just after a space, and a
            // message that ends in one is not what a second pass (the
            // policy cache re-decodes what it encoded) would produce, so the
            // cached policy would not equal the fetched one.
            let cut = String(collapsed.prefix(maximumMessageLength)).trimmingCharacters(in: .whitespaces)
            return cut.isEmpty ? nil : cut
        }
        return collapsed
    }

    /// The allowlist described at the top of this file. Anything not
    /// matching one of these three shapes returns `nil` — never a thrown
    /// error, because one bad link should not cost an otherwise-valid
    /// `minimumVersion`/`message` pair.
    private static func sanitizedAppStoreURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        // `itms-apps` is held to the same host allowlist as `https` rather
        // than waved through on its scheme alone. It is nominally Apple's
        // scheme and the App Store app is what answers it — but a custom
        // scheme is only ever a *claim*: any installed app may register the
        // same one, and iOS resolves that collision in a way nothing here
        // can depend on. Since the wall this URL is shown on is
        // undismissable, the scheme is the weakest possible evidence that a
        // link goes where it says. Checking the host too costs nothing and
        // removes the question entirely.
        guard scheme == "https" || scheme == "itms-apps" else { return nil }
        guard let host = url.host?.lowercased(),
              host == "apps.apple.com" || host == "itunes.apple.com" else {
            return nil
        }
        return url
    }
}

/// The result of comparing the running build against a fetched/cached
/// `UpdatePolicy`. Pure data — the UI task maps this onto whatever screen it
/// builds.
public enum UpdateVerdict: Sendable, Equatable {
    /// Nothing to do: no minimum block, and either no newer version or the
    /// install already meets it.
    case ok
    /// A newer version exists but the install still works. Advisory only.
    case updateAvailable(latest: AppVersion)
    /// The install is below the enforced floor and must be blocked.
    case updateRequired(minimum: AppVersion, message: String?)
}

public extension UpdatePolicy {
    /// Pure comparison — no clock, no I/O, so it's trivially testable and
    /// safe to call on every launch (and every time the cache refreshes)
    /// without side effects.
    ///
    /// A `nil` `minimumVersion` can never produce `.updateRequired`: the
    /// check below only runs when there's something to compare against, so
    /// an empty policy (every field `nil` — e.g. the manifest fetch failed
    /// and no field sanitized to a value) always resolves to `.ok`, never to
    /// a block nobody configured.
    func verdict(forInstalled installed: AppVersion) -> UpdateVerdict {
        if let minimumVersion, installed < minimumVersion {
            return .updateRequired(minimum: minimumVersion, message: message)
        }
        if let latestVersion, installed < latestVersion {
            return .updateAvailable(latest: latestVersion)
        }
        return .ok
    }
}
