import Foundation

/// One device's end-to-end encrypted sync state, format 1
/// (docs/CHROME_EXTENSION.md, "The snapshot (format 1)").
///
/// The same JSON is written by the phone and by the Chrome extension, and a
/// shared vector (chrome-extension/test/fixtures/sync-vector-1.json) pins the
/// bytes on both sides. Two things follow from that and shape this file.
///
/// First, the wire bytes are produced by `canonicalJSON()`, a small hand
/// serializer, not by `JSONEncoder`. `JSONEncoder` gives no promise about key
/// order across OS versions (`.sortedKeys` is alphabetical, which is not the
/// spec's order either), and a single reordered key makes the extension's
/// parse-then-compare tests and any future signature over the bytes disagree
/// for no visible reason. The `encode(to:)` methods exist so the types are
/// honestly `Codable` (a debug dump, a test); they are not the wire format.
///
/// Second, dates are written and read by a hand-rolled UTC formatter
/// (`yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`, exactly what JS `toISOString` gives)
/// instead of a shared `ISO8601DateFormatter`, which is not `Sendable` and
/// would drag a lock into a value type that otherwise needs none.
///
/// Dictionary keys (assignment ids, manual ids) are emitted sorted ascending
/// by Unicode scalar so the output is deterministic; the JS side sorts the
/// same way. Nulls (`dueAt`, `url`) are written explicitly, never omitted.
public struct SyncSnapshot: Codable, Sendable, Equatable {
    public static let currentFormat = 1

    public struct Completion: Codable, Sendable, Equatable {
        public var done: Bool
        public var at: Date
        public init(done: Bool, at: Date) { self.done = done; self.at = at }

        enum CodingKeys: String, CodingKey { case done, at }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            done = try c.decode(Bool.self, forKey: .done)
            at = try c.decodeSyncDate(forKey: .at)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(done, forKey: .done)
            try c.encode(SyncDate.string(at), forKey: .at)
        }
    }

    public struct DueEdit: Codable, Sendable, Equatable {
        /// nil means "edit cleared", and is written as an explicit `null`.
        public var dueAt: Date?
        public var at: Date
        public init(dueAt: Date?, at: Date) { self.dueAt = dueAt; self.at = at }

        enum CodingKeys: String, CodingKey { case dueAt, at }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dueAt = try c.decodeSyncDateIfPresent(forKey: .dueAt)
            at = try c.decodeSyncDate(forKey: .at)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(dueAt.map(SyncDate.string), forKey: .dueAt)
            try c.encode(SyncDate.string(at), forKey: .at)
        }
    }

    public struct ManualTask: Codable, Sendable, Equatable {
        public var title: String
        public var course: String
        public var dueAt: Date?
        public var kind: Assignment.Kind
        public var repeatsWeekly: Bool
        /// A tombstone. Never purged, so a stale device cannot resurrect it.
        public var removed: Bool
        public var at: Date
        public init(title: String, course: String, dueAt: Date?, kind: Assignment.Kind,
                    repeatsWeekly: Bool, removed: Bool, at: Date) {
            self.title = title; self.course = course; self.dueAt = dueAt
            self.kind = kind; self.repeatsWeekly = repeatsWeekly
            self.removed = removed; self.at = at
        }

        enum CodingKeys: String, CodingKey {
            case title, course, dueAt, kind, repeatsWeekly, removed, at
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try c.decode(String.self, forKey: .title)
            course = try c.decode(String.self, forKey: .course)
            dueAt = try c.decodeSyncDateIfPresent(forKey: .dueAt)
            kind = try c.decodeSyncKind(forKey: .kind)
            repeatsWeekly = try c.decode(Bool.self, forKey: .repeatsWeekly)
            removed = try c.decode(Bool.self, forKey: .removed)
            at = try c.decodeSyncDate(forKey: .at)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title)
            try c.encode(course, forKey: .course)
            try c.encode(dueAt.map(SyncDate.string), forKey: .dueAt)
            try c.encode(kind.rawValue, forKey: .kind)
            try c.encode(repeatsWeekly, forKey: .repeatsWeekly)
            try c.encode(removed, forKey: .removed)
            try c.encode(SyncDate.string(at), forKey: .at)
        }
    }

    /// A row of the writer's own merged dashboard. Read-only to other devices.
    public struct WorkItem: Codable, Sendable, Equatable {
        public var id: String
        public var course: String
        public var title: String
        public var dueAt: Date?
        public var kind: Assignment.Kind
        public var source: String
        public var url: String?
        public var done: Bool
        public init(id: String, course: String, title: String, dueAt: Date?,
                    kind: Assignment.Kind, source: String, url: String?, done: Bool) {
            self.id = id; self.course = course; self.title = title
            self.dueAt = dueAt; self.kind = kind; self.source = source
            self.url = url; self.done = done
        }

        enum CodingKeys: String, CodingKey {
            case id, course, title, dueAt, kind, source, url, done
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            course = try c.decode(String.self, forKey: .course)
            title = try c.decode(String.self, forKey: .title)
            dueAt = try c.decodeSyncDateIfPresent(forKey: .dueAt)
            kind = try c.decodeSyncKind(forKey: .kind)
            source = try c.decode(String.self, forKey: .source)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            done = try c.decode(Bool.self, forKey: .done)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(course, forKey: .course)
            try c.encode(title, forKey: .title)
            try c.encode(dueAt.map(SyncDate.string), forKey: .dueAt)
            try c.encode(kind.rawValue, forKey: .kind)
            try c.encode(source, forKey: .source)
            try c.encode(url, forKey: .url)
            try c.encode(done, forKey: .done)
        }
    }

    public var format: Int
    public var deviceId: String
    public var writtenAt: Date
    public var completions: [String: Completion]
    public var dueEdits: [String: DueEdit]
    public var manual: [String: ManualTask]
    public var workList: [WorkItem]

    public init(deviceId: String, writtenAt: Date,
                completions: [String: Completion] = [:],
                dueEdits: [String: DueEdit] = [:],
                manual: [String: ManualTask] = [:],
                workList: [WorkItem] = []) {
        self.format = Self.currentFormat
        self.deviceId = deviceId
        self.writtenAt = writtenAt
        self.completions = completions
        self.dueEdits = dueEdits
        self.manual = manual
        self.workList = workList
    }

    enum CodingKeys: String, CodingKey {
        case format, deviceId, writtenAt, completions, dueEdits, manual, workList
    }

    /// Unknown keys are ignored (the synthesized-style keyed decode only asks
    /// for the keys it knows). A format other than 1 is refused outright: a
    /// future format must not be half-read and then merged into the ledger.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let format = try c.decode(Int.self, forKey: .format)
        guard format == Self.currentFormat else {
            throw DecodingError.dataCorruptedError(
                forKey: .format, in: c,
                debugDescription: "Unsupported sync snapshot format \(format)")
        }
        self.format = format
        deviceId = try c.decode(String.self, forKey: .deviceId)
        writtenAt = try c.decodeSyncDate(forKey: .writtenAt)
        completions = try c.decode([String: Completion].self, forKey: .completions)
        dueEdits = try c.decode([String: DueEdit].self, forKey: .dueEdits)
        manual = try c.decode([String: ManualTask].self, forKey: .manual)
        workList = try c.decode([WorkItem].self, forKey: .workList)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(SyncDate.string(writtenAt), forKey: .writtenAt)
        try c.encode(completions, forKey: .completions)
        try c.encode(dueEdits, forKey: .dueEdits)
        try c.encode(manual, forKey: .manual)
        try c.encode(workList, forKey: .workList)
    }

    public static func decode(_ data: Data) throws -> SyncSnapshot {
        try JSONDecoder().decode(SyncSnapshot.self, from: data)
    }

    // MARK: - Wire form

    /// The exact bytes both clients agree on: spec field order, no
    /// whitespace, slashes unescaped, explicit nulls, sorted dictionary keys.
    public func canonicalJSON() -> Data {
        func obj(_ fields: [(String, String)]) -> String {
            "{" + fields.map { SyncJSON.string($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
        }
        func map<T>(_ d: [String: T], _ f: (T) -> String) -> String {
            let keys = d.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            return "{" + keys.map { SyncJSON.string($0) + ":" + f(d[$0]!) }.joined(separator: ",") + "}"
        }
        func date(_ d: Date?) -> String { d.map { SyncJSON.string(SyncDate.string($0)) } ?? "null" }
        func bool(_ b: Bool) -> String { b ? "true" : "false" }

        let items: [String] = workList.map { w in
            let fields: [(String, String)] = [
                ("id", SyncJSON.string(w.id)), ("course", SyncJSON.string(w.course)),
                ("title", SyncJSON.string(w.title)), ("dueAt", date(w.dueAt)),
                ("kind", SyncJSON.string(w.kind.rawValue)), ("source", SyncJSON.string(w.source)),
                ("url", w.url.map { SyncJSON.string($0) } ?? "null"), ("done", bool(w.done)),
            ]
            return obj(fields)
        }
        let workListJSON = "[" + items.joined(separator: ",") + "]"

        // Each map is built on its own line, with explicit types, so the
        // final literal is plain strings: one literal holding all three
        // closures is the shape that makes the type-checker give up.
        let completionsJSON: String = map(completions) { (c: Completion) -> String in
            obj([("done", bool(c.done)), ("at", date(c.at))])
        }
        let dueEditsJSON: String = map(dueEdits) { (e: DueEdit) -> String in
            obj([("dueAt", date(e.dueAt)), ("at", date(e.at))])
        }
        let manualJSON: String = map(manual) { (m: ManualTask) -> String in
            obj([("title", SyncJSON.string(m.title)), ("course", SyncJSON.string(m.course)),
                 ("dueAt", date(m.dueAt)), ("kind", SyncJSON.string(m.kind.rawValue)),
                 ("repeatsWeekly", bool(m.repeatsWeekly)), ("removed", bool(m.removed)),
                 ("at", date(m.at))])
        }
        let out = obj([
            ("format", String(format)),
            ("deviceId", SyncJSON.string(deviceId)),
            ("writtenAt", date(writtenAt)),
            ("completions", completionsJSON),
            ("dueEdits", dueEditsJSON),
            ("manual", manualJSON),
            ("workList", workListJSON),
        ])
        return Data(out.utf8)
    }
}

// MARK: - JSON strings

/// Escaping that matches JavaScript's `JSON.stringify`, because the extension
/// produces the other half of the shared bytes with it: `"` and `\` escaped,
/// `\b \f \n \r \t` short forms, other control characters below U+0020 as
/// lowercase `\u00xx`, everything else (including `/`, U+007F, U+2028) raw.
enum SyncJSON {
    static func string(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let hex = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Dates

/// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC, always three fractional digits.
/// Civil-date arithmetic (Howard Hinnant's days-from-civil) so no formatter
/// or calendar object is shared. Parsing re-formats the result and compares
/// with the input, which rejects 02-30, 24:00 and any other shape for free.
enum SyncDate {
    static func string(_ date: Date) -> String {
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded())
        var days = ms / 86_400_000
        var rem = ms % 86_400_000
        if rem < 0 { rem += 86_400_000; days -= 1 }
        let (y, m, d) = civil(days)
        func p(_ n: Int, _ w: Int) -> String {
            let s = String(n)
            return String(repeating: "0", count: max(0, w - s.count)) + s
        }
        let h = rem / 3_600_000, mi = rem / 60_000 % 60, s = rem / 1000 % 60, f = rem % 1000
        return "\(p(y, 4))-\(p(m, 2))-\(p(d, 2))T\(p(h, 2)):\(p(mi, 2)):\(p(s, 2)).\(p(f, 3))Z"
    }

    static func parse(_ text: String) -> Date? {
        let b = Array(text.utf8)
        guard b.count == 24 else { return nil }
        func num(_ r: Range<Int>) -> Int? {
            var n = 0
            for i in r {
                guard b[i] >= 48, b[i] <= 57 else { return nil }
                n = n * 10 + Int(b[i] - 48)
            }
            return n
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let s = num(17..<19),
              let f = num(20..<23) else { return nil }
        let ms = (daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + s) * 1000 + f
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return string(date) == text ? date : nil
    }

    private static func civil(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    private static func daysFromCivil(_ year: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

extension KeyedDecodingContainer {
    /// `kind` is an `Assignment.Kind` raw value. A value this build does not
    /// know reads as `.other` rather than failing the whole snapshot, so a
    /// newer writer's extra kind costs one row its label, not every record.
    func decodeSyncKind(forKey key: Key) throws -> Assignment.Kind {
        Assignment.Kind(rawValue: try decode(String.self, forKey: key)) ?? .other
    }

    func decodeSyncDate(forKey key: Key) throws -> Date {
        let text = try decode(String.self, forKey: key)
        guard let date = SyncDate.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "Not a UTC millisecond ISO 8601 date: \(text)")
        }
        return date
    }

    /// Missing and `null` both read as nil; the writer always emits `null`.
    func decodeSyncDateIfPresent(forKey key: Key) throws -> Date? {
        guard let text = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = SyncDate.parse(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self, debugDescription: "Not a UTC millisecond ISO 8601 date: \(text)")
        }
        return date
    }
}
