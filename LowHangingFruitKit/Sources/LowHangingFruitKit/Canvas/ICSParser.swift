import Foundation

/// Minimal RFC 5545 parser, scoped to the subset Canvas's calendar feed emits:
/// VEVENT blocks with SUMMARY, DTSTART, URL, UID. Line folding is handled.
/// Anything fancier (RRULE, VALARM, attachments) is intentionally ignored.
public enum ICSParser {
    public struct Event: Sendable, Hashable {
        public let uid: String
        public let summary: String
        public let dtStart: Date?
        public let url: URL?
    }

    public static func parse(_ data: Data) -> [Event] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public static func parse(_ text: String) -> [Event] {
        let lines = unfold(text)
        var events: [Event] = []
        var inEvent = false
        var fields: [String: (params: [String: String], value: String)] = [:]

        for line in lines {
            if line == "BEGIN:VEVENT" {
                inEvent = true
                fields.removeAll(keepingCapacity: true)
            } else if line == "END:VEVENT" {
                if inEvent { events.append(makeEvent(from: fields)) }
                inEvent = false
            } else if inEvent, let parsed = parseFieldLine(line) {
                fields[parsed.name] = (parsed.params, parsed.value)
            }
        }
        return events
    }

    // MARK: - Line handling

    /// Joins folded continuation lines (those that begin with space or tab) onto
    /// their predecessor, per RFC 5545 §3.1.
    private static func unfold(_ text: String) -> [String] {
        var result: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if let first = line.first, (first == " " || first == "\t"), !result.isEmpty {
                result[result.count - 1].append(contentsOf: line.dropFirst())
            } else {
                result.append(line)
            }
        }
        return result
    }

    private struct ParsedField {
        let name: String
        let params: [String: String]
        let value: String
    }

    private static func parseFieldLine(_ line: String) -> ParsedField? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])

        let parts = head.split(separator: ";", omittingEmptySubsequences: false)
        guard let nameSub = parts.first else { return nil }
        let name = nameSub.uppercased()

        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            if let eq = p.firstIndex(of: "=") {
                let k = String(p[..<eq]).uppercased()
                let v = String(p[p.index(after: eq)...])
                params[k] = v
            }
        }
        return ParsedField(name: name, params: params, value: unescape(value))
    }

    /// RFC 5545 §3.3.11 TEXT escapes: `\n`, `\,`, `\;`, `\\`.
    private static func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\", let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex), next < s.endIndex {
                switch s[next] {
                case "n", "N": out.append("\n")
                case ",":      out.append(",")
                case ";":      out.append(";")
                case "\\":     out.append("\\")
                default:       out.append(s[next])
                }
                i = s.index(after: next)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    // MARK: - Field → Event

    private static func makeEvent(
        from fields: [String: (params: [String: String], value: String)]
    ) -> Event {
        let uid = fields["UID"]?.value ?? UUID().uuidString
        let summary = fields["SUMMARY"]?.value ?? "(untitled)"
        let url = (fields["URL"]?.value).flatMap(URL.init(string:))

        let date: Date?
        if let dt = fields["DTSTART"] {
            date = parseDate(value: dt.value, params: dt.params)
        } else {
            date = nil
        }
        return Event(uid: uid, summary: summary, dtStart: date, url: url)
    }

    private static func parseDate(value: String, params: [String: String]) -> Date? {
        // Date-only: YYYYMMDD, normalized to end-of-day UTC so it sorts after dated events.
        if params["VALUE"] == "DATE" || (value.count == 8 && !value.contains("T")) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            guard let day = f.date(from: value) else { return nil }
            return Calendar(identifier: .gregorian).date(byAdding: .second, value: 86_399, to: day)
        }

        // Datetime: YYYYMMDDTHHmmss with optional trailing Z or TZID param.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        if value.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: String(value.dropLast()))
        }
        if let tzid = params["TZID"], let tz = TimeZone(identifier: tzid) {
            f.timeZone = tz
            return f.date(from: value)
        }
        // Floating local time fallback.
        f.timeZone = TimeZone.current
        return f.date(from: value)
    }
}
