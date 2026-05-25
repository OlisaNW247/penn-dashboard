import Foundation

public struct CanvasRequirementSuggestion: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Hashable {
        case syllabus = "Canvas Syllabus"
        case announcement = "Canvas Announcement"
    }

    public var id: String { "\(course)|\(title)|\(weekday)|\(hour)|\(minute)|\(source.rawValue)" }

    public let course: String
    public let title: String
    public let weekday: Int
    public let hour: Int
    public let minute: Int
    public let source: Source
    public let evidence: String

    public init(
        course: String,
        title: String,
        weekday: Int,
        hour: Int,
        minute: Int,
        source: Source,
        evidence: String
    ) {
        self.course = course
        self.title = title
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.source = source
        self.evidence = evidence
    }
}

public enum CanvasRequirementScanner {
    public static func suggestions(
        from html: String,
        course: String,
        source: CanvasRequirementSuggestion.Source
    ) -> [CanvasRequirementSuggestion] {
        let text = cleanText(html)
        let sentences = text
            .split(whereSeparator: { ".!?\n".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var suggestions: [CanvasRequirementSuggestion] = []
        for sentence in sentences where looksLikeRecurringRequirement(sentence) {
            let weekday = weekday(in: sentence) ?? 1
            let time = time(in: sentence) ?? (hour: 23, minute: 59)
            suggestions.append(CanvasRequirementSuggestion(
                course: course,
                title: inferredTitle(from: sentence),
                weekday: weekday,
                hour: time.hour,
                minute: time.minute,
                source: source,
                evidence: sentence
            ))
        }

        return Array(Set(suggestions)).sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func looksLikeRecurringRequirement(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let recurring = ["weekly", "each week", "every week", "each class", "before class", "by sunday", "by monday", "by tuesday", "by wednesday", "by thursday", "by friday", "by saturday"]
        let work = ["discussion", "post", "reply", "reflection", "journal", "reading response", "participation"]
        let required = ["required", "must", "should", "due", "submit", "post", "reply", "complete"]
        return recurring.contains(where: normalized.contains)
            && work.contains(where: normalized.contains)
            && required.contains(where: normalized.contains)
    }

    private static func inferredTitle(from text: String) -> String {
        let normalized = text.lowercased()
        if normalized.contains("discussion") && normalized.contains("reply") {
            return "Weekly discussion post/reply"
        }
        if normalized.contains("discussion") {
            return "Weekly discussion post"
        }
        if normalized.contains("post") || normalized.contains("reply") {
            return "Weekly post/reply"
        }
        if normalized.contains("reading response") {
            return "Weekly reading response"
        }
        if normalized.contains("reflection") {
            return "Weekly reflection"
        }
        return "Weekly course task"
    }

    private static func weekday(in text: String) -> Int? {
        let days: [(String, Int)] = [
            ("sunday", 1),
            ("monday", 2),
            ("tuesday", 3),
            ("wednesday", 4),
            ("thursday", 5),
            ("friday", 6),
            ("saturday", 7),
        ]
        let normalized = text.lowercased()
        return days.first { normalized.contains($0.0) }?.1
    }

    private static func time(in text: String) -> (hour: Int, minute: Int)? {
        let pattern = #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(match.range(at: 1), in: text),
              let meridiemRange = Range(match.range(at: 3), in: text),
              var hour = Int(text[hourRange])
        else { return nil }

        let minute: Int
        if let minuteRange = Range(match.range(at: 2), in: text) {
            minute = Int(text[minuteRange]) ?? 0
        } else {
            minute = 0
        }

        let meridiem = text[meridiemRange].lowercased()
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        return (hour, minute)
    }

    private static func cleanText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<script\b[^>]*>.*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style\b[^>]*>.*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
