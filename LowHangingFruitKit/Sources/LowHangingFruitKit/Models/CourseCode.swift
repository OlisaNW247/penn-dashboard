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
    /// extra cross-listing tag (e.g. `"ban-cis-3200-001 …"` or, on live Penn
    /// accounts, `"BAN_CIS-2400-001 202630"`), so anchoring at `^` (the old
    /// behavior) matched the wrong token or missed entirely.
    ///
    /// Underscore is a regex word character, so `\b` doesn't fire between a
    /// `BAN_` prefix and the department that follows it — the whole match
    /// would silently fail and `parse` would fall back to the raw registrar
    /// string. Underscores are only ever used by Canvas as a prefix
    /// separator, never inside a real dept or course number, so they're
    /// swapped for spaces before matching; this also folds the underscore
    /// variant into the same last-match-wins handling as the dash variant
    /// below, with no regex changes needed.
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
    /// valid one wins, so a leading decoy tag (like "ban-" or "BAN_") loses
    /// to the real course that follows it.
    private static func extractCode(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z]{2,4})([- ]?)(\d{3,4})\b"#)
        else { return nil }
        let normalized = text.replacingOccurrences(of: "_", with: " ")
        let nsText = normalized as NSString
        let matches = regex.matches(in: normalized, range: NSRange(location: 0, length: nsText.length))

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

    /// True iff `raw` contains a recognizable DEPT + number course code
    /// (i.e. `extractCode(from:)` finds a match). Distinguishes a real
    /// DEPT+number course site from a Canvas community/resource site whose
    /// name never carries one — a diagnostic, a class-year cohort org, or an
    /// archive (e.g. "Chemistry Diagnostic 2024-2025", "Penn Engineering
    /// Class of 2028", "Physics Exam Archive") — which `parse` falls back to
    /// returning verbatim as its "code" rather than failing outright.
    /// Exposed only as this read-only wrapper; `parse`'s own behavior (its
    /// verbatim fallback for unparseable names) is unchanged.
    public static func containsExplicitCode(_ raw: String) -> Bool {
        extractCode(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    private static func firstTermCode(in text: String) -> String? {
        guard let range = text.range(of: #"\b20\d{2}(?:10|20|30)\b"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}
