import Foundation

/// Presentation-only formatting; leaves the response and its sources intact.
enum AssistantPresentation {
    static func greeting(index: Int, date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch index % 3 {
        case 0: return "Ask about classes"
        case 1: return "How can I help?"
        default:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE"
            return "Happy \(formatter.string(from: date))"
        }
    }

    static func answer(_ text: String) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in result.runs {
            if var intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                intent.remove(.stronglyEmphasized)
                result[run.range].inlinePresentationIntent = intent
            }
        }
        return result
    }
}
