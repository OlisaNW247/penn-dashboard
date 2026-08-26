import Foundation

/// Parses the Canvas course "Modules" page (`/courses/<id>/modules`) so
/// `CourseProfileEngine` can tell a genuinely silent course apart from one
/// that only ever publishes readings through Modules and never touches the
/// calendar (see docs/READINGS_COURSES_PLAN.md Phase 1.3). Modules markup is
/// undocumented and drifts across Canvas releases, so — same posture as
/// `CanvasCourseDiscoveryParser` next door — this is a defensive,
/// regex-based best-effort scrape: unrecognized markup yields an empty
/// array, never a thrown error. A parser miss must degrade to "found
/// nothing" rather than assert something false about the course.
public enum CanvasModulesParser {
    public struct Item: Sendable, Hashable {
        public let title: String
        public let dueAt: Date?

        public init(title: String, dueAt: Date?) {
            self.title = title
            self.dueAt = dueAt
        }
    }

    /// Splits the page into one chunk per `id="module_item_<n>"` element
    /// (Canvas stamps this id on every row in a module) and pulls a title,
    /// and a due date when present, out of each chunk independently — so a
    /// malformed or unrecognized row can't corrupt its neighbors, it's just
    /// skipped.
    public static func items(from html: String) -> [Item] {
        guard let markerRegex = try? NSRegularExpression(
            pattern: #"id\s*=\s*["']module_item_\d+["']"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)
        let markers = markerRegex.matches(in: html, range: fullRange)
        guard !markers.isEmpty else { return [] }

        var items: [Item] = []
        for (index, marker) in markers.enumerated() {
            let start = marker.range.location
            let end = index + 1 < markers.count ? markers[index + 1].range.location : nsHTML.length
            guard end > start else { continue }
            let chunk = nsHTML.substring(with: NSRange(location: start, length: end - start))
            guard let title = title(in: chunk) else { continue }
            items.append(Item(title: title, dueAt: dueDate(in: chunk)))
        }
        return items
    }

    /// Titles live in an `ig-title`-classed anchor or an `item_name`-classed
    /// wrapper, depending on Canvas theme/version. Tries both, in order, and
    /// keeps the first non-empty result.
    private static func title(in chunk: String) -> String? {
        let patterns = [
            #"class\s*=\s*["'][^"']*ig-title[^"']*["'][^>]*>(.*?)<"#,
            #"class\s*=\s*["'][^"']*item_name[^"']*["'][^>]*>(?:\s*<a\b[^>]*>)?(.*?)<"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let nsChunk = chunk as NSString
            guard let match = regex.firstMatch(in: chunk, range: NSRange(location: 0, length: nsChunk.length)),
                  match.numberOfRanges >= 2
            else { continue }
            let text = cleanText(nsChunk.substring(with: match.range(at: 1)))
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// Only the machine-readable `datetime="…"` attribute (ISO 8601, as
    /// Canvas's `<time>` elements carry it near `due_date_display`) is
    /// trusted. The human-readable `due_date_display` text (e.g. "Aug 25 by
    /// 11:59pm") omits the year and isn't safely parseable — guessing would
    /// risk showing a wrong date, which is worse than showing none.
    private static func dueDate(in chunk: String) -> Date? {
        guard let regex = try? NSRegularExpression(
            pattern: #"datetime\s*=\s*["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let nsChunk = chunk as NSString
        guard let match = regex.firstMatch(in: chunk, range: NSRange(location: 0, length: nsChunk.length)),
              match.numberOfRanges >= 2
        else { return nil }
        let raw = nsChunk.substring(with: match.range(at: 1))

        // Built locally (not cached as static state) since ISO8601DateFormatter
        // isn't Sendable and this type needs to stay Sendable itself.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func cleanText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
