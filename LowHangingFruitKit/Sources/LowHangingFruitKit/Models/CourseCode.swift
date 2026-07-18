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

        // DEPT (2–4 letters) + optional separator + course number (3–4 digits,
        // may lead with 0, e.g. "PHYS 0150"), anchored at the start.
        if let range = trimmed.range(
            of: #"^[A-Za-z]{2,4}\s*[- ]?\s*\d{3,4}\b"#,
            options: .regularExpression
        ), let code = normalizeCode(String(trimmed[range])) {
            return Parsed(code: code, term: term)
        }

        return Parsed(code: trimmed.isEmpty ? "(unknown course)" : trimmed, term: term)
    }

    private static func normalizeCode(_ head: String) -> String? {
        guard let deptRange = head.range(of: #"[A-Za-z]{2,4}"#, options: .regularExpression),
              let numRange = head.range(of: #"\d{3,4}"#, options: .regularExpression)
        else { return nil }
        return "\(head[deptRange].uppercased()) \(head[numRange])"
    }

    private static func firstTermCode(in text: String) -> String? {
        guard let range = text.range(of: #"\b20\d{2}(?:10|20|30)\b"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}
