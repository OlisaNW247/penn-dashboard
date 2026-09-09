import Foundation

/// A dotted numeric app version ("2", "2.0", "2.0.0", "2.0.0.1"), comparable
/// component-wise with missing trailing components treated as zero.
///
/// **Why a failed parse returns `nil` instead of falling back to `0.0.0`.**
/// This is the same lesson `CourseCode.parse` already paid for: a parser that
/// turns "can't read this" into a plausible-looking default doesn't fail
/// loudly, it fails *silently and wrong*. `CourseCode`'s wrong answer becomes
/// a course's permanent identity; this type's wrong answer would be worse,
/// because it drives a full-screen, undismissable update wall. A hosted
/// manifest that ships a typo'd version string ("2..0") or gets served through
/// a CDN that mangles it must not be interpreted as "0.0.0", which would
/// compare as less than literally every installed build and force-block the
/// entire user base on a typo. `nil` here is a deliberate signal that
/// propagates outward: `UpdatePolicy` decodes the field to `nil` rather than
/// throwing, and a `nil` `minimumVersion` can never produce
/// `.updateRequired` (see `UpdatePolicy.verdict`). A version that fails to
/// parse must make the gate inert, never make it block.
public struct AppVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    /// Normalized components, e.g. [2, 0, 0]. Always non-empty.
    let components: [Int]

    /// Parses a dotted numeric version string. Returns `nil` unless every
    /// dot-separated component is present and is a non-negative integer —
    /// so "", "abc", "2.x", "-1.0" and "2..0" (an empty component between two
    /// dots) all fail rather than silently coercing to something plausible.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            // `Int.init` rejects "", "-1", whitespace and non-digit strings,
            // but it also accepts a leading "+" and a leading zero we're happy
            // to allow ("01") — those are still unambiguous integers. What we
            // must not allow is anything with a sign, which `Int.init` alone
            // permits for "-1": guard on the digits themselves.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else {
                return nil
            }
            parsed.append(value)
        }

        self.components = parsed
    }

    /// Convenience reading the running bundle's marketing version
    /// (`CFBundleShortVersionString`). `nil` when the key is missing or
    /// unparseable, for the same reason the string initializer returns `nil`
    /// rather than guessing.
    public init?(bundle: Bundle) {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        self.init(raw)
    }

    private init(components: [Int]) {
        self.components = components
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r { return false }
        }
        return true
    }

    public func hash(into hasher: inout Hasher) {
        // Hash must agree with `==`, which treats "2.0" and "2.0.0" as equal.
        // Hashing the *trimmed* (trailing-zero-stripped) components keeps that
        // agreement instead of hashing the raw, differently-shaped arrays.
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        hasher.combine(trimmed)
    }
}

extension AppVersion: Codable {
    /// Encodes/decodes as the normalized dotted string, not the component
    /// array, so a cached blob (`UpdatePolicyCache`) stays human-readable and
    /// forward-compatible rather than an opaque `[Int]`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = AppVersion(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(raw)\" is not a valid dotted numeric version"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
