import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Path@Penn audit decoder")
struct PathAuditDecoderTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "path-audit-synthetic", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func audit() throws -> DegreeAudit {
        try PathAuditDecoder.decode(fixture(), fallbackGoals: nil, isWhatIf: false, now: Self.now)
    }

    private func inline(_ json: String, fallback: DegreeGoals? = nil) throws -> DegreeAudit {
        try PathAuditDecoder.decode(Data(json.utf8), fallbackGoals: fallback, isWhatIf: true, now: Self.now)
    }

    private func find(_ id: String, in rules: [AuditRule]) -> AuditRule? {
        for rule in rules {
            if rule.id == id { return rule }
            if let found = find(id, in: rule.children) { return found }
        }
        return nil
    }

    private func allIDs(_ rules: [AuditRule]) -> [String] {
        rules.flatMap { [$0.id] + allIDs($0.children) }
    }

    @Test("blocks keep their order, titles and percent; the DEGREE block fills the audit header")
    func blocks() throws {
        let audit = try audit()
        #expect(audit.blocks.map(\.type) == ["DEGREE", "MAJOR", "OTHER", "CL_SYNTHETIC_BLOCK"])
        #expect(audit.blocks.map(\.id) == ["RA000001", "RA000002", "RA000003", "synthetic"])
        #expect(audit.blocks.map(\.title) == [
            "Degree in Example Studies", "Major in Example Studies", "General Electives", "Unassigned",
        ])
        #expect(audit.blocks.map(\.percentComplete) == [60, 50, 100, 0])
        #expect(audit.percentComplete == 60)
        #expect(audit.degreeLabel == "Degree in Example Studies")
        #expect(audit.catalogYearLabel == "2024")
        #expect(audit.fetchedAt == Self.now)
        #expect(audit.isWhatIf == false)
        #expect(audit.blocks[3].rules.isEmpty)
    }

    @Test("goals come from degreeInfo: NCON and an empty minor are dropped")
    func goals() throws {
        let goals = try audit().goals
        #expect(goals.school == "UG")
        #expect(goals.college == "COL")
        #expect(goals.program == "EXAMPLE")
        #expect(goals.degree == "BS")
        #expect(goals.majors == ["EXST"])
        #expect(goals.concentrations.isEmpty)
        #expect(goals.minors.isEmpty)
        #expect(goals.catalogYear == "2024")
    }

    @Test("a top-level term wrapper is unwrapped")
    func termUnwrapped() throws {
        let rules = try audit().blocks[0].rules
        #expect(rules.map(\.ruleType) == ["header", "comment", "comment", "comment"])
        #expect(rules.map(\.label).first == "Core Requirements")
    }

    @Test("bare courses at block level become one synthetic courses rule")
    func bareCourses() throws {
        let rules = try audit().blocks[2].rules
        #expect(rules.count == 1)
        let rule = rules[0]
        #expect(rule.id == "RA000003.courses")
        #expect(rule.label == "courses")
        #expect(rule.ruleType == "courses")
        #expect(rule.status == .met)
        #expect(rule.applied.map(\.code) == ["DEMO 1100", "DEMO 2000"])
        #expect(rule.children.isEmpty)
        #expect(rule.appliedCount == 2)
        #expect(rule.appliedCredits == 1.5)
    }

    @Test("courses with an icon are applied, the rest are advice; registered is in progress; duplicates and codeless nodes are dropped")
    func appliedAndAdvice() throws {
        let rule = try #require(find("S1", in: try audit().blocks[0].rules))
        #expect(rule.applied.map(\.code) == ["EXMP 1010", "EXMP 2020"])
        #expect(rule.applied.map(\.isInProgress) == [false, true])
        #expect(rule.applied[0].title == "Intro to Examples")
        #expect(rule.advice.map(\.code) == ["DEMO 1100", "DEMO 1200"])
        #expect(rule.advice[0].title == "Demonstration One")
        #expect(rule.advice[0].credits == 1)
        #expect(rule.appliedCount == 2)
        #expect(rule.adviceText == "Pick any two.")
    }

    @Test("status: completed, registered, partial with and without an in-progress course, info comment")
    func statuses() throws {
        let rules = try audit().blocks[0].rules
        #expect(find("S3", in: rules)?.status == .met)
        #expect(find("S4", in: rules)?.status == .inProgress)
        #expect(find("S1", in: rules)?.status == .inProgress)
        #expect(find("DUP", in: rules)?.status == .open)
        #expect(find("C2", in: rules)?.status == .info)
        #expect(find("MS1", in: try audit().blocks[1].rules)?.status == .met)
    }

    @Test("needCourses reads membersNeeded, then coursesNeeded")
    func needCourses() throws {
        let audit = try audit()
        #expect(find("S1", in: audit.blocks[0].rules)?.needCourses == 2)
        #expect(find("MS1", in: audit.blocks[1].rules)?.needCourses == 2)
        #expect(find("C2", in: audit.blocks[0].rules)?.needCourses == nil)
    }

    @Test("credits parse from string hours, with a unit and as a JSON number")
    func credits() throws {
        let audit = try audit()
        let s1 = try #require(find("S1", in: audit.blocks[0].rules))
        #expect(s1.applied.map(\.credits) == [1, 1.5])
        #expect(s1.appliedCredits == 2.5)
        #expect(s1.needCredits == 2)
        let s3 = try #require(find("S3", in: audit.blocks[0].rules))
        #expect(s3.applied.first?.credits == 1)
    }

    @Test("rule ids are unique across the whole audit; a repeated node id is suffixed with its path")
    func uniqueIDs() throws {
        let audit = try audit()
        let ids = audit.blocks.flatMap { allIDs($0.rules) }
        #expect(ids.count == Set(ids).count)
        #expect(ids.contains("DUP"))
        #expect(ids.contains("DUP@RA000001.3"))
    }

    @Test("audit courses are deduped by code, preferring a finished copy, and sorted")
    func courseList() throws {
        let courses = try audit().courses
        #expect(courses.map(\.code) == ["DEMO 1100", "DEMO 2000", "EXMP 1010", "EXMP 2020", "EXMP 3030", "EXMP 4040"])
        #expect(courses.allSatisfy { !$0.isInProgress })
    }

    @Test("creditTotals reads the DEGREE block's label; nil when none matches")
    func creditTotals() throws {
        let totals = try #require(PathAuditDecoder.creditTotals(in: try audit()))
        #expect(totals.have == 24)
        #expect(totals.need == 40)

        let bare = try inline(#"{"blocks":[{"id":"B","type":"DEGREE","title":"t","completionPercent":1,"courseReqCopy":{"members":[{"type":"comment","label":"hello"}]}}]}"#)
        #expect(PathAuditDecoder.creditTotals(in: bare) == nil)
    }

    @Test("nothing from blockhtml, legendHtml or actionsMap survives into the decoded audit")
    func sentinels() throws {
        let raw = String(decoding: try fixture(), as: UTF8.self)
        #expect(raw.contains("GRADE-SENTINEL-A+"))
        #expect(raw.contains("ACTION-SENTINEL"))
        let encoded = String(decoding: try JSONEncoder().encode(audit()), as: UTF8.self)
        #expect(!encoded.contains("GRADE-SENTINEL"))
        #expect(!encoded.contains("ACTION-SENTINEL"))
    }

    @Test("not JSON and no blocks both fail")
    func failures() {
        #expect(throws: PathAuditDecoder.Failure.notJSON) {
            try PathAuditDecoder.decode(Data("not json".utf8), fallbackGoals: nil, isWhatIf: false, now: Self.now)
        }
        #expect(throws: PathAuditDecoder.Failure.noBlocks) {
            try PathAuditDecoder.decode(Data(#"{"blocks":[]}"#.utf8), fallbackGoals: nil, isWhatIf: false, now: Self.now)
        }
    }

    @Test("fallback goals are used when degreeInfo is absent; what-if is passed through")
    func fallbackGoals() throws {
        let fallback = DegreeGoals(degree: "BSE", majors: ["CIS"])
        let audit = try inline(#"{"blocks":[{"id":"B","type":"DEGREE","title":"t","completionPercent":10}]}"#, fallback: fallback)
        #expect(audit.goals == fallback)
        #expect(audit.isWhatIf == true)
        #expect(audit.catalogYearLabel == nil)
        #expect(audit.blocks[0].rules.isEmpty)
    }
}
