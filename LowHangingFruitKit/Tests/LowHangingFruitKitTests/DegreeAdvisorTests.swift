import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree advisor")
struct DegreeAdvisorTests {
    // Mid-November 2026: fall 2026 (202630) is the current term.
    private let now = Date(timeIntervalSince1970: 1_794_600_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    private func advice(_ code: String, _ title: String? = nil, _ credits: Double? = 1) -> AdviceCourse {
        AdviceCourse(code: code, title: title, credits: credits)
    }

    private func taken(_ code: String, inProgress: Bool = false) -> AuditCourse {
        AuditCourse(code: code, title: "t", credits: 1, termCode: nil, isInProgress: inProgress, isTransfer: false)
    }

    private func rule(
        _ id: String, _ status: RuleStatus, advice: [AdviceCourse] = [], applied: [AuditCourse] = [],
        needCourses: Int? = nil, needCredits: Double? = nil, children: [AuditRule] = []
    ) -> AuditRule {
        AuditRule(id: id, label: "rule \(id)", ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: needCourses, needCredits: needCredits, appliedCount: nil, appliedCredits: nil,
                  applied: applied, advice: advice, adviceText: nil, children: children)
    }

    private func audit(_ rules: [AuditRule], percent: Double? = 40, courses: [AuditCourse] = []) -> DegreeAudit {
        DegreeAudit(
            goals: DegreeGoals(), isWhatIf: false, percentComplete: percent, degreeLabel: nil,
            catalogYearLabel: nil,
            blocks: [AuditBlock(id: "B", type: "MAJOR", value: "B", title: "Major", percentComplete: nil, rules: rules)],
            courses: courses, fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func labeled(_ id: String, _ audit: DegreeAudit) -> DegreeLabeledAudit {
        DegreeLabeledAudit(degreeID: id, label: "Deg \(id)", audit: audit)
    }

    private func plan(_ terms: [(String, [String])]) -> DegreePlan {
        DegreePlan(terms: terms.map { code, courses in
            PlannedTerm(termCode: code, courses: courses.map { PlannedCourse(code: $0, title: nil, credits: 1) })
        })
    }

    private func brief(
        _ audits: [DegreeLabeledAudit], _ plan: DegreePlan = .empty, history: [String: [String]] = [:]
    ) -> DegreeAdvisorBrief {
        DegreeAdvisor.brief(audits: audits, plan: plan, history: history, now: now, calendar: calendar)
    }

    private func simpleBrief(addable: [String]) -> DegreeAdvisorBrief {
        let terms = ["202710", "202730", "202810"].map { DegreeAdvisorTerm(code: $0, label: DegreePlanMath.termLabel($0)) }
        var map: [String: AdviceCourse] = [:]
        for code in addable { map[DegreePlanMath.normalizedCode(code)] = advice(DegreePlanMath.normalizedCode(code), "T", 1) }
        return DegreeAdvisorBrief(context: "ctx", terms: terms, addable: map)
    }

    private func action(_ op: DegreeAdvisorOp, _ code: String, _ term: String, _ to: String? = nil) -> DegreeAdvisorAction {
        DegreeAdvisorAction(op: op, code: code, term: term, toTerm: to)
    }

    private func location(_ code: String, _ plan: DegreePlan) -> String? {
        plan.terms.first { $0.courses.contains { DegreePlanMath.normalizedCode($0.code) == code } }?.termCode
    }

    // MARK: Document

    @Test("the document has its six sections in order")
    func headings() {
        let text = brief([labeled("x", audit([rule("r", .open, advice: [advice("ABCD 1000")])]))]).context
        let marks = ["DEGREES\n", "DEGREE 1: Deg x", "SEMESTERS\n", "PLAN\n", "STILL NEEDED", "WORTH\n"]
        let places = marks.compactMap { text.range(of: $0)?.lowerBound }
        #expect(places.count == 6)
        #expect(places == places.sorted())
    }

    @Test("the degrees line carries Penn's percent and omits it when there is none")
    func percentClause() {
        let withPercent = brief([labeled("x", audit([], percent: 67))]).context
        #expect(withPercent.contains("1. Deg x | penn's audit: 67% complete"))
        let without = brief([labeled("x", audit([], percent: nil))]).context
        #expect(without.contains("1. Deg x\n"))
        #expect(!without.contains("% complete"))
    }

    @Test("a met rule lists what it has and never options")
    func metRuleNoOptions() {
        let met = rule("m", .met, advice: [advice("MMMM 9999")], applied: [taken("DONE 1000")])
        let text = brief([labeled("x", audit([met]))]).context
        #expect(text.contains("- met | rule m | has: DONE 1000"))
        #expect(!text.contains("MMMM 9999"))
    }

    @Test("a registered course is marked now")
    func registeredMarked() {
        let r = rule("r", .inProgress, applied: [taken("CIS 1200", inProgress: true), taken("MATH 1400")])
        let text = brief([labeled("x", audit([r]))]).context
        #expect(text.contains("has: CIS 1200 (now), MATH 1400"))
    }

    @Test("need is stated in credits, else courses, and children are indented")
    func needAndIndent() {
        let child = rule("c", .open, needCourses: 2)
        let parent = rule("p", .open, needCredits: 3, children: [child])
        let text = brief([labeled("x", audit([parent]))]).context
        #expect(text.contains("- open | rule p | need 3 cu"))
        // A childless open rule with no options is a word requirement, so it carries a tag.
        #expect(text.contains("\n  - [R1] open | rule c | need 2 courses"))
    }

    @Test("options are capped at 25 with a count of the rest")
    func optionCap() {
        let options = (0..<30).map { advice("ZZ \(1000 + $0)") }
        let text = brief([labeled("x", audit([rule("r", .open, advice: options)]))]).context
        let line = text.split(separator: "\n").first { $0.contains("options:") }.map(String.init) ?? ""
        #expect(line.contains("ZZ 1024"))
        #expect(!line.contains("ZZ 1025"))
        #expect(line.hasSuffix("+5 more"))
    }

    @Test("a normal document never says gpa or grade")
    func noForbiddenWords() {
        let a = audit([rule("r", .open, advice: [advice("ABCD 1000", "Intro", 1)], applied: [taken("DONE 1000")])],
                      courses: [taken("DONE 1000")])
        let text = brief([labeled("x", a)], plan([("202710", ["ABCD 1000"])]), history: ["202610": ["DONE 1000"]])
            .context.lowercased()
        #expect(!text.contains("gpa"))
        #expect(!text.contains("grade"))
    }

    @Test("the same inputs give the same document")
    func deterministic() {
        let a = audit([rule("r", .open, advice: (0..<10).map { advice("ZZ \(1000 + $0)", "T", 1) })])
        let h = ["202610": ["B 1", "A 1"], "202530": ["C 1"]]
        let one = brief([labeled("x", a)], plan([("202710", ["ZZ 1001"])]), history: h)
        let two = brief([labeled("x", a)], plan([("202710", ["ZZ 1001"])]), history: h)
        #expect(one == two)
    }

    @Test("semesters list past as done and the current one as now, oldest first")
    func semesters() {
        let text = brief([labeled("x", audit([]))], history: [
            "202630": ["CIS 1200"], "202610": ["MATH 1400"], "202710": ["FUT 1000"],
        ]).context
        let done = text.range(of: "spring 2026 (done): MATH 1400")?.lowerBound
        let now = text.range(of: "fall 2026 (now): CIS 1200")?.lowerBound
        #expect(done != nil && now != nil)
        if let done, let now { #expect(done < now) }
        #expect(!text.contains("FUT 1000"))
    }

    @Test("a huge option list shrinks to fit")
    func shrinks() {
        let options = (0..<40).map { advice("BIG \(1000 + $0)", String(repeating: "word ", count: 8), 1) }
        let rules = (0..<100).map { rule("r\($0)", .open, advice: options) }
        let text = brief([labeled("x", audit(rules))]).context
        #expect(text.count <= DegreeAdvisor.maxContext)
        #expect(text.contains("WORTH"))
    }

    // MARK: Terms and addable

    @Test("terms are the plan's future terms then the following ones up to eight")
    func termsFromPlan() {
        let b = brief([], plan([("202630", []), ("202710", []), ("202730", [])]))
        #expect(b.terms.count == DegreeAdvisor.maxTerms)
        #expect(b.terms.prefix(3).map { $0.code } == ["202710", "202730", "202810"])
        #expect(b.terms[0].label == DegreePlanMath.termLabel("202710"))
        #expect(!b.terms.contains { $0.code == "202630" })
    }

    @Test("an empty plan starts at the first plan term")
    func termsFromEmptyPlan() {
        let b = brief([])
        #expect(b.terms.first?.code == DegreePlanMath.firstPlanTermCode(now: now, calendar: calendar))
        #expect(b.terms.count == DegreeAdvisor.maxTerms)
    }

    @Test("addable leaves out taken, registered, history and planned codes")
    func addableExcludes() {
        let r = rule("r", .open, advice: [
            advice("TAKEN 1000"), advice("REG 1000"), advice("HIST 1000"), advice("PLAN 1000"), advice("free 1000"),
        ])
        let a = audit([r], courses: [taken("TAKEN 1000"), taken("REG 1000", inProgress: true)])
        let b = brief([labeled("x", a)], plan([("202710", ["PLAN 1000"])]), history: ["202510": ["hist1000"]])
        #expect(Set(b.addable.keys) == ["FREE 1000"])
    }

    @Test("addable takes options of open and in-progress rules only")
    func addableStatuses() {
        let rules = [rule("m", .met, advice: [advice("MET 1000")]), rule("n", .info, advice: [advice("NOTE 1000")]),
                     rule("p", .inProgress, advice: [advice("PROG 1000")]), rule("o", .open, advice: [advice("OPEN 1000")])]
        let b = brief([labeled("x", audit(rules))])
        #expect(Set(b.addable.keys) == ["PROG 1000", "OPEN 1000"])
    }

    // MARK: Request

    @Test("the question is trimmed and cut")
    func questionTrimmed() {
        let b = simpleBrief(addable: [])
        let r = DegreeAdvisor.request(question: "  hi  \n", turns: [], brief: b, now: now)
        #expect(r.question == "hi")
        let long = DegreeAdvisor.request(question: String(repeating: "a", count: 5000), turns: [], brief: b, now: now)
        #expect(long.question.count == DegreeAdvisor.maxQuestion)
    }

    @Test("history keeps the last six turns of valid roles")
    func historyTurns() {
        let b = simpleBrief(addable: [])
        var turns = (0..<10).map { DegreeAdvisorTurn(role: $0 % 2 == 0 ? "user" : "assistant", content: "t\($0)") }
        turns.insert(DegreeAdvisorTurn(role: "system", content: "no"), at: 5)
        let r = DegreeAdvisor.request(question: "q", turns: turns, brief: b, now: now)
        #expect(r.history.map { $0.content } == ["t4", "t5", "t6", "t7", "t8", "t9"])
    }

    @Test("history drops from the front while over the character cap")
    func historyCap() {
        let b = simpleBrief(addable: [])
        let big = String(repeating: "x", count: 3000)
        let turns = [DegreeAdvisorTurn(role: "user", content: big), DegreeAdvisorTurn(role: "assistant", content: big),
                     DegreeAdvisorTurn(role: "user", content: "last")]
        let r = DegreeAdvisor.request(question: "q", turns: turns, brief: b, now: now)
        #expect(r.history.map { $0.content } == [big, "last"])
    }

    @Test("addable is the brief's keys, sorted")
    func addableSorted() {
        let b = simpleBrief(addable: ["zzz 1", "aaa 1", "mmm 1"])
        let r = DegreeAdvisor.request(question: "q", turns: [], brief: b, now: now)
        #expect(r.addable == ["AAA 1", "MMM 1", "ZZZ 1"])
        #expect(r.context == "ctx")
        #expect(r.terms == b.terms)
    }

    @Test("the request encodes with the agreed keys")
    func requestKeys() throws {
        let r = DegreeAdvisor.request(question: "q", turns: [], brief: simpleBrief(addable: []), now: now)
        let data = try JSONEncoder().encode(r)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["question", "history", "context", "terms", "addable", "programs", "requirements", "now", "round"])
    }

    private func entry(_ code: String, _ kind: DegreeProgramKind, degreeID: String?) -> DegreeProgramEntry {
        DegreeProgramEntry(
            listing: PathProgramListing(code: code, title: code), kind: kind, name: code.lowercased(),
            degreeCode: "bs", degreeID: degreeID, degreeLabel: degreeID == nil ? "" : "deg",
            collegeName: "", isSibling: degreeID != nil)
    }

    @Test("programs keep only entries within a degree, with code, name and kind")
    func programsFromEntries() {
        let entries = [
            entry("FNCS-BS", .concentration, degreeID: "d1"),
            entry("MATH-MIN", .minor, degreeID: nil),
            entry("CIS-BSE", .major, degreeID: "d2"),
        ]
        let out = DegreeAdvisor.programs(from: entries)
        #expect(out == [
            DegreeAdvisorProgram(code: "FNCS-BS", name: "fncs-bs", kind: DegreeProgramKind.concentration.tag),
            DegreeAdvisorProgram(code: "CIS-BSE", name: "cis-bse", kind: DegreeProgramKind.major.tag),
        ])
    }

    @Test("programs are capped")
    func programsCap() {
        let entries = (0..<(DegreeAdvisor.maxPrograms + 20)).map { entry("P\($0)-BS", .major, degreeID: "d") }
        #expect(DegreeAdvisor.programs(from: entries).count == DegreeAdvisor.maxPrograms)
    }

    @Test("a request built with programs carries them")
    func requestPrograms() throws {
        let programs = [DegreeAdvisorProgram(code: "FNCS-BS", name: "finance", kind: "concentration")]
        let r = DegreeAdvisor.request(question: "q", turns: [], brief: simpleBrief(addable: []),
                                      programs: programs, now: now)
        #expect(r.programs == programs)
        let data = try JSONEncoder().encode(r)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = object?["programs"] as? [[String: Any]]
        #expect(list?.first?["code"] as? String == "FNCS-BS")
    }

    @Test("a response decodes whatIf and model when present, nil when absent or blank")
    func responseWhatIf() throws {
        let decoder = JSONDecoder()
        let full = try decoder.decode(DegreeAdvisorResponse.self, from: Data(
            #"{"answer":"a","actions":[],"whatIf":"FNCS-BS","model":"m/x"}"#.utf8))
        #expect(full.whatIf == "FNCS-BS")
        #expect(full.model == "m/x")
        let bare = try decoder.decode(DegreeAdvisorResponse.self, from: Data(#"{"answer":"a"}"#.utf8))
        #expect(bare.whatIf == nil)
        #expect(bare.model == nil)
        let blank = try decoder.decode(DegreeAdvisorResponse.self, from: Data(
            #"{"answer":"a","actions":[],"whatIf":"  ","model":null}"#.utf8))
        #expect(blank.whatIf == nil)
    }

    // MARK: Response

    @Test("a response with no actions decodes to none")
    func missingActions() throws {
        let r = try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(#"{"answer":"hi"}"#.utf8))
        #expect(r.answer == "hi")
        #expect(r.actions.isEmpty)
        let n = try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(#"{"answer":"hi","actions":null}"#.utf8))
        #expect(n.actions.isEmpty)
    }

    @Test("an action that fails to decode is dropped and the rest kept")
    func lossyActions() throws {
        let json = #"""
        {"answer":"a","actions":[
          {"op":"add","code":"CIS 1","term":"202710","toTerm":null},
          {"op":"teleport","code":"CIS 2","term":"202710"},
          {"op":"move","code":5,"term":"202710"},
          {"op":"move","code":"CIS 3","term":"202710","toTerm":"202730"}]}
        """#
        let r = try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(json.utf8))
        #expect(r.actions == [action(.add, "CIS 1", "202710"), action(.move, "CIS 3", "202710", "202730")])
    }

    // MARK: Apply

    @Test("add puts the course in an existing term")
    func addExisting() {
        let out = DegreeAdvisor.apply([action(.add, "cis4710", "202710")],
                                      to: plan([("202710", [])]), brief: simpleBrief(addable: ["CIS 4710"]))
        #expect(location("CIS 4710", out.plan) == "202710")
        #expect(out.applied.map { $0.code } == ["CIS 4710"])
        #expect(out.skipped == 0)
    }

    @Test("add two terms past the plan's last creates both")
    func addCreatesTerms() {
        let out = DegreeAdvisor.apply([action(.add, "CIS 4710", "202810")],
                                      to: plan([("202710", [])]), brief: simpleBrief(addable: ["CIS 4710"]))
        #expect(out.plan.terms.map { $0.termCode } == ["202710", "202730", "202810"])
        #expect(location("CIS 4710", out.plan) == "202810")
    }

    @Test("add of a code outside addable is skipped")
    func addNotAddable() {
        let start = plan([("202710", [])])
        let out = DegreeAdvisor.apply([action(.add, "CIS 9999", "202710")], to: start, brief: simpleBrief(addable: ["CIS 4710"]))
        #expect(out.plan == start)
        #expect(out.skipped == 1)
        #expect(out.applied.isEmpty)
    }

    @Test("add to a term the brief does not offer is skipped")
    func addBadTerm() {
        let out = DegreeAdvisor.apply([action(.add, "CIS 4710", "203010")], to: plan([("202710", [])]),
                                      brief: simpleBrief(addable: ["CIS 4710"]))
        #expect(out.skipped == 1)
    }

    @Test("add of an already planned code is skipped")
    func addAlreadyPlanned() {
        let start = plan([("202710", ["CIS 4710"])])
        let out = DegreeAdvisor.apply([action(.add, "CIS 4710", "202730")], to: start, brief: simpleBrief(addable: ["CIS 4710"]))
        #expect(out.plan == start)
        #expect(out.skipped == 1)
    }

    @Test("remove takes a planned course out")
    func removeWorks() {
        let out = DegreeAdvisor.apply([action(.remove, "OIDD 1010", "202710")],
                                      to: plan([("202710", ["OIDD 1010"])]), brief: simpleBrief(addable: []))
        #expect(location("OIDD 1010", out.plan) == nil)
        #expect(out.applied.first?.termLabel == DegreePlanMath.termLabel("202710"))
    }

    @Test("remove of something not planned there is skipped")
    func removeMissing() {
        let start = plan([("202710", ["OIDD 1010"])])
        let out = DegreeAdvisor.apply([action(.remove, "OIDD 1010", "202730"), action(.remove, "NONE 1", "202710")],
                                      to: start, brief: simpleBrief(addable: []))
        #expect(out.plan == start)
        #expect(out.skipped == 2)
    }

    @Test("move changes the term and records both labels")
    func moveWorks() {
        let out = DegreeAdvisor.apply([action(.move, "STAT 1020", "202710", "202730")],
                                      to: plan([("202710", ["STAT 1020"]), ("202730", [])]), brief: simpleBrief(addable: []))
        #expect(location("STAT 1020", out.plan) == "202730")
        #expect(out.applied.first?.toTermLabel == DegreePlanMath.termLabel("202730"))
    }

    @Test("a move into a semester that already holds eight courses goes through")
    func moveIntoEightCourseTerm() {
        // 2026-11-27: a planner-made spring of eight courses (several
        // half-credit) refused every move the chat made into it.
        let eight = (1...8).map { "CIS 10\($0)" }
        let out = DegreeAdvisor.apply([action(.move, "STAT 1020", "202720", "202810")],
                                      to: plan([("202720", ["STAT 1020"]), ("202810", eight)]),
                                      brief: simpleBrief(addable: []))
        #expect(location("STAT 1020", out.plan) == "202810")
        #expect(out.skipped == 0)
        #expect(DegreePlanMath.maxCoursesPerTerm >= 12)
    }

    @Test("skipped edits are said under the answer, never hidden")
    func skippedNote() {
        #expect(DegreeAdvisor.skippedNote(applied: 2, skipped: 0) == nil)
        #expect(DegreeAdvisor.skippedNote(applied: 0, skipped: 1)?.hasPrefix("that change didn't go into your plan") == true)
        #expect(DegreeAdvisor.skippedNote(applied: 0, skipped: 2)?.hasPrefix("none of those changes") == true)
        #expect(DegreeAdvisor.skippedNote(applied: 1, skipped: 1) == "1 of 2 changes didn't go into your plan.")
    }

    @Test("move to the same term, or without a target, is skipped")
    func moveSame() {
        let start = plan([("202710", ["STAT 1020"])])
        let out = DegreeAdvisor.apply([action(.move, "STAT 1020", "202710", "202710"), action(.move, "STAT 1020", "202710")],
                                      to: start, brief: simpleBrief(addable: []))
        #expect(out.plan == start)
        #expect(out.skipped == 2)
    }

    @Test("actions apply in order, so an add then a move of the same course works")
    func orderMatters() {
        let out = DegreeAdvisor.apply(
            [action(.add, "CIS 4710", "202710"), action(.move, "CIS 4710", "202710", "202730")],
            to: plan([("202710", [])]), brief: simpleBrief(addable: ["CIS 4710"]))
        #expect(location("CIS 4710", out.plan) == "202730")
        #expect(out.applied.count == 2)
        #expect(out.skipped == 0)
    }

    @Test("skipped counts exactly the invalid actions")
    func skippedCount() {
        let out = DegreeAdvisor.apply(
            [action(.add, "CIS 4710", "202710"), action(.add, "BAD 1", "202710"), action(.remove, "NOPE 1", "202710")],
            to: plan([("202710", [])]), brief: simpleBrief(addable: ["CIS 4710"]))
        #expect(out.applied.count == 1)
        #expect(out.skipped == 2)
    }

    // MARK: Summary

    private func change(_ op: DegreeAdvisorOp, _ code: String, _ term: String, _ to: String? = nil) -> DegreeAdvisorChange {
        DegreeAdvisorChange(op: op, code: code, termLabel: term, toTermLabel: to)
    }

    @Test("summary groups by operation and term, adds then moves then removes")
    func summaryLines() {
        let lines = DegreeAdvisor.summary([
            change(.remove, "OIDD 1010", "spring 2027"),
            change(.add, "CIS 4710", "fall 2027"),
            change(.move, "STAT 1020", "spring 2027", "fall 2027"),
            change(.add, "CIS 4010", "fall 2027"),
            change(.add, "MATH 1410", "spring 2027"),
        ])
        #expect(lines == [
            "added CIS 4710, CIS 4010 · fall 2027",
            "added MATH 1410 · spring 2027",
            "moved STAT 1020 · spring 2027 → fall 2027",
            "removed OIDD 1010 · spring 2027",
        ])
        #expect(DegreeAdvisor.summary([]).isEmpty)
    }

    // MARK: Grouping

    private func suggestion(_ code: String, _ degrees: [String]) -> DegreeSuggestion {
        DegreeSuggestion(
            course: advice(code),
            gains: degrees.map { DegreeGain(degreeID: $0, degreeLabel: "Deg \($0)", requirement: "r", points: 1) })
    }

    @Test("one audit gives one untitled group, and nothing gives none")
    func groupedSingle() {
        let s = [suggestion("A 1", ["x"]), suggestion("B 1", ["x"])]
        let groups = DegreeContribution.grouped(s, audits: [labeled("x", audit([]))])
        #expect(groups.count == 1)
        #expect(groups[0].id == "")
        #expect(groups[0].title == "")
        #expect(groups[0].suggestions == s)
        #expect(DegreeContribution.grouped([], audits: [labeled("x", audit([]))]).isEmpty)
    }

    @Test("two audits give both, then each degree, empties omitted, ranked order kept")
    func groupedTwo() {
        let s = [suggestion("A 1", ["y"]), suggestion("B 1", ["x", "y"]), suggestion("C 1", ["y"]), suggestion("D 1", ["x", "y"])]
        let audits = [labeled("x", audit([])), labeled("y", audit([]))]
        let groups = DegreeContribution.grouped(s, audits: audits)
        #expect(groups.map { $0.id } == ["both", "y"])
        #expect(groups[0].title == "both degrees")
        #expect(groups[0].suggestions.map { $0.course.code } == ["B 1", "D 1"])
        #expect(groups[1].title == "deg y")
        #expect(groups[1].suggestions.map { $0.course.code } == ["A 1", "C 1"])
        let all = DegreeContribution.grouped([suggestion("E 1", ["x"]), suggestion("F 1", ["y"])], audits: audits)
        #expect(all.map { $0.id } == ["x", "y"])
    }

    // MARK: Word requirements, picks, finish

    private func word(
        _ id: String, _ status: RuleStatus = .open, patterns: [String] = [], words: String? = nil,
        needCourses: Int? = nil, needCredits: Double? = nil, children: [AuditRule] = []
    ) -> AuditRule {
        AuditRule(id: id, label: "rule \(id)", ruleType: "Subset", percentComplete: nil, status: status,
                  needCourses: needCourses, needCredits: needCredits, appliedCount: nil, appliedCredits: nil,
                  applied: [], advice: patterns.map { AdviceCourse(code: $0, title: nil, credits: nil) },
                  adviceText: words, children: children)
    }

    @Test("tags go to childless open or in-progress rules with no concrete option, depth first")
    func tagging() {
        let tree = [
            word("a"),
            word("p", children: [word("c", .inProgress)]),
            word("w", patterns: ["MGMT @"]),
            word("mixed", patterns: ["MGMT @", "CIS 1000"]),
            word("done", .met),
            word("note", .info),
        ]
        let tagged = DegreeAdvisor.tagRequirements([labeled("x", audit(tree))])
        #expect(tagged.map { $0.info.requirement.tag } == ["R1", "R2", "R3"])
        #expect(tagged.map { $0.info.label } == ["rule a", "rule c", "rule w"])
        #expect(tagged[2].info.requirement.patterns == ["MGMT @"])
        #expect(tagged[0].info.ruleKey == DegreeProjection.key(blockID: "B", ruleID: "a"))
        #expect(tagged[0].info.degreeID == "x")
    }

    @Test("the document marks tagged rules and prints penn's words on any rule")
    func documentTagsAndWords() {
        let tree = [
            word("w", patterns: ["MGMT @"], words: "  Take any\n 300-level   MGMT course  ", needCourses: 2),
            word("m", .met, words: "all done"),
        ]
        let text = brief([labeled("x", audit(tree))]).context
        #expect(text.contains("- [R1] open | rule w | need 2 courses | options: MGMT @ | penn's words: Take any 300-level MGMT course"))
        #expect(text.contains("- met | rule m | penn's words: all done"))
        let long = brief([labeled("x", audit([word("l", words: String(repeating: "a", count: 500))]))]).context
        let line = long.split(separator: "\n").first { $0.contains("penn's words:") }.map(String.init) ?? ""
        #expect(line.hasSuffix(String(repeating: "a", count: 200)))
        #expect(!line.hasSuffix(String(repeating: "a", count: 201)))
    }

    @Test("FINISH names the eighth fall or spring semester from the first, ignoring summers")
    func finishSection() {
        let a = labeled("x", audit([]))
        let text = brief([a], history: ["202510": ["A 1"], "202530": ["B 1"]]).context
        #expect(text.contains("\nFINISH\nexpected final semester: fall 2028 (eight fall and spring semesters from spring 2025, the first in SEMESTERS; the student may say otherwise)"))
        let marks = ["SEMESTERS\n", "FINISH\n", "PLAN\n"]
        let places = marks.compactMap { text.range(of: $0)?.lowerBound }
        #expect(places.count == 3 && places == places.sorted())
        let summer = brief([a], history: ["202420": ["A 1"], "202530": ["B 1"]]).context
        #expect(summer.contains("expected final semester: spring 2029 (eight fall and spring semesters from fall 2025"))
        #expect(!brief([a]).context.contains("FINISH"))
        #expect(!brief([a], history: ["202420": ["A 1"]]).context.contains("FINISH"))
    }

    @Test("the request carries the requirements sorted by tag, with the wire fields")
    func requestRequirements() throws {
        let tree = [word("a", needCourses: 4), word("b", patterns: ["MGMT @", "@ @"], needCredits: 2)]
        let b = brief([labeled("x", audit(tree))])
        #expect(Set(b.requirements.keys) == ["R1", "R2"])
        let r = DegreeAdvisor.request(question: "q", turns: [], brief: b, now: now)
        #expect(r.requirements.map { $0.tag } == ["R1", "R2"])
        #expect(r.requirements[0].need == "need 4 courses")
        #expect(r.requirements[1].need == "need 2 cu")
        #expect(r.requirements[1].degree == "Deg x")
        let data = try JSONEncoder().encode(r)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = object?["requirements"] as? [[String: Any]]
        #expect(list?.count == 2)
        #expect(Set(list?.first?.keys.map { $0 } ?? []) == ["tag", "label", "degree", "need", "patterns"])
        #expect(list?.last?["patterns"] as? [String] == ["MGMT @", "@ @"])
    }

    @Test("an action decodes for, title and credits when present and leaves them nil when absent")
    func actionExtras() throws {
        let json = #"""
        {"answer":"a","actions":[
          {"op":"add","code":"MGMT 2010","term":"202710","toTerm":null,"for":"R2","title":"Mgmt","credits":1.5},
          {"op":"add","code":"CIS 1","term":"202710"},
          {"op":"add","code":"CIS 2","term":"202710","credits":"lots"}]}
        """#
        let r = try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(json.utf8))
        #expect(r.actions.count == 3)
        #expect(r.actions[0].requirement == "R2")
        #expect(r.actions[0].title == "Mgmt")
        #expect(r.actions[0].credits == 1.5)
        #expect(r.actions[1].requirement == nil && r.actions[1].title == nil && r.actions[1].credits == nil)
        #expect(r.actions[2].credits == nil)
    }

    private func pickBrief(patterns: [String] = ["MGMT @"], courses: [AuditCourse] = []) -> DegreeAdvisorBrief {
        brief([labeled("x", audit([word("w", patterns: patterns, needCourses: 2)], courses: courses))],
              plan([("202710", [])]))
    }

    private func pick(_ code: String, for tag: String? = "R1", term: String = "202710") -> DegreeAdvisorAction {
        DegreeAdvisorAction(op: .add, code: code, term: term, toTerm: nil, requirement: tag, title: " Mgmt Elective ", credits: 1.5)
    }

    @Test("a valid pick is filed with its title, credits and requirement")
    func pickAccepted() {
        let out = DegreeAdvisor.apply([pick("mgmt2010")], to: plan([("202710", [])]), brief: pickBrief())
        #expect(out.skipped == 0)
        let course = out.plan.terms.first?.courses.first
        #expect(course?.code == "MGMT 2010")
        #expect(course?.title == "Mgmt Elective")
        #expect(course?.credits == 1.5)
        #expect(course?.pickRuleKey == DegreeProjection.key(blockID: "B", ruleID: "w"))
        #expect(course?.pickLabel == "rule w")
    }

    @Test("a pick with no patterns on its requirement is accepted for any well-formed code")
    func pickNoPatterns() {
        let out = DegreeAdvisor.apply([pick("ACCT 1010")], to: plan([("202710", [])]), brief: pickBrief(patterns: []))
        #expect(out.skipped == 0)
    }

    @Test("a pick is skipped for a wrong tag, a bad shape, a pattern miss, a taken or a planned course")
    func pickRejected() {
        let base = plan([("202710", [])])
        let b = pickBrief(courses: [taken("MGMT 3010")])
        #expect(DegreeAdvisor.apply([pick("MGMT 2010", for: "R9")], to: base, brief: b).skipped == 1)
        #expect(DegreeAdvisor.apply([pick("MGMT 2010", for: nil)], to: base, brief: b).skipped == 1)
        #expect(DegreeAdvisor.apply([pick("MGMT 20")], to: base, brief: b).skipped == 1)
        #expect(DegreeAdvisor.apply([pick("MGMTXX 2010")], to: base, brief: b).skipped == 1)
        #expect(DegreeAdvisor.apply([pick("M 2010")], to: base, brief: b).skipped == 1)
        #expect(DegreeAdvisor.apply([pick("ACCT 1010")], to: base, brief: b).skipped == 1)
        #expect(DegreeAdvisor.apply([pick("MGMT 3010")], to: base, brief: b).skipped == 1)
        #expect(DegreeAdvisor.apply([pick("MGMT 2010", term: "209910")], to: base, brief: b).skipped == 1)
        let twice = DegreeAdvisor.apply([pick("MGMT 2010"), pick("MGMT 2010")], to: base, brief: b)
        #expect(twice.applied.count == 1 && twice.skipped == 1)
    }

    @Test("an addable course added with a valid tag records the pick fields; without one it does not")
    func addableWithTag() {
        let tree = [word("w", patterns: ["MGMT @"]), word("c", patterns: ["CIS 1000"])]
        let b = brief([labeled("x", audit(tree))], plan([("202710", [])]))
        // "CIS 1000" is a concrete option, so it is addable; the wildcard rule is R1.
        #expect(b.addable["CIS 1000"] != nil)
        let tagged = DegreeAdvisor.apply([pick("CIS 1000", for: "R1")], to: plan([("202710", [])]), brief: b)
        #expect(tagged.plan.terms.first?.courses.first?.pickLabel == "rule w")
        let plain = DegreeAdvisor.apply([pick("CIS 1000", for: nil)], to: plan([("202710", [])]), brief: b)
        #expect(plain.plan.terms.first?.courses.first?.pickLabel == nil)
    }

    @Test("wildcard advice codes are never addable or suggested")
    func wildcardsExcluded() {
        let a = labeled("x", audit([word("w", patterns: ["MGMT @", "CIS 1000"])]))
        let b = brief([a])
        #expect(Set(b.addable.keys) == ["CIS 1000"])
        let ranked = DegreeContribution.suggestions(plan: .empty, audits: [a], history: [:])
        #expect(ranked.map { $0.course.code } == ["CIS 1000"])
    }

    @Test("an old planned course without pick fields decodes; one with them round-trips")
    func plannedCourseCoding() throws {
        let old = try JSONDecoder().decode(PlannedCourse.self, from: Data(#"{"code":"A 1","credits":1}"#.utf8))
        #expect(old.pickRuleKey == nil && old.pickLabel == nil && old.title == nil)
        let picked = PlannedCourse(code: "A 1", title: "t", credits: 2, pickRuleKey: "B|w", pickLabel: "rule w")
        let back = try JSONDecoder().decode(PlannedCourse.self, from: JSONEncoder().encode(picked))
        #expect(back == picked)
    }

    @Test("adding and moving keep the pick fields")
    func picksSurviveEdits() {
        let picked = PlannedCourse(code: "MGMT 2010", title: nil, credits: 1, pickRuleKey: "B|w", pickLabel: "rule w")
        let base = plan([("202710", []), ("202730", [])])
        let added = DegreePlanMath.adding(picked, to: "202710", in: base)
        let moved = DegreePlanMath.moving(courseCode: "MGMT 2010", to: "202730", before: nil, in: added)
        #expect(moved.terms[1].courses.first?.pickLabel == "rule w")
        #expect(moved.terms[1].courses.first?.pickRuleKey == "B|w")
    }

    @Test("matchesPattern follows the wildcard rules")
    func patternTable() {
        let rows: [(String, String, Bool)] = [
            ("MGMT 2010", "MGMT @", true), ("MGMT 2010", "@ @", true), ("ACCT 2010", "MGMT @", false),
            ("MGMT 2010", "MGMT 2@@", true), ("MGMT 3010", "MGMT 2@@", false),
            ("MGMT 2010", "MGMT 2010", true), ("MGMT 2011", "MGMT 2010", false),
            ("mgmt2010", "MGMT @", true), ("MGMT 2010", "MGMT", true), ("ACCT 2010", "MGMT", false),
            ("MGMT 2010", "MGMT 2@1", false), ("MGMT 2010", "MGMT x", false),
            ("MGMT 2010", "MGMT @@@@", true), ("MGMT 2010", "MGMT 20@@", true),
            ("MGMT 2010", "MGMT 21@@", false), ("MGMT 2010", "MGMT 1 2", false), ("", "@ @", false),
        ]
        for (code, pattern, expected) in rows {
            #expect(DegreePlanMath.matchesPattern(code, pattern) == expected, "\(code) vs \(pattern)")
        }
    }

    // MARK: Still needed, rounds

    private func needsLines(_ text: String) -> [String] {
        guard let start = text.range(of: "STILL NEEDED (after the plan as it stands; this app's estimate)\n") else { return [] }
        let rest = text[start.upperBound...]
        let section = rest.range(of: "\n\nWORTH").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        return section.split(separator: "\n").map(String.init)
    }

    @Test("STILL NEEDED lists a tagged word requirement and an addable one, singular and plural")
    func stillNeededSection() {
        let tree = [
            word("w", patterns: ["MGMT @"], needCourses: 2),
            word("one", needCourses: 1),
            rule("o", .open, advice: [advice("OPTA 1000")], needCredits: 1.5),
        ]
        let b = brief([labeled("x", audit(tree))])
        #expect(needsLines(b.context) == [
            "Deg x | [R1] rule w | 2 courses left",
            "Deg x | [R2] rule one | 1 course left",
            "Deg x | rule o | 1.5 cu left | options in ADDABLE",
        ])
        #expect(b.fillableNeeds == 3)
    }

    @Test("STILL NEEDED omits a need the model cannot act on and says none when empty")
    func stillNeededOmitsAndNone() {
        // A rule whose only options are already taken is neither tagged nor addable.
        let dead = rule("d", .open, advice: [advice("DONE 1000")], needCourses: 1)
        let b = brief([labeled("x", audit([dead], courses: [taken("DONE 1000")]))])
        #expect(needsLines(b.context) == ["none"])
        #expect(b.fillableNeeds == 0)
    }

    @Test("a pick that fills a word requirement takes it off STILL NEEDED")
    func stillNeededAfterPick() {
        let tree = [word("w", patterns: ["MGMT @"], needCourses: 1)]
        let picked = DegreePlan(terms: [PlannedTerm(termCode: "202710", courses: [
            PlannedCourse(code: "MGMT 2010", title: nil, credits: 1, pickRuleKey: "B|w", pickLabel: "rule w")])])
        let b = brief([labeled("x", audit(tree))], picked)
        #expect(needsLines(b.context) == ["none"])
        #expect(b.fillableNeeds == 0)
    }

    @Test("the request always encodes round, clamped to 1...3")
    func requestRound() throws {
        let b = simpleBrief(addable: [])
        func round(_ value: Int?) throws -> Int? {
            let r = value.map { DegreeAdvisor.request(question: "q", turns: [], brief: b, now: now, round: $0) }
                ?? DegreeAdvisor.request(question: "q", turns: [], brief: b, now: now)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any]
            return object?["round"] as? Int
        }
        #expect(try round(nil) == 1)
        #expect(try round(2) == 2)
        #expect(try round(9) == 3)
        #expect(try round(0) == 1)
    }

    @Test("the response decodes planning and dropped, and defaults them when absent")
    func responsePlanningDropped() throws {
        let with = #"{"answer":"a","actions":[],"planning":true,"dropped":["MGMT 9999","X 1"]}"#
        let a = try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(with.utf8))
        #expect(a.planning)
        #expect(a.dropped == ["MGMT 9999", "X 1"])
        let without = #"{"answer":"a","actions":[]}"#
        let b = try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(without.utf8))
        #expect(!b.planning)
        #expect(b.dropped.isEmpty)
        let bad = #"{"answer":"a","actions":[],"planning":"yes","dropped":5}"#
        let c = try JSONDecoder().decode(DegreeAdvisorResponse.self, from: Data(bad.utf8))
        #expect(!c.planning)
        #expect(c.dropped.isEmpty)
    }
}
