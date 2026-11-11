import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree timeline")
struct DegreeTimelineTests {
    private typealias Timeline = DegreeTimeline

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-15: fall 2026, code 202630.
    private static var now: Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 15
        parts.hour = 12
        return utc.date(from: parts)!
    }

    private func columns(
        history: [String: [String]] = [:], plan: DegreePlan = .empty, audit: DegreeAudit? = nil
    ) -> [TimelineColumn] {
        Timeline.columns(history: history, plan: plan, audit: audit, now: Self.now, calendar: Self.utc)
    }

    private func planned(_ terms: (String, [String])...) -> DegreePlan {
        DegreePlan(terms: terms.map { term in
            PlannedTerm(termCode: term.0,
                        courses: term.1.map { PlannedCourse(code: $0, title: nil, credits: 1) })
        })
    }

    private func audit(_ courses: [AuditCourse]) -> DegreeAudit {
        DegreeAudit(goals: DegreeGoals(), isWhatIf: false, percentComplete: nil, degreeLabel: nil,
                    catalogYearLabel: nil, blocks: [], courses: courses,
                    fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func audited(_ code: String, title: String = "t", credits: Double? = 1) -> AuditCourse {
        AuditCourse(code: code, title: title, credits: credits, termCode: nil, isInProgress: false, isTransfer: false)
    }

    @Test("a term is past, current or future against the date")
    func kinds() {
        let out = columns(history: ["202610": ["CIS 1200"], "202630": ["CIS 1210"], "202710": ["CIS 3200"]])
        #expect(out.map(\.kind) == [.past, .current, .future])
    }

    @Test("columns come out ascending by code, whatever order they went in")
    func ordering() {
        let out = columns(history: ["202710": ["A 1"], "202530": ["B 1"], "202630": ["C 1"]],
                          plan: planned(("202730", ["D 1"]), ("202610", [])))
        #expect(out.map(\.termCode) == ["202530", "202610", "202630", "202710", "202730"])
    }

    @Test("the columns are the union of the history's terms and the plan's")
    func union() {
        let out = columns(history: ["202610": ["CIS 1200"]], plan: planned(("202710", ["CIS 3200"])))
        #expect(out.map(\.termCode) == ["202610", "202710"])
        #expect(out[0].taken.map(\.code) == ["CIS 1200"])
        #expect(out[1].planned.map(\.code) == ["CIS 3200"])
    }

    @Test("a history key that is not a term code is dropped")
    func unparseable() {
        let out = columns(history: ["soon": ["CIS 1200"], "202640": ["CIS 1210"], "202610": ["MATH 1400"]])
        #expect(out.map(\.termCode) == ["202610"])
    }

    @Test("an empty history term is dropped unless the plan has it")
    func emptyTerms() {
        let dropped = columns(history: ["202610": [], "202630": ["  "]])
        #expect(dropped.isEmpty)
        let kept = columns(history: ["202710": []], plan: planned(("202710", ["CIS 3200"])))
        #expect(kept.map(\.termCode) == ["202710"])
        #expect(kept[0].taken.isEmpty)
    }

    @Test("history codes are joined to the audit for a title and credits, nil when the audit lacks them")
    func join() {
        let held = audit([audited("CIS 1200", title: "programming", credits: 1.5)])
        let out = columns(history: ["202610": ["cis1200", "MATH 1400"]], audit: held)
        #expect(out[0].taken == [
            TimelineCourse(code: "CIS 1200", title: "programming", credits: 1.5),
            TimelineCourse(code: "MATH 1400", title: nil, credits: nil),
        ])
        let bare = columns(history: ["202610": ["CIS 1200"]])
        #expect(bare[0].taken == [TimelineCourse(code: "CIS 1200", title: nil, credits: nil)])
    }

    @Test("codes are normalised and de-duplicated in order")
    func dedup() {
        let out = columns(history: ["202610": ["cis1200", "MATH 1400", "CIS 1200", " math  1400"]])
        #expect(out[0].taken.map(\.code) == ["CIS 1200", "MATH 1400"])
    }

    @Test("a planned course that is also registered in that column shows once, as taken")
    func plannedAndRegistered() {
        let out = columns(history: ["202710": ["CIS 3200"]],
                          plan: planned(("202710", ["cis 3200", "CIS 4500"])))
        #expect(out[0].taken.map(\.code) == ["CIS 3200"])
        #expect(out[0].planned.map(\.code) == ["CIS 4500"])
    }

    @Test("planned courses are empty for past and current columns")
    func plannedOnlyAhead() {
        let out = columns(history: ["202610": ["CIS 1200"]],
                          plan: planned(("202610", ["CIS 3200"]), ("202630", ["CIS 4500"]), ("202710", ["CIS 5200"])))
        #expect(out.map(\.kind) == [.past, .current, .future])
        #expect(out[0].planned.isEmpty)
        #expect(out[1].planned.isEmpty)
        #expect(out[2].planned.map(\.code) == ["CIS 5200"])
    }

    @Test("a summer term in the history is kept")
    func summer() {
        let out = columns(history: ["202620": ["CIS 1200"]])
        #expect(out.map(\.termCode) == ["202620"])
        #expect(out[0].kind == .past)
    }

    @Test("credits are what was taken plus what is planned, a course the audit lacks counting nothing")
    func credits() {
        let held = audit([audited("CIS 1200", credits: 1), audited("MATH 1400", credits: 0.5)])
        let out = columns(history: ["202710": ["CIS 1200", "MATH 1400", "PHYS 0150"]],
                          plan: DegreePlan(terms: [PlannedTerm(termCode: "202710", courses: [
                              PlannedCourse(code: "CIS 4500", title: nil, credits: 1),
                              PlannedCourse(code: "CIS 5200", title: nil, credits: 0.5),
                          ])]),
                          audit: held)
        #expect(Timeline.credits(out[0]) == 3.0)
        #expect(Timeline.credits(TimelineColumn(termCode: "202610", kind: .past, taken: [], planned: [])) == 0)
    }

    @Test("the leading column is the current one, else the first ahead, else nothing")
    func leading() {
        let withCurrent = columns(history: ["202610": ["A 1"], "202630": ["B 1"], "202710": ["C 1"]])
        #expect(Timeline.leadingColumnID(withCurrent) == "202630")
        let noCurrent = columns(history: ["202610": ["A 1"], "202710": ["C 1"], "202730": ["D 1"]])
        #expect(Timeline.leadingColumnID(noCurrent) == "202710")
        let onlyPast = columns(history: ["202610": ["A 1"]])
        #expect(Timeline.leadingColumnID(onlyPast) == nil)
        #expect(Timeline.leadingColumnID([]) == nil)
    }

    @Test("with no history the columns are the plan's terms, all ahead")
    func planOnly() {
        let plan = planned(("202710", ["CIS 3200"]), ("202730", []))
        let out = columns(plan: plan)
        #expect(out.map(\.termCode) == ["202710", "202730"])
        #expect(out.allSatisfy { $0.kind == .future && $0.taken.isEmpty })
        #expect(out.map { $0.planned.map(\.code) } == [["CIS 3200"], []])
    }
}
