import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree Works audit decoder")
struct DegreeWorksAuditDecoderTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let fakeValues = ["ZZ Fake Student", "fake.student@example.invalid", "3.987", "QX7", "QX8", "QX9", "QX6"]

    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "degreeworks-audit-synthetic", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func audit() throws -> DegreeAudit {
        try DegreeWorksAuditDecoder.decode(fixture(), goals: DegreeGoals(degree: "BSE"), isWhatIf: false, now: Self.now)
    }

    @Test("header, labels and blocks decode; string numbers read")
    func basics() throws {
        let audit = try audit()
        #expect(audit.percentComplete == 42)
        #expect(audit.degreeLabel == "Bachelor of Fake Science")
        #expect(audit.catalogYearLabel == "2024-2025")
        #expect(audit.fetchedAt == Self.now)
        #expect(audit.isWhatIf == false)
        #expect(audit.blocks.map(\.type) == ["DEGREE", "MAJOR", "MINOR", "OTHER"])
        #expect(audit.blocks[0].id == "RA000001")
        #expect(audit.blocks[1].id == "MAJOR:CIS")
        #expect(audit.blocks[0].percentComplete == 55)
    }

    @Test("block status: percent 100 met, any rule in progress, else open; no ruleArray is fine")
    func blockStatus() throws {
        let blocks = try audit().blocks
        #expect(blocks[0].status == .inProgress)
        #expect(blocks[1].status == .met)
        #expect(blocks[2].status == .inProgress)
        #expect(blocks[3].status == .open)
        #expect(blocks[3].rules.isEmpty)
    }

    @Test("rule statuses, nesting and path ids")
    func rules() throws {
        let rules = try audit().blocks[0].rules
        #expect(rules[0].status == .met)
        #expect(rules[0].id == "RA000001.0")
        #expect(rules[1].ruleType == "Group")
        #expect(rules[1].status == .inProgress)
        #expect(rules[1].children.map(\.id) == ["RA000001.1.0", "RA000001.1.1"])
        #expect(rules[1].children[0].status == .inProgress)
        #expect(rules[1].children[1].status == .open)
        #expect(rules[2].ruleType == "IfStmt")
        #expect(rules[2].status == .met)
        #expect(rules[2].children[1].status == .info)
        #expect(rules[3].status == .info)
    }

    @Test("requirement, applied and advice fields")
    func ruleFields() throws {
        let rules = try audit().blocks[0].rules
        #expect(rules[0].needCourses == 1)
        #expect(rules[0].needCredits == 1)
        #expect(rules[0].appliedCount == 1)
        #expect(rules[0].appliedCredits == 1)
        #expect(rules[0].applied.map(\.code) == ["CIS 1200"])
        let open = rules[1].children[1]
        #expect(open.advice == [AdviceCourse(code: "CIS 3200", title: "Fake Algorithms", credits: 1)])
        #expect(open.adviceText == "Take one more from the list")
        #expect(rules[1].children[0].applied[0].isInProgress)
    }

    @Test("courses: unioned, deduped by id, sorted by term with nil last, codes collapsed")
    func courses() throws {
        let audit = try audit()
        #expect(audit.courses.map(\.code) == ["CIS 1200", "MATH 1400", "CIS 1210", "CIS 2400", "MATH 1410"])
        #expect(audit.courses.map(\.id) == ["CIS 1200|202430", "MATH 1400|202510", "CIS 1210|202530", "CIS 2400|202630", "MATH 1410|"])
        #expect(audit.courses[3].isInProgress)
        #expect(audit.courses[0].isInProgress == false)
        #expect(audit.courses[4].isTransfer)
        #expect(audit.courses[4].termCode == nil)
        #expect(audit.courses[0].term == Term(code: "202430"))
        #expect(audit.creditsApplied == 5)
    }

    @Test("ruleCounts walk every depth and skip info")
    func counts() throws {
        let counts = try audit().ruleCounts
        #expect(counts.met == 4)
        #expect(counts.inProgress == 3)
        #expect(counts.open == 1)
    }

    @Test("status rule table")
    func statusRule() {
        typealias D = DegreeWorksAuditDecoder
        for type in ["Complete", "Incomplete", "Noncourse", "Blocktype"] {
            #expect(D.status(percentComplete: 100, inProgressIncomplete: "Yes", ruleType: type, appliedInProgress: true) == .info)
        }
        #expect(D.status(percentComplete: 100, inProgressIncomplete: "Yes", ruleType: "Course", appliedInProgress: true) == .met)
        #expect(D.status(percentComplete: 100, inProgressIncomplete: nil, ruleType: "Block", appliedInProgress: false) == .met)
        #expect(D.status(percentComplete: 0, inProgressIncomplete: "Yes", ruleType: "Course", appliedInProgress: false) == .inProgress)
        #expect(D.status(percentComplete: nil, inProgressIncomplete: nil, ruleType: "Course", appliedInProgress: true) == .inProgress)
        #expect(D.status(percentComplete: 20, inProgressIncomplete: "No", ruleType: "Group", appliedInProgress: false) == .open)
    }

    @Test("lenient: missing arrays and odd numbers; not JSON and no blocks throw")
    func lenient() throws {
        let sparse = Data(#"{"blockArray":[{"title":"x","percentComplete":"abc","ruleArray":[{"ruleType":"Course","percentComplete":1e300,"classesApplied":"1e300"}]}]}"#.utf8)
        let audit = try DegreeWorksAuditDecoder.decode(sparse, goals: DegreeGoals(), isWhatIf: true, now: Self.now)
        #expect(audit.blocks.count == 1)
        #expect(audit.blocks[0].percentComplete == nil)
        #expect(audit.blocks[0].rules[0].appliedCount == nil)
        #expect(audit.courses.isEmpty)
        #expect(audit.isWhatIf)
        #expect(throws: DegreeWorksAuditDecoder.Failure.notJSON) {
            try DegreeWorksAuditDecoder.decode(Data("nope".utf8), goals: DegreeGoals(), isWhatIf: false, now: Self.now)
        }
        #expect(throws: DegreeWorksAuditDecoder.Failure.noBlocks) {
            try DegreeWorksAuditDecoder.decode(Data("{}".utf8), goals: DegreeGoals(), isWhatIf: false, now: Self.now)
        }
    }

    @Test("the decoded audit has no field for name, email, GPA or grade: none of the fixture's fake values survive encoding")
    func nothingPersonalSurvives() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let text = try String(decoding: encoder.encode(audit()), as: UTF8.self)
        for fake in Self.fakeValues { #expect(!text.contains(fake), "leaked \(fake)") }
        let lower = text.lowercased()
        for key in ["studentname", "studentemail", "gpa", "lettergrade", "email"] { #expect(!lower.contains(key)) }
    }

    @Test("keyShape lists key names only, never a value")
    func keyShape() throws {
        let data = try fixture()
        let lines = DegreeWorksAuditDecoder.keyShape(of: data)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("audit: "))
        #expect(lines[0].contains("blockArray"))
        #expect(lines[1].hasPrefix("block: "))
        #expect(lines[2].hasPrefix("rule: "))
        #expect(lines[3].hasPrefix("class: "))
        #expect(lines[3].contains("letterGrade"))
        let joined = lines.joined(separator: "\n")
        for fake in Self.fakeValues + ["Fake Systems", "Bachelor", "RA000001", "CIS"] { #expect(!joined.contains(fake), "leaked \(fake)") }
        #expect(DegreeWorksAuditDecoder.keyShape(of: Data("x".utf8)).isEmpty)
    }
}
