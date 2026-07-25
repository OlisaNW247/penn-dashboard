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
