import Foundation

/// Turns Canvas's noisy course descriptor into a clean display code + term.
///
/// Canvas appends the full descriptor to each calendar SUMMARY, e.g.
/// `Homework 3 [FNAR 3230-401 202610 PSYCHEDELIC ART]`. The bracket content is
/// `DEPT NUMBER-SECTION [TERMCODE] [Title…]`. Cards want just `FNAR 3230`; the
/// `202610` term drives dashboard scoping.
public enum CourseCode {
    public struct Parsed: Sendable, Hashable {
        /// Clean display code, e.g. "FNAR 3230". Falls back to the trimmed raw
        /// label when the string isn't a recognizable Penn course code (cohort
        /// spaces, diagnostics), so nothing silently loses its name.
        public let code: String
        public let term: Term?
    }

    /// Parse the raw bracket content (already stripped of the surrounding `[ ]`).
    public static func parse(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = firstTermCode(in: trimmed).flatMap(Term.init(code:))

        if let code = extractCode(from: trimmed) {
            return Parsed(code: code, term: term)
        }

        return Parsed(code: trimmed.isEmpty ? "(unknown course)" : trimmed, term: term)
    }

    /// Finds a DEPT + course-number pair anywhere in the string, not just at
    /// the very start. Canvas descriptors are occasionally prefixed with an
    /// extra cross-listing tag (e.g. `"ban-cis-3200-001 …"`), so anchoring at
    /// `^` (the old behavior) matched the wrong token or missed entirely.
    ///
    /// DEPT (2–4 letters) + optional separator (a single dash or space) +
    /// course number (3–4 digits, may lead with 0, e.g. "PHYS 0150"). A
    /// space separator only counts as a real course code if the dept is
    /// uppercase — the Penn convention for every real example seen (`"FNAR
    /// 3230"`, `"CIS 1200"`) — so stray lowercase words followed by a number
    /// elsewhere in the string (e.g. "of" in "Class of 2028") aren't
    /// mistaken for a course. A dash/no-separator pairing is accepted
    /// regardless of case, since that's how lowercase cross-list prefixes
    /// like "cis-3200" show up. When multiple candidates match, the LAST
    /// valid one wins, so a leading decoy tag (like "ban-") loses to the real
    /// course that follows it.
    private static func extractCode(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,4})([- ]?)(\d{3,4})\b"#)
        else { return nil }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var best: String?
        for match in matches {
            let dept = nsText.substring(with: match.range(at: 1))
            let separator = nsText.substring(with: match.range(at: 2))
            let number = nsText.substring(with: match.range(at: 3))
            guard separator != " " || dept == dept.uppercased() else { continue }
            best = "\(dept.uppercased()) \(number)"
        }
        return best
    }

    private static func firstTermCode(in text: String) -> String? {
        guard let range = text.range(of: #"\b20\d{2}(?:10|20|30)\b"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}
