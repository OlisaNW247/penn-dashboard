import Foundation

/// Decoding that loses the element that is wrong and nothing else, and says
/// how many it lost.
///
/// **Why this exists.** Every list and map this app keeps as one JSON blob
/// (the course-knowledge file, the per-course preference map, the recurring
/// tasks, the grade overrides) used to be read with a plain
/// `JSONDecoder().decode([T].self, ...)`. That is all-or-nothing: one element
/// that fails to decode, a field a newer build added with a type this build
/// cannot read, a half-written value from a crash, throws for the whole
/// array. Every call site then did `try? ... ?? []`, and the next save wrote
/// the empty result over the blob, so one bad element cost the student the
/// whole store. The ledger's rule ("nothing the student did is ever lost")
/// has to hold for the stores around it as well.
///
/// **The wrong fix** is to default the missing field or to catch the error at
/// the call site and carry on with `[]`: the first hides the damage and the
/// second is the bug. A lossy decode keeps what is readable and *counts* what
/// is not, so a caller that must not treat the result as complete (the
/// course-materials sync, which retires documents Canvas no longer lists)
/// can see that it was not.
///
/// A failed `decode` on an unkeyed container leaves it on the same element,
/// so the loops below step past a bad element by decoding it as something
/// that cannot fail, and stop if the container still did not move, which
/// would otherwise be an endless loop.
public struct LossyArray<Element: Decodable>: Decodable {
    public let elements: [Element]
    /// Elements that were present but could not be decoded.
    public let droppedCount: Int

    public init(elements: [Element] = [], droppedCount: Int = 0) {
        self.elements = elements
        self.droppedCount = droppedCount
    }

    public init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        let result = LossyDecoding.drain(&list, as: Element.self)
        self.elements = result.elements
        self.droppedCount = result.dropped
        LossyDecodeTally.record(result.dropped, in: decoder)
    }
}

/// A string-keyed map whose bad values are skipped instead of failing the
/// map. See `LossyArray`.
public struct LossyDictionary<Value: Decodable>: Decodable {
    public let entries: [String: Value]
    /// Values that were present but could not be decoded.
    public let droppedCount: Int

    public init(entries: [String: Value] = [:], droppedCount: Int = 0) {
        self.entries = entries
        self.droppedCount = droppedCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LossyDecoding.AnyKey.self)
        var kept: [String: Value] = [:]
        var dropped = 0
        for key in container.allKeys {
            if let value = try? container.decode(Value.self, forKey: key) {
                kept[key.stringValue] = value
            } else {
                dropped += 1
            }
        }
        self.entries = kept
        self.droppedCount = dropped
        LossyDecodeTally.record(dropped, in: decoder)
    }
}

/// A running count of what a lossy decode threw away, handed to the decoder
/// through `userInfo` so a type's own `init(from:)` can report without the
/// type having to grow a field that would leak into its `Hashable`/`Equatable`
/// conformance. `CourseKnowledgeBase` is the user: it is compared and hashed
/// as a value all over the app, and "how many elements did the last decode
/// drop" is a fact about a read, not about the value.
public final class LossyDecodeTally: @unchecked Sendable {
    public static let userInfoKey = CodingUserInfoKey(rawValue: "LossyDecodeTally")!

    private let lock = NSLock()
    private var total = 0

    public init() {}

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    public func add(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        total += count
    }

    /// Reports into the tally the decoder carries, if it carries one.
    static func record(_ count: Int, in decoder: Decoder) {
        (decoder.userInfo[userInfoKey] as? LossyDecodeTally)?.add(count)
    }
}

public enum LossyDecoding {
    /// Reads every element of `list` it can. Drops, and counts, the rest.
    public static func drain<T: Decodable>(
        _ list: inout UnkeyedDecodingContainer,
        as type: T.Type
    ) -> (elements: [T], dropped: Int) {
        var elements: [T] = []
        var dropped = 0
        while !list.isAtEnd {
            let before = list.currentIndex
            if let element = try? list.decode(T.self) {
                elements.append(element)
            } else {
                dropped += 1
                _ = try? list.decode(DiscardedElement.self)
            }
            if list.currentIndex == before {
                // The container will not move past the element, so the rest
                // cannot be read either. Count them as dropped rather than
                // report a clean decode of a list that was cut short.
                if let total = list.count { dropped += max(0, total - before - 1) }
                break
            }
        }
        return (elements, dropped)
    }

    /// The array in `key`, element by element. Absent, `null` or not an array
    /// at all reads as empty with nothing dropped, the same convention as
    /// `decodeIfPresent`.
    static func array<T: Decodable, Key: CodingKey>(
        _ type: T.Type,
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        decoder: Decoder
    ) -> [T] {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) == false,
              var list = try? container.nestedUnkeyedContainer(forKey: key)
        else { return [] }
        let result = drain(&list, as: T.self)
        LossyDecodeTally.record(result.dropped, in: decoder)
        return result.elements
    }

    /// Like `array(_:in:forKey:decoder:)`, but the key must exist and hold an
    /// array: a file with no `documents` at all is not a knowledge file, and
    /// that has to stay a failure rather than read as an empty one.
    static func requiredArray<T: Decodable, Key: CodingKey>(
        _ type: T.Type,
        in container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        decoder: Decoder
    ) throws -> [T] {
        var list = try container.nestedUnkeyedContainer(forKey: key)
        let result = drain(&list, as: T.self)
        LossyDecodeTally.record(result.dropped, in: decoder)
        return result.elements
    }

    /// A coding key for any string, for reading a map whose keys the type
    /// does not know in advance.
    struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Decodes from anything and keeps nothing: how `LossyDecoding.drain` moves
/// past an element it could not read.
private struct DiscardedElement: Decodable {
    init(from decoder: Decoder) throws {}
}
