import Foundation

/// The name of a piece of work, cut out of the title a fact gave it.
///
/// The extraction model is asked for an imperative title ("Take the final
/// exam") and pads it with the when and where ("... (Dec 14, 4-8, Annenberg)").
/// That is right for a record and wrong for a list: the card is something a
/// student scans, so the collapsed card shows the name alone ("Final exam")
/// and the whole title is still there once the card is opened.
///
/// This is display only. The wrong fix is rewriting the ledger row's title:
/// the ledger keeps the fact's own words, a later fact refresh matches on
/// them, and a student who edited nothing should never find the stored title
/// changed by a cosmetic rule. Every step below applies only when something
/// non-empty is left, so the worst case is the title unchanged.
///
/// Pure and deterministic: no clock, and nothing that depends on the
/// device's locale (case folding is done on an `en_US_POSIX` locale).
public enum FactTitle {

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Longest first, so "turn in" wins over a hypothetical "turn".
    private static let imperatives: [[String]] = [
        ["prepare", "for"], ["turn", "in"], ["hand", "in"], ["study", "for"],
        ["take"], ["complete"], ["finish"], ["submit"], ["do"], ["attend"],
        ["read"], ["write"], ["review"], ["sit"],
    ]

    private static let determiners: Set<String> = ["the", "your", "a", "an"]
    private static let stopWords: Set<String> = [
        "the", "your", "a", "an", "of", "for", "to", "in", "on", "at", "and",
    ]

    public static func short(_ title: String) -> String {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // a. Trim and collapse whitespace.
        var s = collapse(title)
        guard !s.isEmpty else { return title.isEmpty ? title : original.isEmpty ? title : original }

        // b. Trailing parenthetical or bracketed group, terminated or not.
        while let cut = droppingTrailingGroup(s), !cut.isEmpty { s = cut }

        // c. Trailing clause after a separator, when two or more words precede it.
        if let cut = droppingTrailingClause(s) { s = cut }

        // d. One leading imperative phrase.
        if let cut = droppingLeadingImperative(s) { s = cut }

        // e. Trailing punctuation.
        let trimmed = trimTrailingPunctuation(s)
        if !trimmed.isEmpty { s = trimmed }

        // f. Capitalise the first character only.
        if let first = s.first {
            s = String(first).uppercased(with: posix) + s.dropFirst()
        }

        // g. Nothing usable: hand back the original.
        return s.isEmpty ? title : s
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func droppingTrailingGroup(_ s: String) -> String? {
        for (open, close) in [("(", ")"), ("[", "]")] as [(Character, Character)] {
            guard let openIndex = s.lastIndex(of: open) else { continue }
            let after = s[s.index(after: openIndex)...]
            let terminated = after.contains(close)
            if terminated {
                // Only a group that ends the title is "trailing".
                guard let closeIndex = after.lastIndex(of: close),
                      s[s.index(after: closeIndex)...].allSatisfy({ !$0.isLetter && !$0.isNumber })
                else { continue }
            }
            let head = trimEnd(String(s[..<openIndex]))
            if !head.isEmpty { return head }
        }
        return nil
    }

    private static func droppingTrailingClause(_ s: String) -> String? {
        for sep in [" - ", " \u{2013} ", " \u{2014} ", ": "] {
            var searchStart = s.startIndex
            while let range = s.range(of: sep, range: searchStart..<s.endIndex) {
                let head = trimEnd(String(s[..<range.lowerBound]))
                if head.split(separator: " ").count >= 2 { return head }
                searchStart = range.upperBound
            }
        }
        return nil
    }

    private static func droppingLeadingImperative(_ s: String) -> String? {
        let words = s.split(separator: " ").map(String.init)
        let lowered = words.map { $0.lowercased(with: posix) }
        for phrase in imperatives where lowered.count > phrase.count
            && Array(lowered.prefix(phrase.count)) == phrase {
            var rest = Array(words.dropFirst(phrase.count))
            var restLower = Array(lowered.dropFirst(phrase.count))
            if let head = restLower.first, determiners.contains(head), rest.count > 1 {
                rest.removeFirst()
                restLower.removeFirst()
            }
            let nonStop = restLower.contains {
                !stopWords.contains($0.trimmingCharacters(in: .punctuationCharacters))
            }
            return nonStop ? rest.joined(separator: " ") : nil
        }
        return nil
    }

    private static func trimEnd(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimTrailingPunctuation(_ s: String) -> String {
        var out = Substring(s)
        while let last = out.last, ".,;:".contains(last) || last.isWhitespace { out = out.dropLast() }
        return String(out)
    }
}
