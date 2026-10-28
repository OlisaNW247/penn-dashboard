import Foundation
import Testing

/// Shared pieces for `FuzzTests`: random generators over `SeededGenerator`,
/// byte- and string-level mutators, and the harness that holds every case to a
/// time budget.
///
/// **What a fuzz case proves.** That a parser given hostile or merely odd
/// outside data (a school's calendar feed, Ed's JSON, a pasted announcement, a
/// manifest from a static file anyone can edit) neither traps nor stalls. A
/// trap kills the whole test process, so the harness cannot catch one; what it
/// can do is make it reproducible. Every run uses a fixed seed, so a crash is
/// the same crash on every machine, and with `LHF_FUZZ_TRACE=1` in the
/// environment each iteration number is written to stderr before it runs, so
/// the last line printed before the crash names the iteration to replay.
enum Fuzz {
    static var tracing: Bool { ProcessInfo.processInfo.environment["LHF_FUZZ_TRACE"] != nil }

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }

    /// Runs `body` `iterations` times against one seeded generator. Each
    /// iteration must finish within `perCase` seconds and the run within
    /// `total`; both budgets are far above what a healthy parser needs, so a
    /// failure means a stall or something quadratic, not a slow machine.
    static func run(
        _ name: String,
        seed: UInt64,
        iterations: Int,
        perCase: TimeInterval = 3,
        total: TimeInterval = 60,
        _ body: (inout SeededGenerator, Int) throws -> Void
    ) rethrows {
        var rng = SeededGenerator(seed: seed)
        let start = Date()
        for index in 0..<iterations {
            trace("fuzz \(name) seed=\(seed) iteration=\(index)")
            let caseStart = Date()
            try body(&rng, index)
            let took = Date().timeIntervalSince(caseStart)
            #expect(took < perCase, "\(name) seed \(seed) iteration \(index) took \(took)s")
        }
        let overall = Date().timeIntervalSince(start)
        #expect(overall < total, "\(name) seed \(seed): \(iterations) iterations took \(overall)s")
    }
}

extension SeededGenerator {
    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }

    mutating func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &self) < probability }

    mutating func pick<T>(_ options: [T]) -> T { options[Int.random(in: 0..<options.count, using: &self)] }

    mutating func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &self) })
    }

    /// Random scalars from the ranges that have caused trouble: ASCII, the
    /// control block (NUL included), Latin and combining marks, CJK, emoji,
    /// the BOM and the specials block. Never a surrogate, which is not a scalar.
    mutating func unicode(_ length: Int) -> String {
        var scalars = String.UnicodeScalarView()
        let ranges: [ClosedRange<UInt32>] = [
            0x20...0x7E, 0x00...0x1F, 0x7F...0x9F, 0xA0...0x24F, 0x300...0x36F,
            0x4E00...0x4FFF, 0x1F300...0x1F5FF, 0xFEFF...0xFEFF, 0xFFF0...0xFFFD, 0x200B...0x200F,
        ]
        for _ in 0..<length {
            let range = pick(ranges)
            if let scalar = Unicode.Scalar(UInt32.random(in: range, using: &self)) { scalars.append(scalar) }
        }
        return String(scalars)
    }

    /// `length` characters drawn from `alphabet`.
    mutating func string(_ length: Int, from alphabet: String) -> String {
        let characters = Array(alphabet)
        return String((0..<length).map { _ in characters[Int.random(in: 0..<characters.count, using: &self)] })
    }

    /// `data` with a few random edits: flip, insert, delete, duplicate a
    /// span, or truncate. The edits that make a valid document almost valid.
    mutating func mutate(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        for _ in 0..<int(1...6) {
            switch int(0...4) {
            case 0 where !bytes.isEmpty:
                bytes[int(0...(bytes.count - 1))] = UInt8.random(in: 0...255, using: &self)
            case 1:
                bytes.insert(UInt8.random(in: 0...255, using: &self), at: int(0...bytes.count))
            case 2 where !bytes.isEmpty:
                bytes.remove(at: int(0...(bytes.count - 1)))
            case 3 where bytes.count > 2:
                let start = int(0...(bytes.count - 2))
                let end = min(bytes.count, start + int(1...64))
                bytes.insert(contentsOf: bytes[start..<end], at: int(0...bytes.count))
            case 4 where bytes.count > 1:
                bytes.removeLast(int(1...(bytes.count - 1)))
            default:
                break
            }
        }
        return Data(bytes)
    }

    mutating func mutate(_ text: String) -> String {
        String(decoding: mutate(Data(text.utf8)), as: UTF8.self)
    }

    // MARK: JSON

    /// A random JSON value, `depth` levels deep at most: every scalar type,
    /// numbers at the edges (huge, tiny, negative, fractional), strings that
    /// are hostile, empty and nested containers.
    mutating func jsonValue(depth: Int = 3) -> Any {
        switch int(0...(depth > 0 ? 8 : 5)) {
        case 0: return NSNull()
        case 1: return chance(0.5)
        case 2: return pick([0, 1, -1, 42, Int.max, Int.min, 9_007_199_254_740_993, 1 << 40])
        case 3: return pick([0.0, 0.5, -0.5, 1e-300, 1e300, 123_456.789, Double.greatestFiniteMagnitude])
        case 4: return unicode(int(0...24))
        case 5: return pick(["", "null", "true", "NaN", "Infinity", "2026-03-05T14:21:55Z", "1.2.3", "99999999999999999999.1"])
        case 6, 7: return (0..<int(0...4)).map { _ in jsonValue(depth: depth - 1) }
        default:
            var object: [String: Any] = [:]
            for _ in 0..<int(0...5) { object[pick(["id", "name", "type", "title", "items", "threads", "users", "x", unicode(3)])] = jsonValue(depth: depth - 1) }
            return object
        }
    }

    mutating func jsonData(depth: Int = 3) -> Data {
        let value = jsonValue(depth: depth)
        let wrapped: Any = JSONSerialization.isValidJSONObject(value) ? value : [value]
        return (try? JSONSerialization.data(withJSONObject: wrapped, options: [.fragmentsAllowed])) ?? Data()
    }
}
