import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree plan")
struct DegreePlanTests {
    private typealias Math = DegreePlanMath

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 12
        return utc.date(from: parts)!
    }

    private func course(_ code: String, credits: Double = 1) -> PlannedCourse {
        PlannedCourse(code: code, title: nil, credits: credits)
    }

    private func plan(_ terms: (String, [String])...) -> DegreePlan {
        DegreePlan(terms: terms.map { PlannedTerm(termCode: $0.0, courses: $0.1.map { course($0) }) })
    }

    private func rule(_ id: String, _ label: String, _ status: RuleStatus,
                      advice: [String] = [], children: [AuditRule] = []) -> AuditRule {
        AuditRule(id: id, label: label, ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: nil, needCredits: nil, appliedCount: nil, appliedCredits: nil,
                  applied: [], advice: advice.map { AdviceCourse(code: $0, title: nil, credits: 1) },
                  adviceText: nil, children: children)
    }

    private func audit(blocks: [AuditBlock], courses: [AuditCourse] = []) -> DegreeAudit {
        DegreeAudit(goals: DegreeGoals(), isWhatIf: false, percentComplete: nil, degreeLabel: nil,
                    catalogYearLabel: nil, blocks: blocks, courses: courses,
                    fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func block(_ id: String, title: String = "Major", rules: [AuditRule]) -> AuditBlock {
        AuditBlock(id: id, type: "MAJOR", value: id, title: title, percentComplete: nil, rules: rules)
    }

    private func audited(_ code: String, _ term: String?, credits: Double? = 1, inProgress: Bool = false) -> AuditCourse {
        AuditCourse(code: code, title: "t", credits: credits, termCode: term, isInProgress: inProgress, isTransfer: false)
    }

    // MARK: Codes and terms

    @Test("codes are trimmed, upper-cased, de-spaced and given their space",
          arguments: [
            ("cis5200", "CIS 5200"), (" cis  5200 ", "CIS 5200"), ("CIS 5200", "CIS 5200"),
            ("math\t1400", "MATH 1400"), ("", ""), ("   ", ""), ("econ 0001a", "ECON 0001A"),
          ])
    func normalized(_ raw: String, _ expected: String) {
        #expect(Math.normalizedCode(raw) == expected)
    }

    @Test("the next term skips summers and rolls the year after fall",
          arguments: [
            ("202630", "202710"), ("202710", "202730"), ("202720", "202730"), ("202530", "202610"),
          ])
    func nextTerm(_ code: String, _ expected: String) {
        #expect(Math.nextTermCode(after: code) == expected)
    }

    @Test("an unparseable code has no next term")
    func nextTermUnparseable() {
        #expect(Math.nextTermCode(after: "soon") == nil)
        #expect(Math.nextTermCode(after: "202640") == nil)
        #expect(Math.nextTermCode(after: "") == nil)
    }

    @Test("the first term is the semester after the one containing the date")
    func firstTerm() {
        #expect(Math.firstPlanTermCode(now: Self.date(2026, 10, 15), calendar: Self.utc) == "202710")
        #expect(Math.firstPlanTermCode(now: Self.date(2027, 3, 10), calendar: Self.utc) == "202730")
        #expect(Math.firstPlanTermCode(now: Self.date(2027, 6, 20), calendar: Self.utc) == "202730")
    }

    @Test("a term reads as a lowercase season and year, or as itself")
    func label() {
        #expect(Math.termLabel("202710") == "spring 2027")
        #expect(Math.termLabel("202630") == "fall 2026")
        #expect(Math.termLabel("202620") == "summer 2026")
        #expect(Math.termLabel("nonsense") == "nonsense")
    }

    // MARK: Terms

    @Test("a term is appended after the last, or first for an empty plan, up to the cap")
    func termAdded() {
        let now = Self.date(2026, 10, 15)
        let first = Math.withTermAdded(.empty, now: now, calendar: Self.utc)
        #expect(first.terms.map(\.termCode) == ["202710"])
        let second = Math.withTermAdded(first, now: now, calendar: Self.utc)
        #expect(second.terms.map(\.termCode) == ["202710", "202730"])
        var grown = DegreePlan.empty
        for _ in 0..<(Math.maxTerms + 3) { grown = Math.withTermAdded(grown, now: now, calendar: Self.utc) }
        #expect(grown.terms.count == Math.maxTerms)
        #expect(grown.terms.map(\.termCode) == grown.terms.map(\.termCode).sorted())
        #expect(Set(grown.terms.map(\.termCode)).count == Math.maxTerms)
    }

    @Test("ensuring a first term fills an empty plan and leaves any other alone")
    func ensuring() {
        let now = Self.date(2026, 10, 15)
        #expect(Math.ensuringFirstTerm(.empty, now: now, calendar: Self.utc).terms.map(\.termCode) == ["202710"])
        let past = plan(("202510", ["CIS 1200"]))
        #expect(Math.ensuringFirstTerm(past, now: now, calendar: Self.utc) == past)
    }

    @Test("the last term goes only when empty and not alone")
    func lastTerm() {
        let withCourse = plan(("202710", []), ("202730", ["CIS 3200"]))
        #expect(Math.removingLastTermIfEmpty(withCourse) == withCourse)
        let emptyLast = plan(("202710", ["CIS 3200"]), ("202730", []))
        #expect(Math.removingLastTermIfEmpty(emptyLast).terms.map(\.termCode) == ["202710"])
        let only = plan(("202710", []))
        #expect(Math.removingLastTermIfEmpty(only) == only)
    }

    // MARK: Courses

    @Test("adding normalises the code and refuses what it should")
    func adding() {
        let base = plan(("202710", ["CIS 3200"]), ("202730", []))
        let added = Math.adding(course("cis5200", credits: 0.5), to: "202730", in: base)
        #expect(added.terms[1].courses.map(\.code) == ["CIS 5200"])
        #expect(added.terms[1].courses.first?.credits == 0.5)
        // The same course in another term, in any spelling.
        #expect(Math.adding(course("cis 3200"), to: "202730", in: base) == base)
        // A term the plan does not have.
        #expect(Math.adding(course("CIS 5200"), to: "209910", in: base) == base)
        // An empty code.
        #expect(Math.adding(course("   "), to: "202730", in: base) == base)
        // A full term.
        let full = plan(("202710", (0..<Math.maxCoursesPerTerm).map { "CIS 10\($0)" }))
        #expect(Math.adding(course("CIS 5200"), to: "202710", in: full) == full)
    }

    @Test("removing takes one course out of one term")
    func removing() {
        let base = plan(("202710", ["CIS 3200", "CIS 4500"]), ("202730", ["CIS 5200"]))
        let out = Math.removing(courseCode: "cis 3200", from: "202710", in: base)
        #expect(out.terms[0].courses.map(\.code) == ["CIS 4500"])
        #expect(out.terms[1] == base.terms[1])
        #expect(Math.removing(courseCode: "CIS 5200", from: "202710", in: base) == base)
        #expect(Math.removing(courseCode: "CIS 5200", from: "209910", in: base) == base)
    }

    // MARK: Credits

    @Test("credits add up, registered ones included")
    func credits() {
        let term = PlannedTerm(termCode: "202710", courses: [course("CIS 3200", credits: 1), course("CIS 4500", credits: 0.5)])
        #expect(Math.plannedCredits(term) == 1.5)
        let other = PlannedTerm(termCode: "202730", courses: [course("CIS 5200", credits: 1)])
        #expect(Math.totalPlannedCredits(DegreePlan(terms: [term, other])) == 2.5)
        let held = audit(blocks: [], courses: [
            audited("MATH 2400", "202710", credits: 1, inProgress: true),
            audited("MATH 2400", "202710", credits: 1, inProgress: true),
            audited("PHYS 0150", "202710", credits: nil, inProgress: true),
            audited("CIS 1200", "202710", credits: 1, inProgress: false),
            audited("ECON 0001", "202730", credits: 1, inProgress: true),
        ])
        #expect(Math.registered(in: "202710", audit: held).map(\.code) == ["MATH 2400", "PHYS 0150"])
        #expect(Math.registered(in: "202710", audit: nil).isEmpty)
        #expect(Math.termCredits(term, audit: held) == 2.5)
        #expect(Math.termCredits(term, audit: nil) == 1.5)
    }

    // MARK: Open requirements

    private var sampleAudit: DegreeAudit {
        let child = rule("c1", "Child Option", .open, advice: ["CIS 4500"])
        let parent = rule("r1", "Electives", .inProgress, advice: ["CIS 3200", "CIS 4500"], children: [child])
        let met = rule("r2", "Math", .met, advice: ["MATH 2400"])
        let noAdvice = rule("r3", "Core", .open)
        let info = rule("r4", "A note", .info, advice: ["CIS 9999"])
        let second = rule("r5", "", .open, advice: ["STAT 4300"])
        return audit(
            blocks: [block("B1", rules: [parent, met, noAdvice, info]),
                     block("B2", title: "Writing Seminar", rules: [second])],
            courses: [audited("CIS 1200", "202530")])
    }

    @Test("open requirements are depth-first, in order, and only open or in progress with options")
    func openRequirements() {
        let list = Math.openRequirements(in: sampleAudit)
        #expect(list.map(\.id) == ["B1|r1", "B1|c1", "B2|r5"])
        #expect(list.map(\.label) == ["Electives", "Child Option", "Writing Seminar"])
        #expect(list[0].options.map(\.code) == ["CIS 3200", "CIS 4500"])
        #expect(Math.openRequirements(in: nil).isEmpty)
    }

    @Test("coverage maps a planned course to the first open requirement that lists it")
    func coverage() {
        let planned = plan(("202710", ["cis4500", "CIS 3200"]), ("202730", ["PHIL 1010", "STAT 4300"]))
        let map = Math.coverage(plan: planned, audit: sampleAudit)
        #expect(map["CIS 4500"] == "Electives")
        #expect(map["CIS 3200"] == "Electives")
        #expect(map["STAT 4300"] == "Writing Seminar")
        #expect(map["PHIL 1010"] == nil)
        #expect(Math.coverage(plan: planned, audit: nil).isEmpty)
    }

    @Test("the covered count is how many open requirements have a planned option")
    func coveredCount() {
        let none = Math.coveredCount(plan: plan(("202710", ["PHIL 1010"])), audit: sampleAudit)
        #expect(none.covered == 0)
        #expect(none.open == 3)
        // CIS 4500 is an option of the parent and of the child.
        let some = Math.coveredCount(plan: plan(("202710", ["CIS 4500"])), audit: sampleAudit)
        #expect(some.covered == 2)
        #expect(some.open == 3)
        let noAudit = Math.coveredCount(plan: plan(("202710", ["CIS 4500"])), audit: nil)
        #expect(noAudit.covered == 0)
        #expect(noAudit.open == 0)
    }

    @Test("addable drops planned, taken and registered codes and empty requirements, keeping order")
    func addable() {
        let taken = audit(
            blocks: sampleAudit.blocks,
            courses: [audited("STAT 4300", "202610"), audited("CIS 3200", "202710", inProgress: true)])
        let planned = plan(("202710", ["cis 4500"]))
        let list = Math.addable(Math.openRequirements(in: taken), plan: planned, audit: taken)
        // Everything in every requirement is gone, so nothing is left.
        #expect(list.isEmpty)

        let partial = Math.addable(Math.openRequirements(in: sampleAudit), plan: plan(("202710", ["CIS 3200"])),
                                   audit: sampleAudit)
        #expect(partial.map(\.id) == ["B1|r1", "B1|c1", "B2|r5"])
        #expect(partial[0].options.map(\.code) == ["CIS 4500"])
        #expect(partial[2].options.map(\.code) == ["STAT 4300"])

        let trimmedAudit = audit(blocks: sampleAudit.blocks, courses: [audited("CIS 4500", "202610")])
        let some = Math.addable(Math.openRequirements(in: trimmedAudit), plan: .empty, audit: trimmedAudit)
        #expect(some.map(\.id) == ["B1|r1", "B2|r5"])
        #expect(some[0].options.map(\.code) == ["CIS 3200"])
    }
}

@Suite("Degree plan store")
struct DegreePlanStoreTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("degree-plan-store-\(UUID().uuidString)", isDirectory: true)
    }

    private let sample = DegreePlan(terms: [
        PlannedTerm(termCode: "202710", courses: [PlannedCourse(code: "CIS 3200", title: "algorithms", credits: 1)]),
        PlannedTerm(termCode: "202730", courses: [PlannedCourse(code: "CIS 5200", title: nil, credits: 0.5)]),
    ])

    @Test("round trip keeps everything, and a missing file reads as empty")
    func roundTrip() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreePlanStore(directory: directory)
        #expect(store.load() == .empty)
        try store.save(sample)
        #expect(store.fileURL.lastPathComponent == "degree-plan.json")
        #expect(store.load() == sample)
    }

    @Test("an undecodable file is moved aside and reads as empty")
    func corrupt() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DegreePlanStore(directory: directory)
        try Data("{ not a plan".utf8).write(to: store.fileURL)
        #expect(store.load(now: Date(timeIntervalSince1970: 1_800_000_000)) == .empty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let moved = directory.appendingPathComponent("degree-plan.json.corrupt-1800000000")
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test("clear removes the file and the quarantined copies, and nothing else")
    func clear() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DegreePlanStore(directory: directory)
        try store.save(sample)
        let quarantined = directory.appendingPathComponent("degree-plan.json.corrupt-1")
        try Data("x".utf8).write(to: quarantined)
        let other = directory.appendingPathComponent("keep.txt")
        try Data("k".utf8).write(to: other)
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: quarantined.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(store.load() == .empty)
    }

    @Test("an empty object decodes as an empty plan")
    func lenient() throws {
        let plan = try JSONDecoder().decode(DegreePlan.self, from: Data("{}".utf8))
        #expect(plan == .empty)
    }
}
