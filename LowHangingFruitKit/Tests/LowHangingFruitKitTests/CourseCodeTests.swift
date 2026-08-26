import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Course code parsing")
struct CourseCodeTests {
    struct Case {
        let raw: String
        let code: String
        let term: Term?
    }

    static let cases: [Case] = [
        // The motivating example: full Penn descriptor → bare code + term.
        .init(raw: "FNAR 3230-401 202610 PSYCHEDELIC ART & THE 1960s",
              code: "FNAR 3230", term: Term(year: 2026, season: .spring)),
        // Section but no term / title.
        .init(raw: "ENM 5100-001", code: "ENM 5100", term: nil),
        // Section + trailing title, no term.
        .init(raw: "CIS 5050-001 Software Systems", code: "CIS 5050", term: nil),
        // Already clean.
        .init(raw: "CIS 1200", code: "CIS 1200", term: nil),
        // Leading-zero course number (e.g. PHYS 0150).
        .init(raw: "PHYS 0150-002 202620 Physics I", code: "PHYS 0150",
              term: Term(year: 2026, season: .summer)),
        // Summer term suffix.
        .init(raw: "MATH 1400-910 202620", code: "MATH 1400",
              term: Term(year: 2026, season: .summer)),
        // Fall term suffix.
        .init(raw: "CIS 3200-001 202530 Algorithms", code: "CIS 3200",
              term: Term(year: 2025, season: .fall)),
        // 4-letter dept, 4-digit number.
        .init(raw: "MGMT 2370-403 Management", code: "MGMT 2370", term: nil),
        // Cross-listing prefix ahead of the real dept — regression for the
        // old start-anchored regex matching (or falling through on) "ban-".
        .init(raw: "ban-cis-3200-001 202630 Cross-Listed Seminar", code: "CIS 3200",
              term: Term(year: 2026, season: .fall)),
        // Same shape without a term/title suffix.
        .init(raw: "ban-cis-3200", code: "CIS 3200", term: nil),
        // The reported bug: the same cross-listed shape, but spaced. The old
        // pattern allowed exactly one separator character, so " - " matched
        // nothing and the whole raw descriptor became the course's name —
        // which is what the student then read on every card.
        .init(raw: "ban - phys - 151 - 1234", code: "PHYS 151", term: nil),
        .init(raw: "BAN - PHYS - 151 - 1234", code: "PHYS 151", term: nil),
        // Same, carrying a term and title.
        .init(raw: "ban - phys - 0150 - 001 202630 Principles of Physics",
              code: "PHYS 0150", term: Term(year: 2026, season: .fall)),
        // Underscores and typographically "smartened" dashes.
        .init(raw: "ban_phys_151_1234", code: "PHYS 151", term: nil),
        .init(raw: "phys \u{2013} 151", code: "PHYS 151", term: nil),
        // A title ending in a bare year. "THE 1960" is shaped exactly like a
        // course code, and under last-one-wins across the whole descriptor it
        // won — the class quietly renamed itself after its own title. The
        // existing "1960s" case passed only because the trailing "s" broke the
        // word boundary, so this is the same bug with the luck removed.
        .init(raw: "FNAR 3230-401 202610 PSYCHEDELIC ART & THE 1960",
              code: "FNAR 3230", term: Term(year: 2026, season: .spring)),
        // Title tail with no term code to bound the search: the code still has
        // to win, because it comes first and the tail is not delimited.
        .init(raw: "MUSC 2500-001 THE BEATLES 1967", code: "MUSC 2500", term: nil),
        // Underscore cross-listing prefix, as seen on live Penn Canvas
        // accounts — underscore is a regex word char, so `\b` doesn't fire
        // between "BAN_" and "CIS" without the underscore→space fix.
        .init(raw: "BAN_CIS-2400-001 202630", code: "CIS 2400",
              term: Term(year: 2026, season: .fall)),
        // Same underscore prefix, leading-zero course number preserved.
        .init(raw: "BAN_PHYS-0151-151 202630", code: "PHYS 0151",
              term: Term(year: 2026, season: .fall)),
        // Same course, different section — collapses to the same clean code.
        .init(raw: "BAN_PHYS-0151-402 202630", code: "PHYS 0151",
              term: Term(year: 2026, season: .fall)),
        // Bare underscore-prefixed tag with no real course after it. "BAN"
        // is already uppercase, so this satisfies the space-separator rule
        // just like a genuine dept would — there's no better interpretation
        // for a string shaped like this, so this is an accepted false
        // positive, not a bug.
        .init(raw: "BAN_2400", code: "BAN 2400", term: nil),
        // Same documented quirk with a different tag — matches the
        // already-accepted "TAP 2028" false positive.
        .init(raw: "TAP_2028", code: "TAP 2028", term: nil),
        // Non-course cohort / diagnostic space → keep the label, no term.
        .init(raw: "Class of 2028", code: "Class of 2028", term: nil),
        // Unknown-course fallback passes through unchanged.
        .init(raw: "(unknown course)", code: "(unknown course)", term: nil),
    ]

    @Test("parses clean code + term across messy Canvas descriptors")
    func parsesTable() {
        for c in Self.cases {
            let parsed = CourseCode.parse(c.raw)
            #expect(parsed.code == c.code, "code for \"\(c.raw)\" → \(parsed.code), expected \(c.code)")
            #expect(parsed.term == c.term, "term for \"\(c.raw)\" → \(String(describing: parsed.term))")
        }
    }

    @Test("containsExplicitCode agrees with extractCode's underscore handling")
    func explicitCodeDetection() {
        #expect(CourseCode.containsExplicitCode("BAN_CIS-2400-001 202630"))
        #expect(CourseCode.containsExplicitCode("ban-cis-3200-001 202630 Cross-Listed Seminar"))
        #expect(CourseCode.containsExplicitCode("FNAR 3230-401 202610 PSYCHEDELIC ART & THE 1960s"))
        #expect(!CourseCode.containsExplicitCode("Class of 2028"))
        #expect(!CourseCode.containsExplicitCode(""))
    }

    @Test("term code round-trips and orders correctly")
    func termCodes() {
        #expect(Term(code: "202610") == Term(year: 2026, season: .spring))
        #expect(Term(code: "202620") == Term(year: 2026, season: .summer))
        #expect(Term(code: "202630") == Term(year: 2026, season: .fall))
        #expect(Term(code: "abc") == nil)
        #expect(Term(code: "202640") == nil)          // 40 isn't a valid season
        #expect(Term(year: 2025, season: .fall) < Term(year: 2026, season: .spring))
        #expect(Term(year: 2026, season: .spring) < Term(year: 2026, season: .summer))
    }
}
