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

    /// Finds a DEPT + course-number pair, preferring the part of the
    /// descriptor that can actually hold a course code.
    ///
    /// Penn's canonical Canvas descriptor is `SUBJ NUMBER-SECTION TERMCODE
    /// Title…` — `PSYC 1010-005 202430 Intro to Psych`. Two things deform it
    /// in the wild, and both are handled here.
    ///
    /// **Cross-listing prefixes.** A site can arrive tagged with a leading
    /// token the student never sees in the catalogue: `ban-phys-151-1234`.
    /// The real course is the *second* dept-like token, so among candidates
    /// the last one wins — a leading decoy loses to the course that follows.
    ///
    /// **Separator drift.** The delimiter is not reliably a single character.
    /// Feeds carry `PHYS 151`, `phys-151`, and `phys - 151` — the spaced form
    /// being the one that used to fail outright, because the old pattern
    /// allowed exactly one separator character and ` - ` is three. A failed
    /// parse is not cosmetic: the raw descriptor becomes the course's identity
    /// everywhere, so `ban - phys - 151 - 1234` is what the student reads on
    /// every card, and it is the key selection, grades and dedup are all
    /// filed under. En/em dashes and underscores are accepted for the same
    /// reason.
    ///
    /// **Why the search is bounded by the term code.** Everything from
    /// `202430` onward is the human title, and titles contain things shaped
    /// exactly like course codes — `PSYCHEDELIC ART & THE 1960` ends in
    /// `THE 1960`. With last-one-wins over the whole string that title *is*
    /// the answer, and the class silently renames itself. Cutting at the term
    /// code keeps the "last wins" rule where it's needed (the prefix) and
    /// away from where it's dangerous (the title). Descriptors with no term
    /// code fall back to searching the whole string, which is the previous
    /// behavior.
    ///
    /// A whitespace-only separator still requires an uppercase dept — the
    /// Penn convention for every real example — so ordinary prose like "of"
    /// in `Class of 2028` isn't read as a department. A delimited or empty
    /// separator is accepted in any case, since that's how lowercase
    /// cross-list prefixes (`cis-3200`) arrive.
    private static func extractCode(from rawText: String) -> String? {
        // Underscore is a *word* character to the regex engine, so `\b` never
        // fires beside one and `ban_phys_151` cannot match however the pattern
        // is written. Rewriting them to hyphens up front is simpler than
        // hand-rolling boundaries, and loses nothing: an underscore only ever
        // appears here as a delimiter.
        let text = rawText.replacingOccurrences(of: "_", with: "-")

        // The region that can legitimately contain a code: everything before
        // the term stamp. `firstTermCode` finds the stamp itself; we want the
        // text preceding it.
        let codeRegion: String
        if let termRange = text.range(of: #"\b20\d{2}(?:10|20|30)\b"#, options: .regularExpression) {
            codeRegion = String(text[text.startIndex..<termRange.lowerBound])
        } else {
            codeRegion = text
        }

        return firstPass(codeRegion) ?? (codeRegion == text ? nil : firstPass(text))
    }

    /// Delimiters seen between a Penn dept and its number, beyond plain
    /// spacing. En/em dashes appear when a descriptor has been through a tool
    /// that "smartens" hyphens.
    /// No underscore: `extractCode` rewrites those to hyphens before any of
    /// this runs, so one can never reach the matcher.
    private static let delimiters: Set<Character> = ["-", "\u{2013}", "\u{2014}"]

    private static func firstPass(_ text: String) -> String? {
        // Deliberately not a raw string: the en/em dash have to arrive as real
        // characters, and `#"..."#` would pass the escape through literally and
        // leave the pattern uncompilable — which fails *silently* here, because
        // `try?` turns it into "no course code found" and every descriptor then
        // falls back to its raw form.
        guard let regex = try? NSRegularExpression(
            pattern: "\\b([A-Za-z]{2,4})([ \\t]*[-\u{2013}\u{2014}][ \\t]*|[ \\t]*)(\\d{3,4})\\b"
        ) else { return nil }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var best: String?
        for match in matches {
            let dept = nsText.substring(with: match.range(at: 1))
            let separator = nsText.substring(with: match.range(at: 2))
            let number = nsText.substring(with: match.range(at: 3))
            let isDelimited = separator.contains(where: delimiters.contains)
            // Spacing alone is only a course code when the dept is uppercase.
            guard isDelimited || separator.isEmpty || dept == dept.uppercased() else { continue }
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
