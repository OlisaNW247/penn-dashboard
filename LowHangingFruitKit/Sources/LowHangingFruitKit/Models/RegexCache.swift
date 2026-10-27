import Foundation

/// Compiled regular expressions, kept, for the checks that run once per item.
///
/// `text.range(of: pattern, options: .regularExpression)` compiles `pattern`
/// from scratch on every call. That is invisible for a check that runs once,
/// and the dashboard rebuild is not that: it classifies every item the
/// student has ever had (quiz or exam? attendance? a program-year site? the
/// same title as another row?) every time anything changes, so a pattern
/// that costs a few tens of microseconds to compile is paid thousands of
/// times per rebuild. Compile once, look it up after.
///
/// **The wrong fix** is to hoist each pattern into its own `static let` and
/// leave the call sites alone, which is right for a constant pattern and
/// leaves out the ones assembled at the call site
/// (`"\\b" + noun + "\\b"`). Keyed by the final pattern string and its
/// options, this serves both, and a call site that changes later cannot
/// quietly go back to compiling.
///
/// The cache is bounded: patterns built from user text would otherwise grow
/// it without limit, so past `capacity` entries it starts over rather than
/// tracking recency, which a few hundred distinct patterns never reach.
/// `NSRegularExpression` is immutable and documented thread-safe, so the
/// shared instances can be used from any isolation; only the table needs the
/// lock.
public enum RegexCache {
    static let capacity = 512

    private final class Storage: @unchecked Sendable {
        struct Key: Hashable {
            let pattern: String
            let options: UInt
        }

        private let lock = NSLock()
        private var table: [Key: NSRegularExpression] = [:]
        private var failed: Set<Key> = []

        func regex(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
            let key = Key(pattern: pattern, options: options.rawValue)
            lock.lock()
            if let hit = table[key] {
                lock.unlock()
                return hit
            }
            if failed.contains(key) {
                lock.unlock()
                return nil
            }
            lock.unlock()

            // Compiled outside the lock: two threads racing on a new pattern
            // each compile it once and the second write wins, which costs one
            // redundant compile, not a stall behind the first.
            let compiled = try? NSRegularExpression(pattern: pattern, options: options)

            lock.lock()
            defer { lock.unlock() }
            if table.count + failed.count >= RegexCache.capacity {
                table.removeAll(keepingCapacity: true)
                failed.removeAll(keepingCapacity: true)
            }
            if let compiled {
                table[key] = compiled
            } else {
                failed.insert(key)
            }
            return compiled
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return table.count + failed.count
        }
    }

    private static let storage = Storage()

    /// How many patterns are held. For tests of the bound.
    static var entryCount: Int { storage.count }

    /// The compiled pattern, or nil when it does not compile (the same nil a
    /// `try? NSRegularExpression(pattern:)` gives, and remembered, so a bad
    /// pattern is not recompiled on every call either).
    public static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        storage.regex(pattern, options: options)
    }

    /// `text.range(of: pattern, options: .regularExpression) != nil`, with the
    /// pattern compiled once. Searches the whole string, as that call does. A
    /// pattern that does not compile matches nothing, as there.
    public static func contains(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> Bool {
        guard let regex = regex(pattern, options: options) else { return false }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    /// `text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)`,
    /// with the pattern compiled once. A pattern that does not compile
    /// returns the text unchanged, as there.
    public static func replacing(
        _ pattern: String,
        in text: String,
        with template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = regex(pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: text.utf16.count), withTemplate: template
        )
    }
}
