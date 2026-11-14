import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Degree program search")
struct DegreeProgramSearchTests {
    private static let catalogue: [PathProgramListing] = [
        PathProgramListing(code: "FNCS-BS", title: "Finance BS"),
        PathProgramListing(code: "ACCT-BS", title: "Accounting BS"),
        PathProgramListing(code: "BSAN-BS", title: "Business Analytics BS"),
        PathProgramListing(code: "AIBU-BS", title: "AI for Business BS"),
        PathProgramListing(code: "CSCI-BSE", title: "Computer Science BSE"),
        PathProgramListing(code: "CSCI-BSE-NCON", title: "Computer Science BSE (No Concentration)"),
        PathProgramListing(code: "CSCI-BSE-AINT", title: "Computer Science BSE (Artificial Intelligence)"),
        PathProgramListing(code: "CMPE-BSE", title: "Computer Engineering BSE"),
        PathProgramListing(code: "DMD-BSE", title: "Digital Media Design BSE"),
        PathProgramListing(code: "ECON-BA", title: "Economics BA"),
        PathProgramListing(code: "MATH-BA", title: "Mathematics BA"),
        PathProgramListing(code: "PSCI-BA", title: "Political Science BA"),
        PathProgramListing(code: "MATH-MINOR", title: "Mathematics Minor"),
        PathProgramListing(code: "STAT-MIN", title: "Statistics Minor"),
        PathProgramListing(code: "FNCE-MBA-NCON", title: "Finance MBA (No Concentration)"),
        PathProgramListing(code: "HIST-PHD", title: "History PhD"),
    ]

    private static let cs = StudentDegree(raw: ["degc": "BSE", "coll": "EU", "levl": "UG", "program": "EU_BSE", "major": "CSCI"])
    private static let wharton = StudentDegree(raw: ["degc": "BS", "coll": "WU", "levl": "UG", "program": "WU_BS", "major": "UNDL"])

    private static func built() -> [DegreeProgramEntry] {
        DegreeProgramSearch.entries(
            programs: catalogue,
            degrees: [cs, wharton],
            labels: ["computer science", "wharton"],
            colleges: ["EU": "Engineering", "WU": "Wharton"])
    }

    private static func entry(_ code: String) -> DegreeProgramEntry? {
        built().first { $0.id == code }
    }

    private static func ids(_ query: String, scope: DegreeProgramKind? = nil) -> [String] {
        DegreeProgramSearch.search(DegreeProgramSearch.parse(query), in: built(), scope: scope).map { $0.id }
    }

    private static func listing(_ code: String) -> PathProgramListing {
        PathProgramListing(code: code, title: code)
    }

    private static func row(
        _ kind: DegreeProgramKind, sibling: Bool = false, degreeCode: String = "",
        label: String = "", college: String = ""
    ) -> DegreeProgramEntry {
        DegreeProgramEntry(
            listing: listing("X-Y"), kind: kind, name: "x", degreeCode: degreeCode,
            degreeID: label.isEmpty ? nil : "id", degreeLabel: label, collegeName: college, isSibling: sibling)
    }

    // MARK: classification

    @Test("a Wharton BS row is a sibling concentration of the Wharton degree")
    func whartonConcentration() {
        let found = Self.entry("FNCS-BS")
        #expect(found?.kind == .concentration)
        #expect(found?.isSibling == true)
        #expect(found?.collegeName == "wharton")
        #expect(found?.degreeID == Self.wharton.id)
        #expect(found?.degreeLabel == "wharton")
        #expect(found?.degreeCode == "bs")
        #expect(found?.name == "finance")
    }

    @Test("a real third code part under the student's own major is a concentration that is not a sibling")
    func ownMajorConcentration() {
        let found = Self.entry("CSCI-BSE-AINT")
        #expect(found?.kind == .concentration)
        #expect(found?.isSibling == false)
        #expect(found?.degreeID == Self.cs.id)
        #expect(found?.degreeLabel == "computer science")
        #expect(found?.collegeName == "engineering")
        #expect(found?.name == "computer science (artificial intelligence)")
    }

    @Test("another engineering row is a sibling major")
    func siblingMajor() {
        let found = Self.entry("CMPE-BSE")
        #expect(found?.kind == .major)
        #expect(found?.isSibling == true)
        #expect(found?.degreeID == Self.cs.id)
    }

    @Test("a bachelor's row outside the student's degrees is a plain major")
    func plainMajor() {
        let found = Self.entry("ECON-BA")
        #expect(found?.kind == .major)
        #expect(found?.isSibling == false)
        #expect(found?.degreeID == nil)
        #expect(found?.degreeLabel == "")
        #expect(found?.collegeName == "")
    }

    @Test("both minor code shapes are minors named without the word minor")
    func minors() {
        #expect(Self.entry("MATH-MINOR")?.kind == .minor)
        #expect(Self.entry("MATH-MINOR")?.name == "mathematics")
        #expect(Self.entry("STAT-MIN")?.kind == .minor)
        #expect(Self.entry("STAT-MIN")?.name == "statistics")
        #expect(Self.entry("STAT-MIN")?.isSibling == false)
    }

    @Test("a minor is recognised by its title when the code does not say")
    func minorByTitle() {
        let rows = DegreeProgramSearch.entries(
            programs: [PathProgramListing(code: "ARTH-XYZ", title: "Art History Minor")],
            degrees: [], labels: [], colleges: [:])
        #expect(rows.first?.kind == .minor)
        #expect(rows.first?.name == "art history")
    }

    @Test("graduate programs are other programs")
    func otherPrograms() {
        #expect(Self.entry("FNCE-MBA-NCON")?.kind == .other)
        #expect(Self.entry("HIST-PHD")?.kind == .other)
    }

    @Test("the student's own program is not a sibling and falls under the another-major rule, in both spellings")
    func ownProgram() {
        #expect(Self.entry("CSCI-BSE")?.kind == .major)
        #expect(Self.entry("CSCI-BSE")?.isSibling == false)
        #expect(Self.entry("CSCI-BSE")?.degreeID == nil)
        #expect(Self.entry("CSCI-BSE-NCON")?.kind == .major)
        #expect(Self.entry("CSCI-BSE-NCON")?.isSibling == false)
    }

    @Test("entries come back by kind, siblings first, then name")
    func entryOrder() {
        let rows = Self.built()
        let ranks = rows.map { DegreeProgramKind.allCases.firstIndex(of: $0.kind) ?? 0 }
        #expect(ranks == ranks.sorted())
        #expect(rows.filter { $0.kind == .concentration }.map { $0.id }
            == ["ACCT-BS", "AIBU-BS", "BSAN-BS", "FNCS-BS", "CSCI-BSE-AINT"])
        #expect(rows.filter { $0.kind == .minor }.map { $0.id } == ["MATH-MINOR", "STAT-MIN"])
        #expect(rows.count == Self.catalogue.count)
    }

    // MARK: parse

    @Test("parse: add a math minor")
    func parseAddMinor() {
        let q = DegreeProgramSearch.parse("add a math minor")
        #expect(q.tokens == ["math"])
        #expect(q.kind == .minor)
        #expect(q.change == .add)
        #expect(q.text == "math")
    }

    @Test("parse: switch to econ, what if I did finance concentration, double major in cs")
    func parseOthers() {
        let a = DegreeProgramSearch.parse("switch to econ")
        #expect(a.tokens == ["econ"])
        #expect(a.kind == nil)
        #expect(a.change == .switchTo)

        let b = DegreeProgramSearch.parse("what if i did finance concentration")
        #expect(b.tokens == ["finance"])
        #expect(b.kind == .concentration)
        #expect(b.change == nil)

        let c = DegreeProgramSearch.parse("double major in cs")
        #expect(c.tokens == ["cs"])
        #expect(c.kind == .major)
        #expect(c.change == .add)
    }

    @Test("parse: a change word at an edge is a change, in the middle it is content")
    func parseChangeWords() {
        let edge = DegreeProgramSearch.parse("change management")
        #expect(edge.tokens == ["management"])
        #expect(edge.change == .switchTo)

        let middle = DegreeProgramSearch.parse("social change studies")
        #expect(middle.tokens == ["social", "change", "studies"])
        #expect(middle.change == nil)
    }

    @Test("parse: a lone kind word leaves no tokens")
    func parseKindOnly() {
        let q = DegreeProgramSearch.parse("minors")
        #expect(q.tokens.isEmpty)
        #expect(q.isEmpty)
        #expect(q.kind == .minor)
    }

    @Test("parse folds case and accents")
    func parseFolding() {
        #expect(DegreeProgramSearch.parse("  Économie  ").tokens == ["economie"])
    }

    // MARK: search

    @Test("search: an exact word, a prefix and a typo all find finance, concentration first")
    func searchFinance() {
        #expect(Self.ids("finance").first == "FNCS-BS")
        #expect(Self.ids("finance").contains("FNCE-MBA-NCON"))
        #expect(Self.ids("fin").first == "FNCS-BS")
        #expect(Self.ids("finanse").first == "FNCS-BS")
        #expect(Self.ids("acounting").first == "ACCT-BS")
    }

    @Test("search: aliases stats and cs")
    func searchAliases() {
        #expect(Self.ids("stats") == ["STAT-MIN"])
        #expect(Set(Self.ids("cs")) == ["CSCI-BSE", "CSCI-BSE-NCON", "CSCI-BSE-AINT"])
        #expect(Self.ids("poli sci").first == "PSCI-BA")
    }

    @Test("search: an initialism and a code")
    func searchInitialismAndCode() {
        #expect(Self.ids("dmd").first == "DMD-BSE")
        #expect(Self.ids("fncs") == ["FNCS-BS"])
    }

    @Test("search: scope filters and a kind word in the query acts as the scope")
    func searchScope() {
        #expect(Self.ids("math", scope: .minor) == ["MATH-MINOR"])
        #expect(Set(Self.ids("math")) == ["MATH-BA", "MATH-MINOR"])
        #expect(Self.ids("math minor") == ["MATH-MINOR"])
        #expect(Self.ids("math minor", scope: .major) == ["MATH-BA"])
    }

    @Test("search: every token must match")
    func searchAllTokens() {
        #expect(Self.ids("computer finance").isEmpty)
        #expect(Self.ids("zzzzqq").isEmpty)
    }

    @Test("search: an empty query returns everything in the given order, scoped")
    func searchEmpty() {
        let rows = Self.built()
        #expect(DegreeProgramSearch.search(DegreeProgramSearch.parse(""), in: rows, scope: nil) == rows)
        #expect(DegreeProgramSearch.search(DegreeProgramSearch.parse(""), in: rows, scope: .minor).map { $0.id }
            == ["MATH-MINOR", "STAT-MIN"])
        #expect(DegreeProgramSearch.search(DegreeProgramSearch.parse("minors"), in: rows, scope: nil).map { $0.id }
            == ["MATH-MINOR", "STAT-MIN"])
    }

    @Test("search: the same call twice gives the same list")
    func searchDeterministic() {
        let rows = Self.built()
        let q = DegreeProgramSearch.parse("science")
        #expect(DegreeProgramSearch.search(q, in: rows, scope: nil) == DegreeProgramSearch.search(q, in: rows, scope: nil))
        #expect(DegreeProgramSearch.search(q, in: rows, scope: nil).count >= 4)
    }

    // MARK: sections

    @Test("sections group by kind in order and omit empty kinds")
    func sectionList() {
        let sections = DegreeProgramSearch.sections(Self.built())
        #expect(sections.map { $0.kind } == [.concentration, .major, .minor, .other])
        #expect(sections.first?.id == "concentration")
        #expect(sections.reduce(0) { $0 + $1.entries.count } == Self.catalogue.count)
        let minorsOnly = DegreeProgramSearch.sections(Self.built().filter { $0.kind == .minor })
        #expect(minorsOnly.map { $0.kind } == [.minor])
        #expect(DegreeProgramSearch.sections([]).isEmpty)
    }

    // MARK: related and loose

    @Test("related runs each term in order, skips what is excluded and stops at the limit")
    func relatedTerms() {
        let rows = Self.built()
        let all = DegreeProgramSearch.related(terms: ["finance", "statistics"], in: rows, scope: nil, excluding: ["FNCS-BS"], limit: 5)
        #expect(all.map { $0.id } == ["FNCE-MBA-NCON", "STAT-MIN"])

        let reversed = DegreeProgramSearch.related(terms: ["statistics", "finance"], in: rows, scope: nil, excluding: [], limit: 5)
        #expect(reversed.first?.id == "STAT-MIN")

        let capped = DegreeProgramSearch.related(terms: ["finance", "math"], in: rows, scope: nil, excluding: [], limit: 1)
        #expect(capped.map { $0.id } == ["FNCS-BS"])

        let repeated = DegreeProgramSearch.related(terms: ["finance", "finance"], in: rows, scope: nil, excluding: [], limit: 10)
        #expect(Set(repeated.map { $0.id }).count == repeated.count)
        #expect(DegreeProgramSearch.related(terms: ["finance"], in: rows, scope: nil, excluding: [], limit: 0).isEmpty)
    }

    @Test("loose finds finance from a request where only one word is a subject")
    func looseFindsFinance() {
        let rows = Self.built()
        let q = DegreeProgramSearch.parse("money finance wizardry")
        #expect(DegreeProgramSearch.search(q, in: rows, scope: nil).isEmpty)
        let found = DegreeProgramSearch.loose(q, in: rows, scope: nil, excluding: [], limit: 5)
        #expect(found.first?.id == "FNCS-BS")
        let without = DegreeProgramSearch.loose(q, in: rows, scope: nil, excluding: ["FNCS-BS"], limit: 5)
        #expect(!without.contains { $0.id == "FNCS-BS" })
        #expect(DegreeProgramSearch.loose(DegreeProgramSearch.parse("hi"), in: rows, scope: nil, excluding: [], limit: 5).isEmpty)
    }

    // MARK: preferredPlan

    private static func plan(_ change: PathWhatIfChange) -> PathWhatIfPlan {
        PathWhatIfPlan(change: change, programCode: "X-Y", degreeInfo: [:], goals: cs.goals)
    }

    private static let allPlans: [PathWhatIfPlan] = [
        DegreeProgramSearchTests.plan(.newProgram), DegreeProgramSearchTests.plan(.addMajor),
        DegreeProgramSearchTests.plan(.addMinor), DegreeProgramSearchTests.plan(.addConcentration),
    ]

    private static func preferred(_ text: String, _ plans: [PathWhatIfPlan] = DegreeProgramSearchTests.allPlans) -> PathWhatIfChange? {
        DegreeProgramSearch.preferredPlan(plans, for: DegreeProgramSearch.parse(text))?.change
    }

    @Test("preferredPlan follows the table for each kind and change")
    func preferredTable() {
        #expect(Self.preferred("add math minor") == .addMinor)
        #expect(Self.preferred("math minor") == .addMinor)
        #expect(Self.preferred("switch to finance concentration") == .newProgram)
        #expect(Self.preferred("finance concentration") == .addConcentration)
        #expect(Self.preferred("add finance concentration") == .addConcentration)
        #expect(Self.preferred("double major cs") == .addMajor)
        #expect(Self.preferred("switch major cs") == .newProgram)
        #expect(Self.preferred("major cs") == nil)
        #expect(Self.preferred("add econ") == .addConcentration)
        #expect(Self.preferred("switch econ") == .newProgram)
        #expect(Self.preferred("econ") == nil)
    }

    @Test("preferredPlan falls through to the next candidate present and to nil")
    func preferredFallthrough() {
        let noConc = [Self.plan(.newProgram), Self.plan(.addMajor)]
        #expect(Self.preferred("finance concentration", noConc) == .newProgram)
        #expect(Self.preferred("add econ", [Self.plan(.addMinor), Self.plan(.addMajor)]) == .addMinor)
        #expect(Self.preferred("add econ", [Self.plan(.newProgram)]) == nil)
        #expect(Self.preferred("math minor", [Self.plan(.newProgram)]) == nil)
        let other = DegreeSearchQuery(tokens: ["x"], kind: .other, change: nil)
        #expect(DegreeProgramSearch.preferredPlan(Self.allPlans, for: other) == nil)
        let plain = DegreeSearchQuery(tokens: ["x"], kind: nil, change: nil)
        #expect(DegreeProgramSearch.preferredPlan(Self.allPlans, for: plain) == nil)
    }

    // MARK: actionLine

    @Test("actionLine has six forms")
    func actionLines() {
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.concentration, sibling: true, degreeCode: "bs", label: "wharton", college: "wharton"))
            == "concentration · wharton")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.concentration, sibling: true, degreeCode: "bs", label: "wharton"))
            == "concentration · bs")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.concentration, sibling: true)) == "concentration")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.concentration, label: "computer science"))
            == "concentration · computer science")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.concentration)) == "concentration")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.major, sibling: true, label: "computer science"))
            == "major · instead of computer science")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.major, sibling: true)) == "major")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.major, degreeCode: "ba")) == "major · ba")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.major)) == "major")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.minor, degreeCode: "minor")) == "minor")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.other, degreeCode: "mba")) == "program · mba")
        #expect(DegreeProgramSearch.actionLine(for: Self.row(.other)) == "program")
    }

    @Test("kind headings and tags")
    func kindWords() {
        #expect(DegreeProgramKind.allCases.map { $0.heading }
            == ["concentrations", "majors", "minors", "other programs"])
        #expect(DegreeProgramKind.allCases.map { $0.tag }
            == ["concentration", "major", "minor", "program"])
    }

    // MARK: assist

    @Test("terms(fromReply:) strips bullets, numbering, quotes and periods, dedupes and drops sentences")
    func assistTerms() {
        let reply = "1. Finance\n- \"Statistics\".\nBusiness Analytics, a very long sentence that is clearly not a subject name at all here, finance"
        #expect(DegreeSearchAssist.terms(fromReply: reply) == ["finance", "statistics", "business analytics"])
        #expect(DegreeSearchAssist.terms(fromReply: "a, b, c, d, e, f, g, h") == ["a", "b", "c", "d", "e", "f"])
        #expect(DegreeSearchAssist.terms(fromReply: "").isEmpty)
    }

    @Test("prompt has two lines, caps the options and flattens the request")
    func assistPrompt() {
        let names = (0..<60).map { "name\($0)" }
        let prompt = DegreeSearchAssist.prompt(request: "line one\nline two", optionNames: names)
        let lines = prompt.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("OPTIONS: name0, name1"))
        #expect(lines[0].contains("name39"))
        #expect(!lines[0].contains("name40"))
        #expect(lines[1] == "STUDENT TYPED: line one line two")

        let none = DegreeSearchAssist.prompt(request: "x", optionNames: [])
        #expect(none.hasPrefix("OPTIONS: none\n"))

        let long = DegreeSearchAssist.prompt(request: String(repeating: "a", count: 300), optionNames: [String(repeating: "b", count: 80)])
        #expect(long.components(separatedBy: "\n")[1].count == "STUDENT TYPED: ".count + 160)
        #expect(long.components(separatedBy: "\n")[0].count == "OPTIONS: ".count + 40)
    }

    @Test("shouldAsk wants a real request with almost no results")
    func assistShouldAsk() {
        #expect(DegreeSearchAssist.shouldAsk(DegreeProgramSearch.parse("wizardry"), resultCount: 0))
        #expect(DegreeSearchAssist.shouldAsk(DegreeProgramSearch.parse("wizardry"), resultCount: 2))
        #expect(!DegreeSearchAssist.shouldAsk(DegreeProgramSearch.parse("wizardry"), resultCount: 3))
        #expect(!DegreeSearchAssist.shouldAsk(DegreeProgramSearch.parse("art"), resultCount: 0))
        #expect(!DegreeSearchAssist.shouldAsk(DegreeProgramSearch.parse("minors"), resultCount: 0))
        #expect(!DegreeSearchAssist.instructions.isEmpty)
    }
}
